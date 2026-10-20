-- =====================================================================
-- NammaStay · 021_expenses_paylinks.sql
--   1. Expenses & profit — record spending; profit = money received
--      (payments − refunds) − expenses, per period and per month.
--      Needs the "See reports & revenue" permission (017).
--   2. Online payment links (Razorpay) — each property connects its own
--      Razorpay account (keys stored write-only, never readable from the
--      app). Staff create a link for a booking's balance; when the guest
--      pays, the `razorpay` edge function records the payment
--      automatically (webhook, or "check status" when the booking opens).
-- Run AFTER 020_ota_sync.sql. Then deploy the `razorpay` edge function
-- (docs/GO-LIVE.md §36).
-- =====================================================================

-- =====================================================================
-- 1. Expenses & profit
-- =====================================================================
create table if not exists public.expenses (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  spent_on     date not null default current_date,
  category     text not null default 'other' check (category in ('rent','salaries','electricity','water','internet','supplies','laundry',
                 'repairs','ota_commission','marketing','food','taxes','other')),
  amount_paise int  not null check (amount_paise between 1 and 100000000),
  method       text not null default 'cash' check (method in ('cash','upi','card','bank')),
  vendor       text check (char_length(vendor) <= 80),
  note         text check (char_length(note) <= 300),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create index if not exists expenses_prop_day on public.expenses (property_id, spent_on desc);
alter table public.expenses enable row level security;
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager','accountant']::public.member_role[]))
         and public._allowed(property_id, 'view_reports'));
revoke all on public.expenses from anon, authenticated;
grant select on public.expenses to authenticated;

-- p: { id?, spent_on, category, amount_paise, method, vendor, note }
create or replace function public.save_expense(p_property uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_amt int := nullif(p->>'amount_paise', '')::int; v_day date := coalesce(nullif(p->>'spent_on', '')::date, public._local_date(p_property, now()));
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_reports');
  if v_amt is null or v_amt < 1 then raise exception 'Enter the amount.'; end if;
  if v_day > public._local_date(p_property, now()) + 31 then raise exception 'That date is too far in the future.'; end if;
  if nullif(p->>'id', '') is null then
    insert into public.expenses (property_id, spent_on, category, amount_paise, method, vendor, note)
    values (p_property, v_day, coalesce(nullif(p->>'category', ''), 'other'), v_amt, coalesce(nullif(p->>'method', ''), 'cash'),
            nullif(left(btrim(coalesce(p->>'vendor', '')), 80), ''), nullif(left(btrim(coalesce(p->>'note', '')), 300), ''))
    returning id into v_id;
  else
    update public.expenses set spent_on = v_day, category = coalesce(nullif(p->>'category', ''), category), amount_paise = v_amt,
           method = coalesce(nullif(p->>'method', ''), method), vendor = nullif(left(btrim(coalesce(p->>'vendor', '')), 80), ''),
           note = nullif(left(btrim(coalesce(p->>'note', '')), 300), '')
     where id = (p->>'id')::uuid and property_id = p_property returning id into v_id;
    if v_id is null then raise exception 'Expense not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.delete_expense(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.expenses where id = p_id;
  if v_prop is null then raise exception 'Expense not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(v_prop, 'view_reports');
  delete from public.expenses where id = p_id;
end $$;

-- Revenue = money received (payments − refunds) by date received; expenses by date spent.
create or replace function public.profit_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; v_rev bigint; v_exp bigint; v_m0 date;
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_reports');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid period.'; end if;
  select timezone into v_tz from public.properties where id = p_property;
  select coalesce(sum(case when kind = 'refund' then -amount_paise else amount_paise end), 0) into v_rev
    from public.payments where property_id = p_property and (received_at at time zone v_tz)::date between p_from and p_to;
  select coalesce(sum(amount_paise), 0) into v_exp from public.expenses where property_id = p_property and spent_on between p_from and p_to;
  v_m0 := (date_trunc('month', p_to) - interval '5 months')::date;
  return jsonb_build_object(
    'revenue_paise', v_rev, 'expenses_paise', v_exp, 'profit_paise', v_rev - v_exp,
    'margin', case when v_rev > 0 then round((v_rev - v_exp) * 100.0 / v_rev, 1) else null end,
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'total_paise', t) order by t desc), '[]'::jsonb)
                      from (select category, sum(amount_paise) t from public.expenses
                             where property_id = p_property and spent_on between p_from and p_to group by category) c),
    'months', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'),
                 'revenue_paise', (select coalesce(sum(case when kind = 'refund' then -amount_paise else amount_paise end), 0) from public.payments
                                    where property_id = p_property and date_trunc('month', (received_at at time zone v_tz)::date) = m),
                 'expenses_paise', (select coalesce(sum(amount_paise), 0) from public.expenses
                                     where property_id = p_property and date_trunc('month', spent_on) = m)) order by m), '[]'::jsonb)
               from generate_series(v_m0, date_trunc('month', p_to)::date, interval '1 month') m));
