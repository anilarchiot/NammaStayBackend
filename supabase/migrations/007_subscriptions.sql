-- =====================================================================
-- NammaStay · 007_subscriptions.sql
-- Subscription model: flat price per property, 15-day free trial,
-- owners pay by UPI to YOUR UPI ID and submit the UTR; you approve.
--
--   • platform_settings   your UPI ID, trial length, grace days
--   • plans               monthly / yearly prices (edit anytime)
--   • subscriptions       one row per property: trial end, paid-until
--   • subscription_payments  UTRs submitted by owners, approved by you
--
-- Enforced in the database: when access has expired (after grace days),
-- NEW bookings, new/changed rooms & beds, new bed blocks and new staff
-- are refused. Existing guests can still be checked out and paid, and all
-- data stays readable and exportable.
--
-- Run AFTER 001–003 and 006. Existing properties (your own hostel) are
-- marked complimentary at the end of this file — they never expire.
-- =====================================================================

-- ---------- Settings (single row) ----------
create table public.platform_settings (
  id          int primary key default 1 check (id = 1),
  upi_id      text check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,256}@[A-Za-z]{2,64}$'),
  payee_name  text not null default 'NammaStay',
  trial_days  int  not null default 15 check (trial_days between 0 and 90),
  grace_days  int  not null default 3  check (grace_days between 0 and 30),
  support_whatsapp text,
  support_email    text,
  updated_at  timestamptz not null default now()
);
insert into public.platform_settings (id) values (1) on conflict do nothing;

-- ---------- Plans ----------
create table public.plans (
  id            text primary key check (id ~ '^[a-z0-9_]{2,30}$'),
  name          text not null,
  period_months int  not null check (period_months between 1 and 36),
  price_paise   int  not null check (price_paise between 0 and 100000000),
  description   text,
  is_active     boolean not null default true,
  sort          int not null default 0
);
-- Prices: ₹1,650/month, ₹16,500/year (2 months free). Change anytime in the app: Subscribers → Billing settings.
insert into public.plans (id, name, period_months, price_paise, description, sort) values
  ('monthly', 'Monthly', 1,  165000,  'Billed every month', 1),
  ('yearly',  'Yearly',  12, 1650000, '2 months free',       2)
on conflict (id) do nothing;

-- ---------- One subscription per property ----------
create table public.subscriptions (
  property_id      uuid primary key references public.properties(id) on delete cascade,
  plan_id          text references public.plans(id),
  trial_ends_at    timestamptz not null,
  paid_until       timestamptz,
  is_complimentary boolean not null default false,   -- free forever (your own hostel, partners)
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index subscriptions_paid_until on public.subscriptions (paid_until);
create trigger subscriptions_touch before update on public.subscriptions
  for each row execute function public._touch_updated_at();

create type public.sub_payment_status as enum ('pending','approved','rejected');

create table public.subscription_payments (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  plan_id       text not null references public.plans(id),
  amount_paise  int  not null check (amount_paise >= 0),
  utr           text not null check (utr ~ '^[0-9A-Z]{6,35}$'),
  status        public.sub_payment_status not null default 'pending',
  submitted_by  uuid default auth.uid(),
  submitted_at  timestamptz not null default now(),
  reviewed_by   uuid,
  reviewed_at   timestamptz,
  review_note   text check (char_length(review_note) <= 500),
  period_start  timestamptz,
  period_end    timestamptz
);
create unique index subscription_payments_utr on public.subscription_payments (utr) where status <> 'rejected';
create index subscription_payments_pending on public.subscription_payments (status, submitted_at desc);
create index subscription_payments_property on public.subscription_payments (property_id, submitted_at desc);

-- New properties start a free trial automatically
create or replace function public._properties_start_trial() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.subscriptions (property_id, trial_ends_at)
  values (new.id, now() + make_interval(days => (select trial_days from public.platform_settings where id = 1)))
  on conflict (property_id) do nothing;
  return new;
end $$;
create trigger properties_start_trial after insert on public.properties
  for each row execute function public._properties_start_trial();

-- ---------- Access state ----------
-- complimentary | trial | active | grace | expired
create or replace function public._access_state(p_property uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; v_end timestamptz; v_grace int;
begin
  select * into s from public.subscriptions where property_id = p_property;
  if not found then return 'expired'; end if;
  if s.is_complimentary then return 'complimentary'; end if;
  if s.paid_until is not null and s.paid_until > now() then return 'active'; end if;
  if s.trial_ends_at > now() and (s.paid_until is null or s.paid_until <= now()) then return 'trial'; end if;
  v_end := greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at));
  select grace_days into v_grace from public.platform_settings where id = 1;
  if now() < v_end + make_interval(days => v_grace) then return 'grace'; end if;
  return 'expired';
