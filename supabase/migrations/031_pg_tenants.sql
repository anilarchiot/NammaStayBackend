-- =====================================================================
-- NammaStay · 031_pg_tenants.sql — PG / co-living: tenants & monthly rent
--
-- A PG / co-living property is set up like a hostel (rooms & beds; plans
-- "Hostels & PGs") and marked as PG in pg_properties (sign-up / Settings → Type).
-- Only those properties get this separate module for monthly tenants:
--   • tenancies      who lives in which bed, rent, food, deposit, notice
--   • rent_dues      monthly rent / food (created automatically), deposit,
--                    electricity and other charges
--   • rent_payments  money received (receipt numbers RC-…), deposit used
--                    against dues, deposit refunds
--
-- The tenant's bed is held with a normal booking at ₹0 (rent lives here), so
-- the calendar, occupancy, housekeeping, online check-in link and "no double
-- booking" rule all keep working. Bookings are made in yearly segments; the
-- next segment is added automatically 30 days before the current one ends.
--
-- ADD-ON ONLY: new tables + new functions. No existing table, function or
-- trigger is changed. Safe to run more than once. Run after 001–030.
-- Optional daily job (rent created even if nobody opens the page):
--   supabase/setup/pg_schedule.sql
-- =====================================================================

create sequence if not exists public.rent_receipt_seq start 1001;

-- Which properties are PG / co-living (the Tenants & rent page is only for them).
-- A PG is set up like a hostel (beds); this switch is set at sign-up or in Settings → Type.
create table if not exists public.pg_properties (
  property_id uuid primary key references public.properties(id) on delete cascade,
  enabled_at  timestamptz not null default now(),
  enabled_by  uuid default auth.uid()
);
alter table public.pg_properties enable row level security;
drop policy if exists pg_properties_select on public.pg_properties;
create policy pg_properties_select on public.pg_properties for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.pg_properties from anon, authenticated;
grant select on public.pg_properties to authenticated;

create or replace function public.pg_mode(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.pg_properties where property_id = p_property)
     and exists (select 1 from public.property_members where property_id = p_property and user_id = auth.uid())
$$;

create or replace function public.pg_set_mode(p_property uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if p_on then
    if (select kind from public.properties where id = p_property) <> 'hostel' then
      raise exception 'PG / co-living works with beds — set the type to PG / Co-living (not hotel or homestay).';
    end if;
    insert into public.pg_properties (property_id) values (p_property) on conflict do nothing;
  else
    delete from public.pg_properties where property_id = p_property;
  end if;
  return p_on;
end $$;

create table if not exists public.tenancies (
  id              uuid primary key default gen_random_uuid(),
  property_id     uuid not null,
  guest_id        uuid not null,
  bed_id          uuid not null,
  booking_id      uuid,                                  -- current booking segment holding the bed
  booking_ids     uuid[] not null default '{}',          -- every segment (history)
  start_date      date not null,
  move_out_on     date,                                  -- day the tenant leaves (set with notice)
  notice_given_on date,
  status          text not null default 'active' check (status in ('active','notice','moved_out')),
  cycle           text not null default 'movein' check (cycle in ('movein','calendar')),
  rent_paise      int not null check (rent_paise between 0 and 100000000),
  food_paise      int not null default 0 check (food_paise between 0 and 100000000),
  deposit_paise   int not null default 0 check (deposit_paise between 0 and 100000000),
  notice_days     smallint not null default 30 check (notice_days between 0 and 180),
  note            text check (char_length(note) <= 1000),
  settled         jsonb,                                 -- move-out settlement summary
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, property_id),
  check (move_out_on is null or move_out_on >= start_date),
  foreign key (guest_id, property_id) references public.guests(id, property_id) on delete restrict,
  foreign key (bed_id,   property_id) references public.beds(id,   property_id) on delete restrict
);
create index if not exists tenancies_property on public.tenancies (property_id, status);
create index if not exists tenancies_bed on public.tenancies (bed_id);
create index if not exists tenancies_bookings on public.tenancies using gin (booking_ids);

create table if not exists public.rent_dues (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null,
  tenancy_id   uuid not null,
  kind         text not null check (kind in ('rent','food','deposit','electricity','maintenance','late_fee','damage','other')),
  period_start date,                                      -- rent / food: the month it covers
  period_end   date,                                      -- exclusive
  label        text not null check (char_length(label) between 1 and 80),
  due_on       date not null,
  amount_paise int not null check (amount_paise between 0 and 100000000),
  paid_paise   int not null default 0 check (paid_paise >= 0),
  edited       boolean not null default false,            -- changed by hand: automatic updates leave it alone
  credit_paise int not null default 0 check (credit_paise >= 0),   -- paid in advance but no longer owed (shorter last month) → returned at move-out
  note         text check (char_length(note) <= 300),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  check (paid_paise <= amount_paise),
  unique (tenancy_id, kind, period_start),
  foreign key (tenancy_id, property_id) references public.tenancies(id, property_id) on delete cascade
);
alter table public.rent_dues add column if not exists credit_paise int not null default 0 check (credit_paise >= 0);
create index if not exists rent_dues_tenancy on public.rent_dues (tenancy_id, due_on);
create index if not exists rent_dues_property on public.rent_dues (property_id, due_on);