end $$;

-- =====================================================================
-- 2. Online payment links (Razorpay)
-- =====================================================================
-- Keys live here. No policies + no grants → readable only by the server (service role).
create table if not exists public.property_secrets (
  property_id         uuid primary key references public.properties(id) on delete cascade,
  rzp_key_id          text check (rzp_key_id ~ '^rzp_(test|live)_[A-Za-z0-9]{8,32}$'),
  rzp_key_secret      text check (char_length(rzp_key_secret) between 8 and 120),
  rzp_webhook_secret  text check (char_length(rzp_webhook_secret) between 6 and 120),
  updated_at          timestamptz not null default now()
);
alter table public.property_secrets enable row level security;
revoke all on public.property_secrets from anon, authenticated;

create table if not exists public.payment_links (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null,
  booking_id     uuid not null,
  rzp_link_id    text not null unique,
  short_url      text not null,
  amount_paise   int  not null check (amount_paise > 0),
  status         text not null default 'created' check (status in ('created','paid','cancelled','expired')),
  rzp_payment_id text,
  payment_id     uuid,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  paid_at        timestamptz,
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index if not exists payment_links_booking on public.payment_links (booking_id, created_at desc);
alter table public.payment_links enable row level security;
drop policy if exists payment_links_select on public.payment_links;
create policy payment_links_select on public.payment_links for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager','front_desk','accountant']::public.member_role[])));
revoke all on public.payment_links from anon, authenticated;
grant select on public.payment_links to authenticated;

-- Owner connects Razorpay. Leave a secret empty to keep the saved one.
create or replace function public.set_razorpay_keys(p_property uuid, p_key_id text, p_key_secret text, p_webhook_secret text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id text := nullif(btrim(coalesce(p_key_id, '')), '');
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if v_id is null then                                             -- disconnect
    delete from public.property_secrets where property_id = p_property; return;
  end if;
  if v_id !~ '^rzp_(test|live)_[A-Za-z0-9]{8,32}$' then raise exception 'The Key ID looks like rzp_live_XXXXXXXX (Razorpay → Account & Settings → API Keys).'; end if;
  insert into public.property_secrets (property_id, rzp_key_id, rzp_key_secret, rzp_webhook_secret)
  values (p_property, v_id, nullif(btrim(coalesce(p_key_secret, '')), ''), nullif(btrim(coalesce(p_webhook_secret, '')), ''))
  on conflict (property_id) do update set rzp_key_id = excluded.rzp_key_id,
    rzp_key_secret = coalesce(excluded.rzp_key_secret, public.property_secrets.rzp_key_secret),
    rzp_webhook_secret = coalesce(excluded.rzp_webhook_secret, public.property_secrets.rzp_webhook_secret), updated_at = now();
  if (select rzp_key_secret from public.property_secrets where property_id = p_property) is null then
    raise exception 'Enter the Key Secret too.';
  end if;
end $$;

create or replace function public.razorpay_status(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.property_secrets%rowtype;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select * into s from public.property_secrets where property_id = p_property;
  return jsonb_build_object('connected', s.rzp_key_id is not null and s.rzp_key_secret is not null,
    'mode', case when s.rzp_key_id like 'rzp_live_%' then 'live' when s.rzp_key_id like 'rzp_test_%' then 'test' end,
    'key_hint', case when s.rzp_key_id is not null then left(s.rzp_key_id, 9) || '…' || right(s.rzp_key_id, 4) end,
    'webhook', s.rzp_webhook_secret is not null, 'updated_at', s.updated_at);
end $$;

-- Staff ask for a link (checks role, "Take payments" permission and the amount)
create or replace function public.paylink_prepare(p_booking uuid, p_amount int) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b public.bookings%rowtype; g public.guests%rowtype; p public.properties%rowtype;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  perform public._require_perm(b.property_id, 'record_payments');
  if b.status in ('cancelled','no_show') then raise exception 'This booking is cancelled.'; end if;
  if b.balance_paise <= 0 then raise exception 'Nothing is due on this booking.'; end if;
  if p_amount is null or p_amount < 100 or p_amount > b.balance_paise then
    raise exception 'Amount must be between ₹1 and the balance (₹%).', to_char(b.balance_paise / 100.0, 'FM99,99,99,990.00');
  end if;
  if not exists (select 1 from public.property_secrets where property_id = b.property_id and rzp_key_secret is not null) then
    raise exception 'Connect Razorpay first: Settings → Property details → Online payments.';
  end if;
  select * into g from public.guests where id = b.guest_id;
  select * into p from public.properties where id = b.property_id;
  return jsonb_build_object('booking_id', b.id, 'property_id', b.property_id, 'code', b.code, 'amount_paise', p_amount,
    'guest_name', g.full_name, 'guest_phone', g.phone, 'guest_email', g.email, 'property_name', p.name);
end $$;

create or replace function public.paylink_list(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.bookings where id = p_booking;
  if v_prop is null then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'rzp_link_id', l.rzp_link_id, 'short_url', l.short_url, 'amount_paise', l.amount_paise,
            'status', l.status, 'created_at', l.created_at, 'paid_at', l.paid_at) order by l.created_at desc), '[]'::jsonb)
          from public.payment_links l where l.booking_id = p_booking);