end $$;

create or replace function public.property_access(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; v_state text; v_end timestamptz;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select * into s from public.subscriptions where property_id = p_property;
  v_state := public._access_state(p_property);
  v_end := case v_state when 'trial' then s.trial_ends_at
                        when 'active' then s.paid_until
                        else greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at)) end;
  return jsonb_build_object(
    'state', v_state, 'plan_id', s.plan_id, 'trial_ends_at', s.trial_ends_at, 'paid_until', s.paid_until,
    'ends_at', v_end,
    'days_left', case when v_state in ('trial','active') then greatest(0, ceil(extract(epoch from (v_end - now())) / 86400))::int end,
    'grace_days', (select grace_days from public.platform_settings where id = 1),
    'pending_payment', exists (select 1 from public.subscription_payments where property_id = p_property and status = 'pending'));
end $$;

-- ---------- Database-level enforcement ----------
create or replace function public._require_access() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public._access_state(new.property_id) = 'expired' then
    raise exception 'This property''s NammaStay subscription has ended. The owner can renew in Settings → Billing.'
      using errcode = 'P0402', hint = 'subscription_expired';
  end if;
  return new;
end $$;
create trigger bookings_require_access   before insert on public.bookings          for each row execute function public._require_access();
create trigger bed_blocks_require_access before insert on public.bed_blocks        for each row execute function public._require_access();
create trigger rooms_require_access      before insert or update on public.rooms    for each row execute function public._require_access();
create trigger beds_require_access       before insert or update on public.beds     for each row execute function public._require_access();
create trigger members_require_access    before insert on public.property_members  for each row execute function public._require_access();

-- ---------- Self sign-up: create your own property (starts the trial) ----------
create or replace function public.create_my_property(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_email text; v_prop uuid;
begin
  if v_uid is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  if exists (select 1 from public.property_members where user_id = v_uid) then
    raise exception 'Your account already has a property. To add another, contact NammaStay support.';
  end if;
  if coalesce(char_length(btrim(p->>'name')), 0) < 2 then raise exception 'Please enter your property name.'; end if;
  select email into v_email from auth.users where id = v_uid;

  insert into public.properties (name, kind, city, phone, email)
  values (left(btrim(p->>'name'), 120),
          coalesce(nullif(p->>'kind', ''), 'hostel'),
          left(nullif(btrim(p->>'city'), ''), 80),
          left(nullif(btrim(p->>'phone'), ''), 20),
          v_email)
  returning id into v_prop;                         -- trigger starts the free trial

  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (v_prop, v_uid, 'owner', left(nullif(btrim(p->>'owner_name'), ''), 80), v_email);

  return jsonb_build_object('property_id', v_prop,
    'trial_ends_at', (select trial_ends_at from public.subscriptions where property_id = v_prop));
end $$;

-- ---------- Billing screen for owners ----------
create or replace function public.billing_info(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return jsonb_build_object(
    'access', public.property_access(p_property),
    'plans', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort), '[]'::jsonb) from public.plans x where x.is_active),
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
  select * into v_plan from public.plans where id = p_plan and is_active;
  if not found then raise exception 'Choose a plan.'; end if;
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

-- ---------- Your admin screen (platform admins only) ----------
create or replace function public._assert_platform_admin() returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
end $$;

