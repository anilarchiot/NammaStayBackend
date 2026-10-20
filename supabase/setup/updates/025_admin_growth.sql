-- =====================================================================
-- NammaStay · 025_admin_growth.sql — admin website: grow & run the business
--   1. Customer health: each property's setup checklist + a 0–100 score
--   2. Revenue: MRR, ARR, money collected per month, plan mix, churn
--   3. Coupons: codes owners enter when paying (percent or flat ₹ off)
--   4. Admin activity log: who approved / suspended / changed what, when
--   5. Lead → property: link a converted lead to the property created
-- Run AFTER 024_form_c.sql.
-- =====================================================================

-- ---------------------------------------------------------------- 1. customer health
create or replace function public.admin_health() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(x order by (x->>'score')::int, x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object(
      'property_id', p.id, 'name', p.name, 'city', p.city, 'kind', p.kind, 'created_at', p.created_at, 'state', public._access_state(p.id),
      'trial_ends_at', s.trial_ends_at, 'paid_until', s.paid_until, 'last_seen_at', u.last_seen_at,
      'steps', jsonb_build_object('rooms', u.beds > 0, 'upi', p.upi_id is not null, 'staff', u.staff > 1, 'first_booking', u.bookings > 0,
                                  'first_payment', u.payments > 0, 'regular_use', u.bookings_14 >= 3),
      'bookings_14', u.bookings_14, 'active_days_7', u.active_days_7,
      'score', least(100, round(
          8 * ((u.beds > 0)::int + (p.upi_id is not null)::int + (u.staff > 1)::int + (u.bookings > 0)::int + (u.payments > 0)::int)
        + 3 * least(u.bookings_14, 10) + 6 * least(u.active_days_7, 5)))::int) x
      from public.properties p
      join public.subscriptions s on s.property_id = p.id
      cross join lateral (select
        (select count(*) from public.beds b where b.property_id = p.id and b.is_active) beds,
        (select count(*) from public.property_members m where m.property_id = p.id) staff,
        (select count(*) from public.bookings b where b.property_id = p.id) bookings,
        (select count(*) from public.payments y where y.property_id = p.id) payments,
        (select count(*) from public.bookings b where b.property_id = p.id and b.created_at > now() - interval '14 days') bookings_14,
        (select count(distinct d) from (select (b.created_at at time zone 'Asia/Kolkata')::date d from public.bookings b where b.property_id = p.id and b.created_at > now() - interval '7 days'
                                         union select (y.received_at at time zone 'Asia/Kolkata')::date from public.payments y where y.property_id = p.id and y.received_at > now() - interval '7 days') z) active_days_7,
        (select max(m.last_seen_at) from public.property_members m where m.property_id = p.id) last_seen_at) u) q);
end $$;

-- ---------------------------------------------------------------- 2. revenue
create or replace function public.admin_revenue() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_mrr bigint;
begin
  perform public._assert_platform_admin();
  with latest as (
    select distinct on (sp.property_id) sp.property_id, sp.amount_paise, pl.period_months, pl.kind, pl.name as plan_name
      from public.subscription_payments sp join public.plans pl on pl.id = sp.plan_id
      join public.subscriptions s on s.property_id = sp.property_id
     where sp.status = 'approved' and s.paid_until > now() and not s.is_complimentary and not coalesce(s.is_suspended, false)
     order by sp.property_id, sp.reviewed_at desc)
  select coalesce(sum(amount_paise::numeric / greatest(period_months, 1)), 0)::bigint into v_mrr from latest;
  return jsonb_build_object(
    'mrr_paise', v_mrr, 'arr_paise', v_mrr * 12,
    'paying', (select count(*) from public.subscriptions s where s.paid_until > now() and not s.is_complimentary and not coalesce(s.is_suspended, false)),
    'trials', (select count(*) from public.subscriptions s where s.trial_ends_at > now() and (s.paid_until is null or s.paid_until < now()) and not s.is_complimentary),
    'complimentary', (select count(*) from public.subscriptions s where s.is_complimentary),
    'churned_30', (select count(*) from public.subscriptions s where s.paid_until between now() - interval '30 days' and now() and not s.is_complimentary),
    'collected_this_month', (select coalesce(sum(amount_paise), 0) from public.subscription_payments
                              where status = 'approved' and date_trunc('month', reviewed_at at time zone 'Asia/Kolkata') = date_trunc('month', now() at time zone 'Asia/Kolkata')),
    'months', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'),
                 'collected_paise', (select coalesce(sum(amount_paise), 0) from public.subscription_payments sp
                                      where sp.status = 'approved' and date_trunc('month', sp.reviewed_at at time zone 'Asia/Kolkata') = m)) order by m), '[]'::jsonb)
               from generate_series(date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '11 months', date_trunc('month', now() at time zone 'Asia/Kolkata'), interval '1 month') m),
    'mix', (select coalesce(jsonb_agg(jsonb_build_object('plan', plan_name, 'kind', kind, 'yearly', period_months >= 12, 'count', n) order by n desc), '[]'::jsonb) from (
              select pl.name plan_name, pl.kind, pl.period_months, count(*) n
                from (select distinct on (sp.property_id) sp.property_id, sp.plan_id from public.subscription_payments sp
                       join public.subscriptions s on s.property_id = sp.property_id
                      where sp.status = 'approved' and s.paid_until > now() order by sp.property_id, sp.reviewed_at desc) l
                join public.plans pl on pl.id = l.plan_id group by pl.name, pl.kind, pl.period_months) z),
    'conversion_90', (select jsonb_build_object('trials', count(*), 'paid', count(*) filter (where exists (select 1 from public.subscription_payments sp where sp.property_id = s.property_id and sp.status = 'approved')))
                        from public.subscriptions s join public.properties p on p.id = s.property_id where p.created_at > now() - interval '90 days' and not s.is_complimentary));