create table if not exists public.rent_payments (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null,
  tenancy_id   uuid not null,
  due_id       uuid references public.rent_dues(id) on delete set null,
  code         text not null default ('RC-' || nextval('public.rent_receipt_seq')),
  kind         text not null check (kind in ('payment','deposit_adjust','refund')),
  amount_paise int not null check (amount_paise > 0),
  method       text not null check (method in ('upi','cash','card','bank','deposit')),
  reference    text check (char_length(reference) <= 80),
  note         text check (char_length(note) <= 200),
  received_at  timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  foreign key (tenancy_id, property_id) references public.tenancies(id, property_id) on delete cascade
);
create index if not exists rent_payments_tenancy on public.rent_payments (tenancy_id, received_at);
create index if not exists rent_payments_property on public.rent_payments (property_id, received_at);

alter table public.tenancies enable row level security;
alter table public.rent_dues enable row level security;
alter table public.rent_payments enable row level security;
drop policy if exists tenancies_select on public.tenancies;
create policy tenancies_select on public.tenancies for select to authenticated using (property_id in (select public.my_property_ids()));
drop policy if exists rent_dues_select on public.rent_dues;
create policy rent_dues_select on public.rent_dues for select to authenticated using (property_id in (select public.my_property_ids()));
drop policy if exists rent_payments_select on public.rent_payments;
create policy rent_payments_select on public.rent_payments for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.tenancies, public.rent_dues, public.rent_payments from anon, authenticated;
grant select on public.tenancies, public.rent_dues, public.rent_payments to authenticated;   -- writes only through the functions below

-- ---------------------------------------------------------------- tenant bookings stay at ₹0
-- Only for bookings that hold a tenant's bed: if staff move it on the calendar or edit it on the
-- booking page, the price stays ₹0 (+ any extras) and the tenant's bed follows the move.
-- Every other booking is left exactly as before (the trigger returns immediately).
create or replace function public._pg_keep_tenant_booking() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_t uuid; v_cur uuid;
begin
  select id, booking_id into v_t, v_cur from public.tenancies where booking_ids @> array[new.id] limit 1;
  if v_t is null then return new; end if;
  new.rate_paise := 0;
  new.discount_paise := 0;
  new.extra_paise := 0;
  new.total_paise := coalesce(new.charges_paise, 0);
  if new.bed_id is distinct from old.bed_id and new.id = v_cur then
    update public.tenancies set bed_id = new.bed_id, updated_at = now() where id = v_t;
  end if;
  return new;
end $$;
drop trigger if exists zz_pg_tenant_booking on public.bookings;
create trigger zz_pg_tenant_booking before update on public.bookings
  for each row execute function public._pg_keep_tenant_booking();   -- "zz": runs after the price-rules trigger

-- ---------------------------------------------------------------- helpers
create or replace function public._pg_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone public._tz(p_property))::date
$$;

-- Moment a tenant arrives / leaves on a given day (property check-in / check-out time)
create or replace function public._pg_at(p_property uuid, p_day date, p_out boolean) returns timestamptz
language sql stable security definer set search_path = public, pg_temp as $$
  select (p_day + case when p_out then p.checkout_time else p.checkin_time end) at time zone p.timezone
    from public.properties p where p.id = p_property
$$;