create or replace function public.admin_subscriptions(p_q text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := nullif(btrim(p_q), '');
begin
  perform public._assert_platform_admin();
  return jsonb_build_object(
    'settings', (select to_jsonb(s) from public.platform_settings s where id = 1),
    'plans', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort), '[]'::jsonb) from public.plans x),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('id', sp.id, 'property_id', sp.property_id, 'property', p.name,
                  'plan_id', sp.plan_id, 'amount_paise', sp.amount_paise, 'utr', sp.utr, 'submitted_at', sp.submitted_at,
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

create or replace function public.admin_review_subscription_payment(p_id uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare sp public.subscription_payments%rowtype; s public.subscriptions%rowtype; v_plan public.plans%rowtype; v_start timestamptz; v_end timestamptz;
begin
  perform public._assert_platform_admin();
  select * into sp from public.subscription_payments where id = p_id for update;
  if not found then raise exception 'Payment not found.'; end if;
  if sp.status <> 'pending' then raise exception 'This payment was already reviewed.'; end if;

  if not p_approve then
    update public.subscription_payments set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
           review_note = nullif(btrim(p_note), '') where id = p_id;
    return jsonb_build_object('status', 'rejected');
  end if;

  select * into s from public.subscriptions where property_id = sp.property_id for update;
  select * into v_plan from public.plans where id = sp.plan_id;
  -- Paying during the trial doesn't lose trial days; renewing early doesn't lose paid days.
  v_start := greatest(now(), coalesce(s.paid_until, now()), s.trial_ends_at);
  v_end := v_start + make_interval(months => v_plan.period_months);
  update public.subscriptions set paid_until = v_end, plan_id = v_plan.id where property_id = sp.property_id;
  update public.subscription_payments set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = nullif(btrim(p_note), ''), period_start = v_start, period_end = v_end where id = p_id;
  insert into public.notifications (property_id, kind, title, body)
  values (sp.property_id, 'subscription', 'Subscription payment confirmed',
          'Paid until ' || to_char(v_end at time zone 'Asia/Kolkata', 'DD Mon YYYY'));
  return jsonb_build_object('status', 'approved', 'paid_until', v_end);
end $$;

-- Manual override: extend by N days, or give free access
create or replace function public.admin_update_subscription(p_property uuid, p_extend_days int default null, p_complimentary boolean default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  if p_extend_days is not null and (p_extend_days < -3650 or p_extend_days > 3650) then raise exception 'Enter a sensible number of days.'; end if;
  update public.subscriptions
     set paid_until = case when p_extend_days is null then paid_until
                           else greatest(now(), coalesce(paid_until, now()), trial_ends_at) + make_interval(days => p_extend_days) end,
         is_complimentary = coalesce(p_complimentary, is_complimentary)
   where property_id = p_property;
  if not found then raise exception 'Property not found.'; end if;
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
      is_active = coalesce((pl->>'is_active')::boolean, is_active)
    where id = pl->>'id';
  end loop;
end $$;

-- ---------- Security ----------
alter table public.platform_settings enable row level security;
alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.subscription_payments enable row level security;

-- Prices are public (the homepage shows them); everything else goes through the functions above.
create policy plans_public_read on public.plans for select to anon, authenticated using (is_active);
create policy subs_member_read on public.subscriptions for select to authenticated
  using (property_id in (select public.my_property_ids()) or public.is_platform_admin());
create policy subpay_read on public.subscription_payments for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])) or public.is_platform_admin());

revoke all on public.platform_settings, public.plans, public.subscriptions, public.subscription_payments from anon, authenticated;
grant select on public.plans to anon, authenticated;
grant select on public.subscriptions, public.subscription_payments to authenticated;

revoke execute on function
  public._access_state(uuid), public.property_access(uuid), public._require_access(), public._properties_start_trial(),
  public.create_my_property(jsonb), public.billing_info(uuid), public.submit_subscription_payment(uuid, text, text),
  public._assert_platform_admin(), public.admin_subscriptions(text), public.admin_review_subscription_payment(uuid, boolean, text),
  public.admin_update_subscription(uuid, int, boolean), public.admin_save_billing_settings(jsonb)
  from public, anon, authenticated;
grant execute on function
  public.property_access(uuid), public.create_my_property(jsonb), public.billing_info(uuid),
  public.submit_subscription_payment(uuid, text, text), public.admin_subscriptions(text),
  public.admin_review_subscription_payment(uuid, boolean, text), public.admin_update_subscription(uuid, int, boolean),
  public.admin_save_billing_settings(jsonb)
to authenticated;

-- ---------- Existing properties (your own hostel): free forever ----------
insert into public.subscriptions (property_id, trial_ends_at, is_complimentary)
select id, now(), true from public.properties
on conflict (property_id) do update set is_complimentary = true;