end $$;

-- ---------------------------------------------------------------- 3. coupons
create table if not exists public.coupons (
  code        text primary key check (code ~ '^[A-Z0-9-]{3,20}$'),
  kind        text not null check (kind in ('percent','flat')),
  value       int  not null check (value > 0),                    -- percent: 1–90 · flat: paise
  plan_ids    text[],                                             -- null = every plan
  max_uses    int check (max_uses is null or max_uses > 0),
  used        int not null default 0,
  expires_at  timestamptz,
  is_active   boolean not null default true,
  note        text check (char_length(note) <= 200),
  created_at  timestamptz not null default now(),
  check (kind <> 'percent' or value <= 90)
);
alter table public.coupons enable row level security;
revoke all on public.coupons from anon, authenticated;

alter table public.subscription_payments
  add column if not exists coupon_code text,
  add column if not exists discount_paise int not null default 0 check (discount_paise >= 0);

create or replace function public._coupon_quote(p_plan text, p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.coupons%rowtype; pl public.plans%rowtype; v_disc int;
begin
  select * into pl from public.plans where id = p_plan;
  select * into c from public.coupons where code = upper(btrim(coalesce(p_code, '')));
  if not found or not c.is_active or (c.expires_at is not null and c.expires_at < now()) or (c.max_uses is not null and c.used >= c.max_uses) then
    raise exception 'That coupon code isn’t valid.';
  end if;
  if c.plan_ids is not null and not (p_plan = any (c.plan_ids)) then raise exception 'That coupon doesn’t apply to this plan.'; end if;
  v_disc := case c.kind when 'percent' then round(pl.price_paise * c.value / 100.0) else least(c.value, pl.price_paise - 100) end;
  return jsonb_build_object('code', c.code, 'discount_paise', v_disc, 'amount_paise', pl.price_paise - v_disc, 'price_paise', pl.price_paise);
end $$;

-- Owner checks a code before paying
create or replace function public.check_coupon(p_property uuid, p_plan text, p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if not exists (select 1 from public._plans_for(p_property) x where x.id = p_plan) then raise exception 'Choose a plan for your property.'; end if;
  return public._coupon_quote(p_plan, p_code);
end $$;

-- Pay with a coupon (the 3-argument version without a coupon still works)
create or replace function public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text, p_coupon text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_plan public.plans%rowtype; v_utr text := upper(regexp_replace(coalesce(p_utr, ''), '\s', '', 'g')); v_id uuid; q jsonb;
begin
  if nullif(btrim(coalesce(p_coupon, '')), '') is null then return public.submit_subscription_payment(p_property, p_plan, p_utr); end if;
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select * into v_plan from public._plans_for(p_property) x where x.id = p_plan;
  if not found then raise exception 'Choose a plan for your property.'; end if;
  if v_plan.is_quote then raise exception 'This plan is priced on request. Please contact NammaStay support.'; end if;
  if v_utr !~ '^[0-9A-Z]{6,35}$' then raise exception 'Enter the UPI transaction ID (UTR) from your payment app.'; end if;
  if (select count(*) from public.subscription_payments where property_id = p_property and status = 'pending') >= 3 then
    raise exception 'You already have payments waiting for confirmation. We’ll confirm them shortly.';
  end if;
  q := public._coupon_quote(p_plan, p_coupon);
  begin
    insert into public.subscription_payments (property_id, plan_id, amount_paise, utr, coupon_code, discount_paise)
    values (p_property, v_plan.id, (q->>'amount_paise')::int, v_utr, q->>'code', (q->>'discount_paise')::int) returning id into v_id;
  exception when unique_violation then raise exception 'This UPI transaction ID was already submitted.';
  end;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'amount_paise', (q->>'amount_paise')::int);
end $$;

create or replace function public._coupon_used() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and new.coupon_code is not null then
    update public.coupons set used = used + 1 where code = new.coupon_code;
  end if;
  return new;
end $$;
drop trigger if exists sub_payment_coupon on public.subscription_payments;
create trigger sub_payment_coupon after update of status on public.subscription_payments for each row execute function public._coupon_used();

create or replace function public.admin_coupons() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb) from public.coupons c);
end $$;