end $$;

-- ---------- server only (razorpay edge function, service role) ----------
create or replace function public.paylink_keys(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('key_id', rzp_key_id, 'key_secret', rzp_key_secret, 'webhook_secret', rzp_webhook_secret)
    from public.property_secrets where property_id = p_property
$$;

create or replace function public.paylink_store(p_property uuid, p_booking uuid, p_link_id text, p_url text, p_amount int, p_user uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into public.payment_links (property_id, booking_id, rzp_link_id, short_url, amount_paise, created_by)
  values (p_property, p_booking, p_link_id, p_url, p_amount, p_user) returning id into v_id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (p_property, 'booking', p_booking, p_booking, 'paylink_created', jsonb_build_object('amount_paise', p_amount, 'url', p_url), p_user);
  return v_id;
end $$;

-- Idempotent: a link is recorded as paid only once (webhook + status check can both arrive)
create or replace function public.paylink_mark_paid(p_link_id text, p_payment_id text, p_method text, p_amount int) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.payment_links%rowtype; b public.bookings%rowtype; v_amt int; v_pay uuid; v_method public.payment_method;
begin
  select * into l from public.payment_links where rzp_link_id = p_link_id for update;
  if not found then return jsonb_build_object('error', 'unknown link'); end if;
  if l.status = 'paid' then return jsonb_build_object('already', true); end if;
  select * into b from public.bookings where id = l.booking_id for update;
  v_amt := least(coalesce(p_amount, l.amount_paise), greatest(b.balance_paise, 0));
  v_method := case lower(coalesce(p_method, '')) when 'card' then 'card' when 'upi' then 'upi' else 'bank' end;
  if v_amt > 0 then
    insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, note, received_by)
    values (b.property_id, b.id, 'payment', v_method, v_amt, left(p_payment_id, 64), 'Paid online — Razorpay payment link', l.created_by)
    returning id into v_pay;
  end if;
  update public.payment_links set status = 'paid', rzp_payment_id = p_payment_id, payment_id = v_pay, paid_at = now() where id = l.id;
  insert into public.notifications (property_id, kind, title, body, booking_id)
  values (b.property_id, 'payment', 'Online payment received',
          format('%s · %s paid by %s via payment link', b.code, '₹' || to_char(coalesce(p_amount, l.amount_paise) / 100.0, 'FM99,99,99,990.00'), upper(coalesce(p_method, 'online'))), b.id);
  return jsonb_build_object('recorded_paise', v_amt, 'payment_id', v_pay);
end $$;

create or replace function public.paylink_set_status(p_link_id text, p_status text) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.payment_links set status = p_status where rzp_link_id = p_link_id and status = 'created' and p_status in ('cancelled','expired')
$$;

-- ---------- permissions ----------
revoke execute on function public.save_expense(uuid, jsonb), public.delete_expense(uuid), public.profit_summary(uuid, date, date),
  public.set_razorpay_keys(uuid, text, text, text), public.razorpay_status(uuid), public.paylink_prepare(uuid, int), public.paylink_list(uuid),
  public.paylink_keys(uuid), public.paylink_store(uuid, uuid, text, text, int, uuid), public.paylink_mark_paid(text, text, text, int),
  public.paylink_set_status(text, text) from public, anon, authenticated;
grant execute on function public.save_expense(uuid, jsonb), public.delete_expense(uuid), public.profit_summary(uuid, date, date),
  public.set_razorpay_keys(uuid, text, text, text), public.razorpay_status(uuid), public.paylink_prepare(uuid, int), public.paylink_list(uuid)
  to authenticated;
grant execute on function public.paylink_keys(uuid), public.paylink_store(uuid, uuid, text, text, int, uuid),
  public.paylink_mark_paid(text, text, text, int), public.paylink_set_status(text, text) to service_role;