-- Insert a ₹0 booking that holds the bed for [p_from, p_to). Friendly error if the bed is taken.
create or replace function public._pg_hold(t public.tenancies, p_from date, p_to date, p_status public.booking_status, p_in timestamptz default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_in timestamptz; v_out timestamptz; v_id uuid; v_clash record;
begin
  v_in := coalesce(p_in, public._pg_at(t.property_id, p_from, false));    -- p_in: continue exactly where the last segment ends
  v_out := public._pg_at(t.property_id, p_to, true);
  if v_out <= v_in then v_out := v_in + interval '1 day'; end if;
  select b.code, b.check_in_at, (b.check_in_at at time zone public._tz(t.property_id))::date as d into v_clash
    from public.bookings b
   where b.bed_id = t.bed_id and b.status in ('pending','confirmed','checked_in')
     and b.stay && tstzrange(v_in, v_out, '[)') and not (b.id = any (t.booking_ids))
   order by b.check_in_at limit 1;
  if v_clash.code is not null then
    -- another booking later on this bed: hold the bed up to it; the page warns until it is sorted out
    if v_clash.check_in_at > greatest(v_in, now()) + interval '1 day' then
      v_out := v_clash.check_in_at;
    else
      raise exception 'This bed is taken from % (%). Choose another bed.', to_char(v_clash.d, 'DD Mon YYYY'), v_clash.code
        using errcode = 'P0409';
    end if;
  end if;
  perform set_config('nammastay.skip_rate_rules', '1', true);       -- rent is tracked in rent_dues, not on the booking
  insert into public.bookings (property_id, guest_id, bed_id, visitors, check_in_at, check_out_at, nights,
                               rate_paise, total_paise, status, source, note, arrived_at)
  values (t.property_id, t.guest_id, t.bed_id, 1, v_in, v_out,
          greatest(1, least(366, ceil(extract(epoch from (v_out - v_in)) / 86400)::int)),
          0, 0, p_status, 'direct', 'PG tenant — rent is in Tenants & rent',
          case when p_status = 'checked_in' then now() end)
  returning id into v_id;
  perform set_config('nammastay.skip_rate_rules', '', true);
  return v_id;
end $$;

-- Change the end of the current booking segment (notice / move-out / notice withdrawn)
create or replace function public._pg_set_end(p_booking uuid, p_property uuid, p_to date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; v_out timestamptz;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null then return; end if;
  v_out := greatest(public._pg_at(p_property, p_to, true), b.check_in_at + interval '1 day');
  v_out := least(v_out, b.check_in_at + interval '366 days');
  if v_out = b.check_out_at then return; end if;
  perform set_config('nammastay.skip_rate_rules', '1', true);
  update public.bookings set check_out_at = v_out,
         nights = greatest(1, least(366, ceil(extract(epoch from (v_out - b.check_in_at)) / 86400)::int))
   where id = p_booking;
  perform set_config('nammastay.skip_rate_rules', '', true);
end $$;

-- Close a finished segment without marking the bed "dirty" (the tenant is still there)
create or replace function public._pg_close_segment(p_booking uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bed uuid; v_hk record;
begin
  select bed_id into v_bed from public.bookings where id = p_booking and status in ('confirmed','checked_in');
  if v_bed is null then return; end if;
  select hk_status, hk_note, hk_updated_at, hk_by into v_hk from public.beds where id = v_bed;
  update public.bookings set status = 'checked_out', departed_at = check_out_at where id = p_booking;
  update public.beds set hk_status = v_hk.hk_status, hk_note = v_hk.hk_note, hk_updated_at = v_hk.hk_updated_at, hk_by = v_hk.hk_by where id = v_bed;
end $$;

-- Bring one tenancy up to date: bed segments + rent / food dues up to today
create or replace function public._pg_sync_one(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t public.tenancies; b public.bookings; v_today date; v_seg_from date; v_seg_to date; v_new uuid;
  k int := 0; p_s date; p_e date; full_e date; v_days int; v_full int; v_amt int; v_end date; v_lbl text;
begin
  select * into t from public.tenancies where id = p_id for update;
  if t.id is null or t.status = 'moved_out' then return; end if;
  v_today := public._pg_today(t.property_id);
  v_end := coalesce(t.move_out_on, 'infinity'::date);

  -- 1) bed segments
  if t.booking_id is not null then
    select * into b from public.bookings where id = t.booking_id;
    -- arrival day reached → checked in
    if b.status = 'confirmed' and (b.check_in_at at time zone public._tz(t.property_id))::date <= v_today then
      update public.bookings set status = 'checked_in', arrived_at = coalesce(arrived_at, now()) where id = b.id;
    end if;
    -- current segment ends within 30 days and the tenant stays on → add the next one
    v_seg_from := (b.check_out_at at time zone public._tz(t.property_id))::date;
    if v_seg_from <= v_today + 30 and v_seg_from < v_end then
      v_seg_to := least(v_seg_from + 365, v_end);
      begin
        v_new := public._pg_hold(t, v_seg_from, v_seg_to, 'confirmed', b.check_out_at);
        update public.tenancies set booking_id = v_new, booking_ids = booking_ids || v_new where id = t.id;
        t.booking_ids := t.booking_ids || v_new;
      exception when others then null;                       -- bed taken later: shown on the page as a warning
      end;
    end if;
    -- older segments whose time has passed → closed (bed stays as it is)
    perform public._pg_close_segment(x.id) from public.bookings x
      where x.id = any (t.booking_ids) and x.id <> coalesce((select booking_id from public.tenancies where id = t.id), x.id)
        and x.status in ('confirmed','checked_in') and x.check_out_at <= now();
  end if;

  -- 2) rent & food dues for every period that has started (last one prorated on move-out)
  loop
    if t.cycle = 'calendar' then
      p_s := case when k = 0 then t.start_date else (date_trunc('month', t.start_date) + make_interval(months => k))::date end;
      full_e := (date_trunc('month', p_s) + interval '1 month')::date;
      v_full := full_e - date_trunc('month', p_s)::date;
    else
      p_s := (t.start_date + make_interval(months => k))::date;
      full_e := (t.start_date + make_interval(months => k + 1))::date;
      v_full := full_e - p_s;
    end if;
    exit when p_s > v_today or p_s >= v_end or k > 600;
    p_e := least(full_e, v_end);
    v_days := p_e - p_s;
    v_lbl := to_char(p_s, 'Mon YYYY') || case when p_e < full_e or v_days < v_full then ' (' || v_days || ' days)' else '' end;
    if t.rent_paise > 0 then
      v_amt := round(t.rent_paise::numeric * v_days / v_full);
      insert into public.rent_dues (property_id, tenancy_id, kind, period_start, period_end, label, due_on, amount_paise)
      values (t.property_id, t.id, 'rent', p_s, p_e, 'Rent · ' || v_lbl, p_s, v_amt)
      on conflict (tenancy_id, kind, period_start) do update
        set amount_paise = greatest(excluded.amount_paise, rent_dues.paid_paise), period_end = excluded.period_end, label = excluded.label,
            credit_paise = greatest(0, rent_dues.paid_paise - excluded.amount_paise)
        where not rent_dues.edited and rent_dues.period_end is distinct from excluded.period_end;
    end if;
    if t.food_paise > 0 then
      v_amt := round(t.food_paise::numeric * v_days / v_full);
      insert into public.rent_dues (property_id, tenancy_id, kind, period_start, period_end, label, due_on, amount_paise)
      values (t.property_id, t.id, 'food', p_s, p_e, 'Food · ' || v_lbl, p_s, v_amt)
      on conflict (tenancy_id, kind, period_start) do update
        set amount_paise = greatest(excluded.amount_paise, rent_dues.paid_paise), period_end = excluded.period_end, label = excluded.label,
            credit_paise = greatest(0, rent_dues.paid_paise - excluded.amount_paise)
        where not rent_dues.edited and rent_dues.period_end is distinct from excluded.period_end;
    end if;
    k := k + 1;
  end loop;
  -- periods that start on/after the move-out day aren't owed: drop unpaid ones, and anything
  -- already paid for them becomes "paid ahead" (returned at move-out)
  delete from public.rent_dues d where d.tenancy_id = t.id and d.kind in ('rent','food')
     and d.period_start >= v_end and d.paid_paise = 0 and not d.edited;
  update public.rent_dues d set amount_paise = d.paid_paise, credit_paise = d.paid_paise, period_end = d.period_start,
         label = regexp_replace(d.label, ' \(.*\)$', '') || ' (not stayed)'
   where d.tenancy_id = t.id and d.kind in ('rent','food') and d.period_start >= v_end and d.paid_paise > 0 and not d.edited
     and d.credit_paise <> d.paid_paise;
end $$;

create or replace function public._pg_sync(p_property uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._pg_sync_one(id) from public.tenancies where property_id = p_property and status <> 'moved_out';
end $$;

-- Daily job for every property (optional schedule: setup/pg_schedule.sql)
create or replace function public.pg_run_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; r record;
begin
  for r in select distinct property_id from public.tenancies where status <> 'moved_out' loop
    perform public._pg_sync(r.property_id); n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public._pg_row(t public.tenancies, v_today date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', t.id, 'status', t.status, 'start_date', t.start_date, 'move_out_on', t.move_out_on, 'notice_given_on', t.notice_given_on,
    'cycle', t.cycle, 'rent_paise', t.rent_paise, 'food_paise', t.food_paise, 'deposit_paise', t.deposit_paise, 'notice_days', t.notice_days,
    'note', t.note, 'settled', t.settled, 'booking_id', t.booking_id,
    'guest', jsonb_build_object('id', g.id, 'full_name', g.full_name, 'phone', g.phone, 'id_type', g.id_type, 'id_number', g.id_number,
                                'has_id', g.id_doc_path is not null or g.id_doc_back_path is not null),
    'bed', jsonb_build_object('id', bd.id, 'label', bd.label, 'room', r.name),
    'due_paise', coalesce((select sum(amount_paise - paid_paise) from public.rent_dues d where d.tenancy_id = t.id and d.due_on <= v_today), 0),
    'overdue_paise', coalesce((select sum(amount_paise - paid_paise) from public.rent_dues d where d.tenancy_id = t.id and d.due_on < v_today - 5), 0),
    'upcoming_paise', coalesce((select sum(amount_paise - paid_paise) from public.rent_dues d where d.tenancy_id = t.id and d.due_on > v_today), 0),
    'deposit_held_paise', case when t.status = 'moved_out' then 0 else
        coalesce((select sum(paid_paise) from public.rent_dues d where d.tenancy_id = t.id and d.kind = 'deposit'), 0) end,
    'next_due_on', (select min(d.due_on) from public.rent_dues d where d.tenancy_id = t.id and d.amount_paise > d.paid_paise),
    'last_paid_at', (select max(received_at) from public.rent_payments p where p.tenancy_id = t.id and p.kind = 'payment'),
    'self_checkin_token', (select bk.self_checkin_token from public.bookings bk where bk.id = t.booking_id),
    'self_checkin_at', (select max(bk.self_checkin_at) from public.bookings bk where bk.id = any (t.booking_ids)),
    'held_until', (select (bk.check_out_at at time zone public._tz(t.property_id))::date from public.bookings bk where bk.id = t.booking_id),
    'hold_warning', case when t.status <> 'moved_out' and (select bk.check_out_at from public.bookings bk where bk.id = t.booking_id)
                              <= now() + interval '45 days'
                          and coalesce(t.move_out_on, 'infinity'::date) > (select (bk.check_out_at at time zone public._tz(t.property_id))::date from public.bookings bk where bk.id = t.booking_id)
                         and not exists (select 1 from public.bookings nx where nx.id = any (t.booking_ids) and nx.check_in_at >= (select bk.check_out_at from public.bookings bk where bk.id = t.booking_id) and nx.id <> t.booking_id)
                         then 'Bed is held for this tenant only until ' || to_char((select (bk.check_out_at at time zone public._tz(t.property_id))::date from public.bookings bk where bk.id = t.booking_id), 'DD Mon')
                              || ' — another guest is booked on it soon after. Drag the tenant to a free bed on the Calendar, or move that booking.' end)
  from public.guests g, public.beds bd, public.rooms r
  where g.id = t.guest_id and bd.id = t.bed_id and r.id = bd.room_id
$$;

-- ---------------------------------------------------------------- list (keeps everything up to date first)
create or replace function public.pg_tenants(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date; v_month date;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._pg_sync(p_property);
  v_today := public._pg_today(p_property);
  v_month := date_trunc('month', v_today)::date;
  return jsonb_build_object(
    'today', v_today,
    'property', (select jsonb_build_object('name', name, 'upi_id', upi_id, 'phone', phone) from public.properties where id = p_property),
    'tenants', coalesce((select jsonb_agg(public._pg_row(t, v_today) order by (t.status = 'moved_out'), t.start_date desc)
                           from public.tenancies t where t.property_id = p_property), '[]'::jsonb),
    'summary', jsonb_build_object(
      'active', (select count(*) from public.tenancies where property_id = p_property and status = 'active'),
      'notice', (select count(*) from public.tenancies where property_id = p_property and status = 'notice'),
      'rent_roll_paise', coalesce((select sum(rent_paise + food_paise) from public.tenancies where property_id = p_property and status <> 'moved_out'), 0),
      'collected_month_paise', coalesce((select sum(p.amount_paise) from public.rent_payments p left join public.rent_dues d on d.id = p.due_id
                                          where p.property_id = p_property and p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit'
                                            and (p.received_at at time zone public._tz(p_property))::date >= v_month), 0),
      'due_now_paise', coalesce((select sum(d.amount_paise - d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                  where d.property_id = p_property and d.due_on <= v_today and t.status <> 'moved_out'), 0),
      'tenants_due', (select count(distinct d.tenancy_id) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                       where d.property_id = p_property and d.due_on <= v_today and d.amount_paise > d.paid_paise and t.status <> 'moved_out'),
      'deposits_held_paise', coalesce((select sum(d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                        where d.property_id = p_property and d.kind = 'deposit' and t.status <> 'moved_out'), 0)));
end $$;

-- ---------------------------------------------------------------- one tenant (ledger)
create or replace function public.pg_tenant(p_tenancy uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.tenancies;
begin
  select * into t from public.tenancies where id = p_tenancy;
  if t.id is null then raise exception 'Tenant not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(t.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._pg_sync_one(t.id);
  select * into t from public.tenancies where id = p_tenancy;
  return public._pg_row(t, public._pg_today(t.property_id)) || jsonb_build_object(
    'property', (select jsonb_build_object('name', name, 'upi_id', upi_id) from public.properties where id = t.property_id),
    'dues', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'label', d.label, 'due_on', d.due_on,
               'period_start', d.period_start, 'period_end', d.period_end, 'amount_paise', d.amount_paise, 'paid_paise', d.paid_paise,
               'edited', d.edited, 'note', d.note, 'credit_paise', d.credit_paise) order by d.due_on desc, d.created_at desc)
             from public.rent_dues d where d.tenancy_id = t.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'kind', p.kind, 'amount_paise', p.amount_paise,
               'method', p.method, 'reference', p.reference, 'note', p.note, 'received_at', p.received_at,
               'for', (select label from public.rent_dues d where d.id = p.due_id)) order by p.received_at desc, p.code desc)
             from public.rent_payments p where p.tenancy_id = t.id), '[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'status', b.status,
               'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at) order by b.check_in_at)
             from public.bookings b where b.id = any (t.booking_ids)), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- move in
-- p: { guest_id? | guest:{full_name, phone, nationality, id_type, id_number, id_doc_path, id_doc_back_path},
--      bed_id, start_date, rent_paise, food_paise, deposit_paise, deposit_paid_paise, method, reference,
--      cycle ('movein'|'calendar'), notice_days, note }
create or replace function public.pg_move_in(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_guest uuid := nullif(p->>'guest_id', '')::uuid; v_bed uuid := (p->>'bed_id')::uuid;
  v_start date := coalesce(nullif(p->>'start_date', '')::date, public._pg_today(p_property));
  v_today date := public._pg_today(p_property);
  t public.tenancies; v_bk uuid; v_dep uuid; v_paid int := coalesce(nullif(p->>'deposit_paid_paise', '')::int, 0);
  v_type public.id_doc_type;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  if not exists (select 1 from public.pg_properties where property_id = p_property) then
    raise exception 'Tenants & rent is for PG / co-living properties. Set the property type to PG / Co-living in Settings.';
  end if;
  if not exists (select 1 from public.beds where id = v_bed and property_id = p_property and is_active) then
    raise exception 'Choose a bed.';
  end if;
  if exists (select 1 from public.tenancies where bed_id = v_bed and status <> 'moved_out'
              and coalesce(move_out_on, 'infinity'::date) > v_start) then
    raise exception 'Another tenant already lives in this bed. Choose another bed.' using errcode = 'P0409';
  end if;
  if v_start < v_today - 62 then raise exception 'The move-in date can be at most 2 months in the past.'; end if;
  if coalesce(nullif(p->>'rent_paise', '')::int, 0) <= 0 then raise exception 'Enter the monthly rent.'; end if;

  if v_guest is null then
    if char_length(btrim(coalesce(p#>>'{guest,full_name}', ''))) < 2 then raise exception 'Enter the tenant''s full name.'; end if;
    v_type := nullif(p#>>'{guest,id_type}', '')::public.id_doc_type;
    insert into public.guests (property_id, full_name, phone, nationality, id_type, id_number, id_doc_path, id_doc_back_path, consent_at)
    values (p_property, btrim(p#>>'{guest,full_name}'), public._clean_phone(p#>>'{guest,phone}'),
            nullif(btrim(coalesce(p#>>'{guest,nationality}', '')), ''), v_type,
            public._mask_id(v_type::text, nullif(p#>>'{guest,id_number}', '')),
            nullif(p#>>'{guest,id_doc_path}', ''), nullif(p#>>'{guest,id_doc_back_path}', ''), now())
    returning id into v_guest;
  elsif not exists (select 1 from public.guests where id = v_guest and property_id = p_property) then
    raise exception 'Guest not found.';
  end if;

  insert into public.tenancies (property_id, guest_id, bed_id, start_date, cycle, rent_paise, food_paise, deposit_paise, notice_days, note)
  values (p_property, v_guest, v_bed, v_start, coalesce(nullif(p->>'cycle', ''), 'movein'),
          (p->>'rent_paise')::int, coalesce(nullif(p->>'food_paise', '')::int, 0), coalesce(nullif(p->>'deposit_paise', '')::int, 0),
          coalesce(nullif(p->>'notice_days', '')::smallint, 30), nullif(btrim(coalesce(p->>'note', '')), ''))
  returning * into t;

  v_bk := public._pg_hold(t, v_start, v_start + 365, case when v_start <= v_today then 'checked_in' else 'confirmed' end::public.booking_status);
  update public.tenancies set booking_id = v_bk, booking_ids = array[v_bk] where id = t.id;

  if t.deposit_paise > 0 then
    insert into public.rent_dues (property_id, tenancy_id, kind, period_start, label, due_on, amount_paise)
    values (p_property, t.id, 'deposit', v_start, 'Security deposit', v_start, t.deposit_paise) returning id into v_dep;
    if v_paid > 0 then
      perform public._require_perm(p_property, 'record_payments');
      if v_paid > t.deposit_paise then raise exception 'Deposit paid can''t be more than the deposit.'; end if;
      insert into public.rent_payments (property_id, tenancy_id, due_id, kind, amount_paise, method, reference, note)
      values (p_property, t.id, v_dep, 'payment', v_paid, coalesce(nullif(p->>'method', ''), 'upi'), nullif(p->>'reference', ''), 'Deposit');
      update public.rent_dues set paid_paise = v_paid where id = v_dep;
    end if;
  end if;
  perform public._pg_sync_one(t.id);
  return jsonb_build_object('id', t.id, 'booking_id', v_bk, 'guest_id', v_guest,
    'held_until', (select (check_out_at at time zone public._tz(p_property))::date from public.bookings where id = v_bk));
end $$;

-- ---------------------------------------------------------------- edit rent / food / deposit / notice days / note
create or replace function public.pg_update(p_tenancy uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.tenancies; v_dep int;
begin
  select * into t from public.tenancies where id = p_tenancy for update;
  if t.id is null then raise exception 'Tenant not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(t.property_id, array['owner','manager']::public.member_role[]);
  if t.status = 'moved_out' then raise exception 'This tenant has moved out.'; end if;
  v_dep := coalesce(nullif(p->>'deposit_paise', '')::int, t.deposit_paise);
  update public.tenancies set
    rent_paise = coalesce(nullif(p->>'rent_paise', '')::int, rent_paise),
    food_paise = coalesce(nullif(p->>'food_paise', '')::int, food_paise),
    deposit_paise = v_dep,
    notice_days = coalesce(nullif(p->>'notice_days', '')::smallint, notice_days),
    note = case when p ? 'note' then nullif(btrim(coalesce(p->>'note', '')), '') else note end,
    updated_at = now()
  where id = t.id;
  if v_dep <> t.deposit_paise then
    if exists (select 1 from public.rent_dues where tenancy_id = t.id and kind = 'deposit') then
      if v_dep < (select paid_paise from public.rent_dues where tenancy_id = t.id and kind = 'deposit') then
        raise exception 'More than that was already paid as deposit.';
      end if;
      update public.rent_dues set amount_paise = v_dep, edited = true where tenancy_id = t.id and kind = 'deposit';
    elsif v_dep > 0 then
      insert into public.rent_dues (property_id, tenancy_id, kind, period_start, label, due_on, amount_paise)
      values (t.property_id, t.id, 'deposit', t.start_date, 'Security deposit', public._pg_today(t.property_id), v_dep);
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------- extra charge (electricity, maintenance, late fee, other)
create or replace function public.pg_add_charge(p_tenancy uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.tenancies; v_id uuid; v_kind text := coalesce(nullif(p->>'kind', ''), 'other');
begin
  select * into t from public.tenancies where id = p_tenancy;
  if t.id is null then raise exception 'Tenant not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(t.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if v_kind not in ('electricity','maintenance','late_fee','damage','other') then raise exception 'Choose what the charge is for.'; end if;
  if coalesce(nullif(p->>'amount_paise', '')::int, 0) <= 0 then raise exception 'Enter the amount.'; end if;
  insert into public.rent_dues (property_id, tenancy_id, kind, label, due_on, amount_paise, note, edited)
  values (t.property_id, t.id, v_kind, left(coalesce(nullif(btrim(p->>'label'), ''), initcap(replace(v_kind, '_', ' '))), 80),
          coalesce(nullif(p->>'due_on', '')::date, public._pg_today(t.property_id)), (p->>'amount_paise')::int,
          nullif(btrim(coalesce(p->>'note', '')), ''), true)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- change / waive one due
create or replace function public.pg_edit_due(p_due uuid, p_amount_paise int, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.rent_dues;
begin
  select * into d from public.rent_dues where id = p_due for update;
  if d.id is null then raise exception 'Not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(d.property_id, array['owner','manager']::public.member_role[]);
  if p_amount_paise < d.paid_paise then raise exception 'That is less than what was already paid (%).', to_char(d.paid_paise / 100.0, 'FM9,99,99,990'); end if;
  if p_amount_paise = 0 and d.paid_paise = 0 and d.kind not in ('rent','food') then
    delete from public.rent_dues where id = d.id; return;
  end if;
  update public.rent_dues set amount_paise = p_amount_paise, edited = true,
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note) where id = d.id;
end $$;

-- ---------------------------------------------------------------- record a payment (oldest dues first, or one due)
create or replace function public.pg_pay(p_tenancy uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t public.tenancies; v_left int := coalesce(nullif(p->>'amount_paise', '')::int, 0); v_due uuid := nullif(p->>'due_id', '')::uuid;
  v_open int; d record; v_part int; v_codes text[] := '{}'; v_code text; v_at timestamptz := coalesce(nullif(p->>'received_at', '')::timestamptz, now());
begin
  select * into t from public.tenancies where id = p_tenancy for update;
  if t.id is null then raise exception 'Tenant not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(t.property_id, array['owner','manager','front_desk']::public.member_role[]);
  perform public._require_perm(t.property_id, 'record_payments');
  if v_left <= 0 then raise exception 'Enter the amount received.'; end if;
  select coalesce(sum(amount_paise - paid_paise), 0) into v_open from public.rent_dues
   where tenancy_id = t.id and (v_due is null or id = v_due);
  if v_left > v_open then
    raise exception 'Only ₹% is due. Add a charge first, or enter a smaller amount.', to_char(v_open / 100.0, 'FM9,99,99,990');
  end if;
  for d in select * from public.rent_dues where tenancy_id = t.id and amount_paise > paid_paise and (v_due is null or id = v_due)
           order by due_on, case kind when 'deposit' then 0 else 1 end, created_at loop
    exit when v_left <= 0;
    v_part := least(v_left, d.amount_paise - d.paid_paise);
    insert into public.rent_payments (property_id, tenancy_id, due_id, kind, amount_paise, method, reference, note, received_at)
    values (t.property_id, t.id, d.id, 'payment', v_part, coalesce(nullif(p->>'method', ''), 'upi'),
            nullif(btrim(coalesce(p->>'reference', '')), ''), nullif(btrim(coalesce(p->>'note', '')), ''), v_at)
    returning code into v_code;
    update public.rent_dues set paid_paise = paid_paise + v_part where id = d.id;
    v_codes := v_codes || v_code; v_left := v_left - v_part;
  end loop;
  return jsonb_build_object('receipts', v_codes,
    'balance_paise', (select coalesce(sum(amount_paise - paid_paise), 0) from public.rent_dues
                       where tenancy_id = t.id and due_on <= public._pg_today(t.property_id)));
end $$;

-- ---------------------------------------------------------------- notice (p_move_out = null withdraws the notice)
create or replace function public.pg_notice(p_tenancy uuid, p_move_out date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.tenancies; b public.bookings; v_seg_end date; v_today date;
begin
  select * into t from public.tenancies where id = p_tenancy for update;
  if t.id is null then raise exception 'Tenant not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(t.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if t.status = 'moved_out' then raise exception 'This tenant has already moved out.'; end if;
  v_today := public._pg_today(t.property_id);
  select * into b from public.bookings where id = t.booking_id;
  if p_move_out is null then
    update public.tenancies set status = 'active', move_out_on = null, notice_given_on = null, updated_at = now() where id = t.id;
    if b.id is not null then
      v_seg_end := (b.check_in_at at time zone public._tz(t.property_id))::date + 365;
      begin perform public._pg_set_end(b.id, t.property_id, v_seg_end);
      exception when exclusion_violation then null;          -- someone booked the bed after the old move-out: keep the shorter hold
      end;
    end if;
  else
    if p_move_out < t.start_date then raise exception 'Move-out can''t be before the move-in date.'; end if;
    update public.tenancies set status = 'notice', move_out_on = p_move_out, notice_given_on = coalesce(notice_given_on, v_today), updated_at = now() where id = t.id;
    if b.id is not null and b.check_out_at > public._pg_at(t.property_id, p_move_out, true) then
      perform public._pg_set_end(b.id, t.property_id, p_move_out);
    end if;
  end if;
  perform public._pg_sync_one(t.id);
end $$;

-- ---------------------------------------------------------------- move out & settle the deposit
-- p: { move_out_on, deductions_paise, deduction_note, refund_method, refund_reference }
create or replace function public.pg_move_out(p_tenancy uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t public.tenancies; b public.bookings; v_day date; v_ded int := coalesce(nullif(p->>'deductions_paise', '')::int, 0);
  v_dep_paid int; v_credit int; v_open int; v_use int; v_refund int; d record; v_part int; v_left int; v_set jsonb;
begin
  select * into t from public.tenancies where id = p_tenancy for update;
  if t.id is null then raise exception 'Tenant not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(t.property_id, array['owner','manager']::public.member_role[]);
  if t.status = 'moved_out' then raise exception 'This tenant has already moved out.'; end if;
  v_day := coalesce(nullif(p->>'move_out_on', '')::date, t.move_out_on, public._pg_today(t.property_id));
  if v_day < t.start_date then raise exception 'Move-out can''t be before the move-in date.'; end if;

  -- final dues up to the move-out day (last month prorated)
  update public.tenancies set move_out_on = v_day where id = t.id;
  perform public._pg_sync_one(t.id);
  if v_ded > 0 then
    insert into public.rent_dues (property_id, tenancy_id, kind, label, due_on, amount_paise, note, edited)
    values (t.property_id, t.id, 'damage', 'Deductions at move-out', v_day, v_ded, nullif(btrim(coalesce(p->>'deduction_note', '')), ''), true);
  end if;

  -- deposit pays any open dues; the rest is refunded
  select coalesce(sum(paid_paise), 0) into v_dep_paid from public.rent_dues where tenancy_id = t.id and kind = 'deposit';
  select coalesce(sum(credit_paise), 0) into v_credit from public.rent_dues where tenancy_id = t.id;
  v_dep_paid := v_dep_paid + v_credit;                                  -- money held: deposit + rent paid ahead that isn't owed
  select coalesce(sum(amount_paise - paid_paise), 0) into v_open from public.rent_dues where tenancy_id = t.id and kind <> 'deposit';
  v_use := least(v_dep_paid, v_open); v_left := v_use;
  for d in select * from public.rent_dues where tenancy_id = t.id and kind <> 'deposit' and amount_paise > paid_paise order by due_on, created_at loop
    exit when v_left <= 0;
    v_part := least(v_left, d.amount_paise - d.paid_paise);
    insert into public.rent_payments (property_id, tenancy_id, due_id, kind, amount_paise, method, note)
    values (t.property_id, t.id, d.id, 'deposit_adjust', v_part, 'deposit', 'Taken from deposit / advance at move-out');
    update public.rent_dues set paid_paise = paid_paise + v_part where id = d.id;
    v_left := v_left - v_part;
  end loop;
  v_refund := v_dep_paid - v_use;
  if v_refund > 0 then
    perform public._require_perm(t.property_id, 'refunds');
    insert into public.rent_payments (property_id, tenancy_id, kind, amount_paise, method, reference, note)
    values (t.property_id, t.id, 'refund', v_refund, coalesce(nullif(p->>'refund_method', ''), 'upi'),
            nullif(btrim(coalesce(p->>'refund_reference', '')), ''), case when v_credit > 0 then 'Deposit + advance refund' else 'Deposit refund' end);
  end if;
  v_set := jsonb_build_object('move_out_on', v_day, 'deposit_paid_paise', v_dep_paid - v_credit, 'advance_paise', v_credit, 'used_for_dues_paise', v_use,
             'deductions_paise', v_ded, 'refund_paise', v_refund, 'still_due_paise', v_open - v_use, 'settled_at', now());
  update public.tenancies set status = 'moved_out', move_out_on = v_day, notice_given_on = coalesce(notice_given_on, v_day),
         settled = v_set, updated_at = now() where id = t.id;

  -- the bed: end the hold, mark checked out (housekeeping gets a "dirty" bed as usual)
  select * into b from public.bookings where id = t.booking_id;
  if b.id is not null then
    perform public._pg_set_end(b.id, t.property_id, v_day);
    update public.bookings set status = 'checked_out', departed_at = now() where id = b.id and status in ('confirmed','checked_in');
  end if;
  -- any later segment that was added ahead: release it
  update public.bookings set status = 'checked_out', departed_at = now()
   where id = any (t.booking_ids) and id <> coalesce(t.booking_id, id) and status in ('confirmed','checked_in') and check_in_at > now();
  return v_set;
end $$;

-- ---------------------------------------------------------------- delete a tenant entered by mistake (no payments yet)
create or replace function public.pg_delete(p_tenancy uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.tenancies;
begin
  select * into t from public.tenancies where id = p_tenancy for update;
  if t.id is null then return; end if;
  perform public._assert_role(t.property_id, array['owner','manager']::public.member_role[]);
  if exists (select 1 from public.rent_payments where tenancy_id = t.id) then
    raise exception 'This tenant has payments. Use Move out instead.';
  end if;
  delete from public.tenancies where id = t.id;                       -- dues go with it
  delete from public.bookings where id = any (t.booking_ids) and paid_paise = 0;
end $$;

revoke execute on function public._pg_keep_tenant_booking(), public._pg_today(uuid), public._pg_at(uuid, date, boolean), public._pg_hold(public.tenancies, date, date, public.booking_status, timestamptz),
  public._pg_set_end(uuid, uuid, date), public._pg_close_segment(uuid), public._pg_sync_one(uuid), public._pg_sync(uuid),
  public._pg_row(public.tenancies, date), public.pg_run_all() from public, anon, authenticated;
grant execute on function public.pg_run_all() to service_role;
revoke execute on function public.pg_mode(uuid), public.pg_set_mode(uuid, boolean) from public, anon;
grant execute on function public.pg_mode(uuid), public.pg_set_mode(uuid, boolean) to authenticated;
revoke execute on function public.pg_tenants(uuid), public.pg_tenant(uuid), public.pg_move_in(uuid, jsonb), public.pg_update(uuid, jsonb),
  public.pg_add_charge(uuid, jsonb), public.pg_edit_due(uuid, int, text), public.pg_pay(uuid, jsonb), public.pg_notice(uuid, date),
  public.pg_move_out(uuid, jsonb), public.pg_delete(uuid) from public, anon;
grant execute on function public.pg_tenants(uuid), public.pg_tenant(uuid), public.pg_move_in(uuid, jsonb), public.pg_update(uuid, jsonb),
  public.pg_add_charge(uuid, jsonb), public.pg_edit_due(uuid, int, text), public.pg_pay(uuid, jsonb), public.pg_notice(uuid, date),
  public.pg_move_out(uuid, jsonb), public.pg_delete(uuid) to authenticated;