-- p: { code, kind, value (percent number or rupees for flat), plan_ids?, max_uses?, expires_at?, note?, is_active? }
create or replace function public.admin_save_coupon(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text := upper(btrim(coalesce(p->>'code', ''))); v_kind text := coalesce(p->>'kind', 'percent'); v_val numeric := nullif(p->>'value', '')::numeric;
begin
  perform public._assert_platform_admin();
  if v_code !~ '^[A-Z0-9-]{3,20}$' then raise exception 'Code: 3–20 letters, numbers or dashes (e.g. LAUNCH20).'; end if;
  if v_val is null or v_val <= 0 then raise exception 'Enter the discount.'; end if;
  if v_kind = 'percent' and v_val > 90 then raise exception 'Percent discounts go up to 90%%.'; end if;
  insert into public.coupons (code, kind, value, plan_ids, max_uses, expires_at, note, is_active)
  values (v_code, v_kind, case when v_kind = 'flat' then round(v_val * 100) else round(v_val) end,
          case when jsonb_typeof(p->'plan_ids') = 'array' and jsonb_array_length(p->'plan_ids') > 0 then array(select jsonb_array_elements_text(p->'plan_ids')) end,
          nullif(p->>'max_uses', '')::int, nullif(p->>'expires_at', '')::timestamptz, nullif(btrim(coalesce(p->>'note', '')), ''), coalesce((p->>'is_active')::boolean, true))
  on conflict (code) do update set kind = excluded.kind, value = excluded.value, plan_ids = excluded.plan_ids, max_uses = excluded.max_uses,
     expires_at = excluded.expires_at, note = excluded.note, is_active = excluded.is_active;
end $$;

-- Subscribers page: show the coupon on payments waiting for approval
create or replace function public.admin_subscriptions(p_q text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := nullif(btrim(p_q), '');
begin
  perform public._assert_platform_admin();
  return jsonb_build_object(
    'settings', (select to_jsonb(s) from public.platform_settings s where id = 1),
    'plans', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort), '[]'::jsonb) from public.plans x),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('id', sp.id, 'property_id', sp.property_id, 'property', p.name,
                  'plan_id', sp.plan_id, 'amount_paise', sp.amount_paise, 'utr', sp.utr, 'submitted_at', sp.submitted_at, 'coupon_code', sp.coupon_code,
                  'owner_email', (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1))
                  order by sp.submitted_at), '[]'::jsonb)
                from public.subscription_payments sp join public.properties p on p.id = sp.property_id
               where sp.status = 'pending'),
    'properties', (select coalesce(jsonb_agg(r order by r->>'created_at' desc), '[]'::jsonb) from (
                select jsonb_build_object('property_id', p.id, 'name', p.name, 'city', p.city, 'created_at', p.created_at,
                  'owner_email', (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
                  'owner_name', (select m.display_name from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
                  'beds', (select count(*) from public.beds b where b.property_id = p.id and b.is_active),
                  'state', public._access_state(p.id), 'plan_id', s.plan_id, 'trial_ends_at', s.trial_ends_at,
                  'paid_until', s.paid_until, 'is_complimentary', s.is_complimentary,
                  'last_booking_at', (select max(b.created_at) from public.bookings b where b.property_id = p.id)) r
                  from public.properties p join public.subscriptions s on s.property_id = p.id
                 where v_q is null or p.name ilike '%' || v_q || '%' or p.city ilike '%' || v_q || '%'
                    or exists (select 1 from public.property_members m where m.property_id = p.id and m.email ilike '%' || v_q || '%')
                 limit 500) q));
end $$;

-- ---------------------------------------------------------------- 4. admin activity log
create table if not exists public.admin_actions (
  id           bigserial primary key,
  admin_id     uuid,
  admin_email  text,
  action       text not null,
  property_id  uuid,
  details      jsonb,
  at           timestamptz not null default now()
);
create index if not exists admin_actions_at on public.admin_actions (at desc);
alter table public.admin_actions enable row level security;
revoke all on public.admin_actions from anon, authenticated;

-- Logs a change when the person making it is a NammaStay admin (owners' own changes are not logged here)
create or replace function public._admin_audit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare n jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end; o jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_diff jsonb; v_prop uuid; v_action text;
begin
  if auth.uid() is null or not exists (select 1 from public.platform_admins where user_id = auth.uid()) then return coalesce(new, old); end if;
  select jsonb_object_agg(k, jsonb_build_array(o->k, n->k)) into v_diff
    from jsonb_object_keys(coalesce(n, o)) k where k not in ('updated_at', 'doc') and (o is null or n is null or o->k is distinct from n->k);
  if tg_op = 'UPDATE' and v_diff is null then return new; end if;
  v_prop := coalesce(nullif(coalesce(n, o)->>'property_id', ''), case when tg_table_name = 'properties' then coalesce(n, o)->>'id' end)::uuid;
  v_action := case tg_table_name
    when 'subscriptions' then 'subscription_changed'
    when 'subscription_payments' then case when tg_op = 'UPDATE' and n->>'status' is distinct from o->>'status' then 'payment_' || (n->>'status') else 'payment_changed' end
    when 'plans' then 'plan_changed' when 'platform_settings' then 'settings_changed' when 'properties' then lower(tg_op) || '_property'
    when 'coupons' then lower(tg_op) || '_coupon' when 'leads' then 'lead_changed' when 'platform_admins' then lower(tg_op) || '_admin'
    else lower(tg_op) || '_' || tg_table_name end;
  insert into public.admin_actions (admin_id, admin_email, action, property_id, details)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), v_action, v_prop,
          jsonb_build_object('table', tg_table_name, 'changes', v_diff, 'key', coalesce(n, o)->>'id', 'code', coalesce(n, o)->>'code', 'name', coalesce(n, o)->>'name'));
  return coalesce(new, old);
