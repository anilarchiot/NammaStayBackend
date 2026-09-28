-- =====================================================================
-- NammaStay · 015_plans_by_type.sql
-- Subscription prices by property TYPE and SIZE (still one flat price per
-- property). Each owner only sees the plans that fit their property.
--
--   Homestay  up to 6 rooms     ₹999 / month     ₹9,990 / year
--   Hostel/PG any size          ₹1,650 / month   ₹16,500 / year   (existing 'monthly' / 'yearly')
--   Hotel     up to 20 rooms    ₹2,499 / month   ₹24,990 / year
--   Hotel     21–50 rooms       ₹3,999 / month   ₹39,990 / year
--   Hotel     51+ rooms         custom quote (contact us)
-- A homestay with more than 6 rooms gets hotel pricing automatically.
-- Change prices anytime: app → Subscribers → Billing settings.
-- Run AFTER 007_subscriptions.sql.
-- =====================================================================

alter table public.plans
  add column if not exists kind text check (kind is null or kind in ('hostel','hotel','homestay')),
  add column if not exists min_units int check (min_units is null or min_units >= 0),
  add column if not exists max_units int check (max_units is null or max_units >= 1),
  add column if not exists is_quote boolean not null default false;

-- existing plans are the hostel / PG prices
update public.plans set kind = 'hostel', sort = case id when 'monthly' then 10 when 'yearly' then 11 else sort end
 where id in ('monthly','yearly') and kind is null;
update public.plans set name = 'Monthly', description = 'Billed every month' where id = 'monthly';
update public.plans set name = 'Yearly', description = '2 months free' where id = 'yearly';

insert into public.plans (id, name, period_months, price_paise, description, sort, kind, min_units, max_units, is_quote) values
  ('homestay_monthly', 'Monthly', 1,  99900,   'Homestays up to 6 rooms',        1, 'homestay', null, 6,    false),
  ('homestay_yearly',  'Yearly',  12, 999000,  'Homestays · 2 months free',      2, 'homestay', null, 6,    false),
  ('hotel_s_monthly',  'Monthly', 1,  249900,  'Hotels up to 20 rooms',          20, 'hotel',   null, 20,   false),
  ('hotel_s_yearly',   'Yearly',  12, 2499000, 'Up to 20 rooms · 2 months free', 21, 'hotel',   null, 20,   false),
  ('hotel_m_monthly',  'Monthly', 1,  399900,  'Hotels with 21–50 rooms',        22, 'hotel',   21,   50,   false),
  ('hotel_m_yearly',   'Yearly',  12, 3999000, '21–50 rooms · 2 months free',    23, 'hotel',   21,   50,   false),
  ('hotel_l_quote',    'Large hotels', 1, 0,   '50+ rooms — custom pricing',     24, 'hotel',   51,   null, true)
on conflict (id) do nothing;

-- Plans that fit one property (its type and number of active rooms/beds)
create or replace function public._plans_for(p_property uuid) returns setof public.plans
language sql stable security definer set search_path = public, pg_temp as $$
  with k as (
    select coalesce(p.kind, 'hostel') as kind,
           (select count(*) from public.beds b where b.property_id = p.id and b.is_active)::int as n
      from public.properties p where p.id = p_property),
  exact as (
    select pl.* from public.plans pl, k
     where pl.is_active and (pl.kind is null or pl.kind = k.kind)
       and (pl.min_units is null or k.n >= pl.min_units) and (pl.max_units is null or k.n <= pl.max_units))
  select * from exact
  union all
  select pl.* from public.plans pl, k                       -- e.g. a homestay that outgrew 6 rooms → hotel prices
   where not exists (select 1 from exact) and pl.is_active and pl.kind = 'hotel'
     and (pl.min_units is null or k.n >= pl.min_units) and (pl.max_units is null or k.n <= pl.max_units)
$$;

create or replace function public.billing_info(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return jsonb_build_object(
    'access', public.property_access(p_property),
    'plans', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort), '[]'::jsonb) from public._plans_for(p_property) x),
    'kind', (select kind from public.properties where id = p_property),
    'units', (select count(*) from public.beds where property_id = p_property and is_active),
    'pay_to', (select jsonb_build_object('upi_id', upi_id, 'payee_name', payee_name,
                      'support_whatsapp', support_whatsapp, 'support_email', support_email)
                 from public.platform_settings where id = 1),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'plan_id', plan_id, 'amount_paise', amount_paise, 'utr', utr,
                      'status', status, 'submitted_at', submitted_at, 'review_note', review_note,
                      'period_start', period_start, 'period_end', period_end) order by submitted_at desc), '[]'::jsonb)
                  from (select * from public.subscription_payments where property_id = p_property
                        order by submitted_at desc limit 24) h));
end $$;

create or replace function public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_plan public.plans%rowtype; v_utr text := upper(regexp_replace(coalesce(p_utr, ''), '\s', '', 'g')); v_id uuid;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select * into v_plan from public._plans_for(p_property) x where x.id = p_plan;
  if not found then raise exception 'Choose a plan for your property.'; end if;
  if v_plan.is_quote then raise exception 'This plan is priced on request. Please contact NammaStay support.'; end if;
  if v_utr !~ '^[0-9A-Z]{6,35}$' then raise exception 'Enter the UPI transaction ID (UTR) from your payment app.'; end if;
  if (select count(*) from public.subscription_payments where property_id = p_property and status = 'pending') >= 3 then
    raise exception 'You already have payments waiting for confirmation. We’ll confirm them shortly.';
  end if;
  begin
    insert into public.subscription_payments (property_id, plan_id, amount_paise, utr)
    values (p_property, v_plan.id, v_plan.price_paise, v_utr) returning id into v_id;
  exception when unique_violation then
    raise exception 'This UPI transaction ID was already submitted.';
  end;
  return jsonb_build_object('id', v_id, 'status', 'pending');
end $$;

create or replace function public.admin_save_billing_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare pl jsonb;
begin
  perform public._assert_platform_admin();
  update public.platform_settings set
    upi_id = coalesce(nullif(btrim(p->>'upi_id'), ''), upi_id),
    payee_name = coalesce(nullif(btrim(p->>'payee_name'), ''), payee_name),
    trial_days = coalesce(nullif(p->>'trial_days', '')::int, trial_days),
    grace_days = coalesce(nullif(p->>'grace_days', '')::int, grace_days),
    support_whatsapp = case when p ? 'support_whatsapp' then nullif(btrim(p->>'support_whatsapp'), '') else support_whatsapp end,
    support_email = case when p ? 'support_email' then nullif(btrim(p->>'support_email'), '') else support_email end,
    updated_at = now()
  where id = 1;
  for pl in select * from jsonb_array_elements(coalesce(p->'plans', '[]'::jsonb)) loop
    update public.plans set
      price_paise = coalesce(nullif(pl->>'price_paise', '')::int, price_paise),
      name = coalesce(nullif(btrim(pl->>'name'), ''), name),
      description = case when pl ? 'description' then nullif(btrim(pl->>'description'), '') else description end,
      is_active = coalesce((pl->>'is_active')::boolean, is_active),
      min_units = case when pl ? 'min_units' then nullif(pl->>'min_units', '')::int else min_units end,
      max_units = case when pl ? 'max_units' then nullif(pl->>'max_units', '')::int else max_units end
    where id = pl->>'id';
  end loop;
end $$;

revoke execute on function public._plans_for(uuid) from public, anon, authenticated;