end $$;
do $$ declare t text; begin
  foreach t in array array['subscriptions','subscription_payments','plans','platform_settings','properties','coupons','leads','platform_admins'] loop
    execute format('drop trigger if exists admin_audit on public.%I', t);
    execute format('create trigger admin_audit after insert or update or delete on public.%I for each row execute function public._admin_audit()', t);
  end loop;
end $$;

create or replace function public.admin_actions_list(p_limit int default 200, p_property uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'admin_email', a.admin_email, 'action', a.action,
            'property_id', a.property_id, 'property', p.name, 'details', a.details) order by a.at desc), '[]'::jsonb)
          from (select * from public.admin_actions where p_property is null or property_id = p_property order by at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) a
          left join public.properties p on p.id = a.property_id);
end $$;

-- ---------------------------------------------------------------- 5. lead → property
alter table public.leads add column if not exists property_id uuid references public.properties(id) on delete set null;
create or replace function public.admin_lead_converted(p_lead uuid, p_property uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  update public.leads set property_id = p_property, status = 'won' where id = p_lead;
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public.admin_health(), public.admin_revenue(), public._coupon_quote(text, text), public.check_coupon(uuid, text, text),
  public.submit_subscription_payment(uuid, text, text, text), public._coupon_used(), public.admin_coupons(), public.admin_save_coupon(jsonb),
  public._admin_audit(), public.admin_actions_list(int, uuid), public.admin_lead_converted(uuid, uuid) from public, anon, authenticated;
grant execute on function public.admin_health(), public.admin_revenue(), public.check_coupon(uuid, text, text), public.submit_subscription_payment(uuid, text, text, text),
  public.admin_coupons(), public.admin_save_coupon(jsonb), public.admin_actions_list(int, uuid), public.admin_lead_converted(uuid, uuid) to authenticated;
