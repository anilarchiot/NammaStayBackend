-- =====================================================================
-- NammaStay · 042_staff.sql — Staff: attendance & shifts, salary & advances, leave, documents
--
-- One new page "Staff" (owner + manager). Works for every property type — hostel, hotel, homestay,
-- resort, PG: the page offers ready-made roles and shifts for the type; owners rename or add their own.
--   • Staff need no NammaStay login. They check in / out by scanning the property's QR with their own
--     phone and typing their 4-digit PIN (staff-checkin.html). Owner / manager can also mark by hand.
--   • Live-in staff (homestay caretaker, PG warden…) count as present automatically.
--   • Shifts (overnight shifts allowed), weekly off, a roster for any day, late after N minutes.
--   • Leave requests with approve / decline (paid, sick or unpaid) and a warning when the property is busy.
--   • Salary by month, day or hour (or none, e.g. hostel volunteers): unpaid absences and unpaid leave are
--     deducted, advances are recovered; "Pay" writes the salary into Expenses (category "salaries").
--   • Documents: ID proof and police verification (private storage bucket "staff-docs").
--
-- Salaries are seen by the owner, and by managers only if the owner allows it.
-- ADD-ON ONLY — new tables, functions, one private storage bucket and its policies. The only rows it writes
-- into an existing table are the salary expenses the owner pays (public.expenses, category 'salaries').
-- Safe to run more than once. Rollback: rollback_042_staff.sql
-- =====================================================================

-- ---------------------------------------------------------------- tables
create table if not exists public.staff_settings (
  property_id         uuid primary key references public.properties(id) on delete cascade,
  leave_days_year     int  not null default 12 check (leave_days_year between 0 and 60),
  late_after_min      int  not null default 15 check (late_after_min between 0 and 120),
  managers_see_salary boolean not null default false,
  qr_token            uuid not null default gen_random_uuid(),
  updated_at          timestamptz not null default now()
);
create unique index if not exists staff_settings_qr on public.staff_settings (qr_token);

create table if not exists public.staff_shifts (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 2 and 30),
  starts      time not null,
  ends        time not null,                       -- ends <= starts: the shift runs past midnight
  sort        int  not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists staff_shifts_property on public.staff_shifts (property_id, sort);

create table if not exists public.staff_members (
  id              uuid primary key default gen_random_uuid(),
  property_id     uuid not null references public.properties(id) on delete cascade,
  name            text not null check (char_length(btrim(name)) between 2 and 60),
  phone           text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  role            text not null check (char_length(btrim(role)) between 2 and 40),
  live_in         boolean not null default false,  -- lives on site: present unless marked otherwise
  pay_type        text not null default 'month' check (pay_type in ('month', 'day', 'hour', 'none')),
  pay_paise       int  not null default 0 check (pay_paise between 0 and 100000000),
  weekly_off      smallint[] not null default '{}' check (weekly_off <@ array[0,1,2,3,4,5,6]::smallint[]),
  shift_id        uuid references public.staff_shifts(id) on delete set null,
  joined_on       date,
  left_on         date,
  pin_hash        text,                            -- md5(id || pin); the PIN itself is never stored
  id_kind         text check (id_kind is null or id_kind in ('aadhaar', 'voter_id', 'driving_licence', 'pan', 'passport', 'other')),
  id_last4        text check (id_last4 is null or id_last4 ~ '^[0-9A-Za-z]{1,4}$'),   -- last 4 only
  id_doc          text,                            -- file path in "staff-docs"
  needs_police    boolean not null default false,
  police_doc      text,
  address         text check (char_length(address) <= 200),
  emergency_name  text check (char_length(emergency_name) <= 60),
  emergency_phone text check (emergency_phone is null or emergency_phone ~ '^\+?[0-9]{8,15}$'),
  note            text check (char_length(note) <= 200),
  created_at      timestamptz not null default now(),
  check (left_on is null or joined_on is null or left_on >= joined_on)
);
create index if not exists staff_members_property on public.staff_members (property_id);

create table if not exists public.staff_roster (       -- a different shift (or a day off) on one day
  property_id uuid not null references public.properties(id) on delete cascade,
  staff_id    uuid not null references public.staff_members(id) on delete cascade,
  day         date not null,
  shift_id    uuid references public.staff_shifts(id) on delete cascade,   -- null = day off
  primary key (staff_id, day)
);

create table if not exists public.staff_attendance (
  property_id uuid not null references public.properties(id) on delete cascade,
  staff_id    uuid not null references public.staff_members(id) on delete cascade,
  day         date not null,                       -- the shift's day (a night shift belongs to the day it starts)
  status      text not null check (status in ('present', 'late', 'half', 'absent', 'off')),
  in_at       timestamptz,
  out_at      timestamptz,
  source      text not null default 'manual' check (source in ('qr', 'manual')),
  note        text check (char_length(note) <= 200),
  marked_by   uuid,
  updated_at  timestamptz not null default now(),
  primary key (staff_id, day)
);
create index if not exists staff_attendance_property on public.staff_attendance (property_id, day);

create table if not exists public.staff_leave (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  staff_id    uuid not null references public.staff_members(id) on delete cascade,
  date_from   date not null,
  date_to     date not null,
  kind        text not null default 'paid' check (kind in ('paid', 'sick', 'unpaid')),
  reason      text check (char_length(reason) <= 200),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  decided_by  uuid,
  decided_at  timestamptz,
  created_at  timestamptz not null default now(),
  check (date_to >= date_from and date_to - date_from <= 60)
);
create index if not exists staff_leave_property on public.staff_leave (property_id, date_from);

create table if not exists public.staff_advances (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  staff_id     uuid not null references public.staff_members(id) on delete cascade,
  given_on     date not null,
  amount_paise int  not null check (amount_paise between 100 and 100000000),
  note         text check (char_length(note) <= 200),
  created_at   timestamptz not null default now()
);
create index if not exists staff_advances_property on public.staff_advances (property_id, given_on);

create table if not exists public.staff_payslips (
  id              uuid primary key default gen_random_uuid(),
  property_id     uuid not null references public.properties(id) on delete cascade,
  staff_id        uuid not null references public.staff_members(id) on delete cascade,
  month           date not null check (extract(day from month) = 1),
  gross_paise     int  not null,
  deduction_paise int  not null default 0,
  advance_paise   int  not null default 0,
  net_paise       int  not null,
  days_worked     numeric(6,2),
  paid_on         date not null,
  method          text not null check (method in ('cash', 'upi', 'card', 'bank')),
  expense_id      uuid,                              -- the row written into public.expenses
  created_at      timestamptz not null default now(),
  unique (staff_id, month)
);
create index if not exists staff_payslips_property on public.staff_payslips (property_id, month);

create table if not exists public.staff_qr_tries (    -- QR check-in rate limit
  key text not null,
  at  timestamptz not null default now()
);
create index if not exists staff_qr_tries_key on public.staff_qr_tries (key, at);

do $$ declare t text; begin
  foreach t in array array['staff_settings', 'staff_shifts', 'staff_members', 'staff_roster', 'staff_attendance', 'staff_leave',
                           'staff_advances', 'staff_payslips', 'staff_qr_tries'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);   -- read and written only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- documents (PRIVATE bucket; owner + manager)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('staff-docs', 'staff-docs', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Path layout: {property_id}/{staff_id}/{kind}-{random}.{ext}
drop policy if exists "staff-docs: read" on storage.objects;
create policy "staff-docs: read" on storage.objects for select to authenticated
  using (bucket_id = 'staff-docs' and exists (
    select 1 from public.my_property_ids(array['owner','manager']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "staff-docs: upload" on storage.objects;
create policy "staff-docs: upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'staff-docs' and exists (
    select 1 from public.my_property_ids(array['owner','manager']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "staff-docs: delete" on storage.objects;
create policy "staff-docs: delete" on storage.objects for delete to authenticated
  using (bucket_id = 'staff-docs' and exists (
    select 1 from public.my_property_ids(array['owner','manager']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));

-- ---------------------------------------------------------------- helpers (server only)
create or replace function public._st_tz(p_property uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select nullif(timezone, '') from public.properties where id = p_property), 'Asia/Kolkata')
$$;

create or replace function public._st_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone public._st_tz(p_property))::date
$$;

create or replace function public._st_check(p_property uuid, p_owner_only boolean) returns public.member_role
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  return public._assert_role(p_property, case when p_owner_only then array['owner']::public.member_role[] else array['owner', 'manager']::public.member_role[] end);
end $$;

-- Owner always; managers only when the owner allows it
create or replace function public._st_can_salary(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.property_members m where m.property_id = p_property and m.user_id = auth.uid()
                   and (m.role = 'owner' or (m.role = 'manager' and coalesce((select managers_see_salary from public.staff_settings s where s.property_id = p_property), false))))
$$;

create or replace function public._st_settings(p_property uuid) returns public.staff_settings
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare s public.staff_settings;
begin
  insert into public.staff_settings (property_id) values (p_property) on conflict do nothing;
  select * into s from public.staff_settings where property_id = p_property;
  return s;
end $$;

-- The shift a person works on a day: the roster override, else their usual shift (none on a weekly off)
create or replace function public._st_shift(p_staff uuid, p_day date) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select case when exists (select 1 from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              then (select r.shift_id from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              when extract(dow from p_day)::smallint = any (coalesce((select weekly_off from public.staff_members where id = p_staff), '{}'::smallint[])) then null
              else (select shift_id from public.staff_members where id = p_staff) end
$$;

-- Does the person work that day at all? (roster says off / weekly off → no; no shift set up → yes, unless weekly off)
create or replace function public._st_works(p_staff uuid, p_day date) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case when exists (select 1 from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              then (select r.shift_id is not null from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              else not (extract(dow from p_day)::smallint = any (coalesce((select weekly_off from public.staff_members where id = p_staff), '{}'::smallint[]))) end
$$;

-- One person's day: present / late / half / absent / leave / off / later (today, not yet due) / not_in (today, due, no check-in) / upcoming
create or replace function public._st_day(p_staff uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.staff_members; a public.staff_attendance; sh public.staff_shifts; v_tz text; v_today date; v_lv text; v_status text; v_start timestamptz;
        v_late int;
begin
  select * into m from public.staff_members where id = p_staff;
  v_tz := public._st_tz(m.property_id); v_today := (now() at time zone v_tz)::date;
  select * into sh from public.staff_shifts where id = public._st_shift(p_staff, p_day);
  select * into a from public.staff_attendance where staff_id = p_staff and day = p_day;
  select kind into v_lv from public.staff_leave where staff_id = p_staff and status = 'approved' and p_day between date_from and date_to limit 1;
  v_start := case when sh.id is not null then (p_day + sh.starts) at time zone v_tz end;
  select late_after_min into v_late from public.staff_settings where property_id = m.property_id;
  v_status := case
    when (m.joined_on is not null and p_day < m.joined_on) or (m.left_on is not null and p_day > m.left_on) then 'not_employed'
    when a.staff_id is not null then a.status
    when v_lv is not null then 'leave'
    when not public._st_works(p_staff, p_day) then 'off'
    when m.live_in and p_day <= v_today then 'present'
    when p_day < v_today then 'absent'
    when p_day = v_today and (v_start is null or now() < v_start + make_interval(mins => coalesce(v_late, 15))) then 'later'
    when p_day = v_today then 'not_in'
    else 'upcoming' end;
  return jsonb_build_object('day', p_day, 'status', v_status, 'leave_kind', v_lv,
    'shift_id', sh.id, 'shift', sh.name, 'starts', sh.starts, 'ends', sh.ends,
    'in_at', a.in_at, 'out_at', a.out_at, 'source', a.source, 'note', a.note,
    'late_min', case when a.in_at is not null and v_start is not null then greatest(0, floor(extract(epoch from a.in_at - v_start) / 60))::int end);
end $$;

-- Salary for one person and month (paise). Days in the month count from joining to leaving.
create or replace function public._st_salary(p_staff uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.staff_members; v_m0 date := date_trunc('month', p_month)::date; v_m1 date; v_days int; d date; x jsonb;
        v_work numeric := 0; v_absent numeric := 0; v_unpaid numeric := 0; v_out numeric := 0; v_hours numeric := 0; v_paid numeric := 0;
        v_gross bigint := 0; v_ded bigint := 0; v_adv_due bigint; v_adv bigint; v_slip public.staff_payslips; v_today date;
        v_len numeric; sh public.staff_shifts;
begin
  select * into m from public.staff_members where id = p_staff;
  v_m1 := (v_m0 + interval '1 month - 1 day')::date; v_days := v_m1 - v_m0 + 1;
  v_today := public._st_today(m.property_id);
  for d in select g::date from generate_series(v_m0, v_m1, interval '1 day') g loop
    x := public._st_day(p_staff, d);
    case x->>'status'
      when 'not_employed' then v_out := v_out + 1;
      when 'present', 'late' then v_work := v_work + 1;
      when 'half' then v_work := v_work + 0.5; v_absent := v_absent + 0.5;
      when 'absent' then v_absent := v_absent + 1;
      when 'leave' then if x->>'leave_kind' = 'unpaid' then v_unpaid := v_unpaid + 1; else v_paid := v_paid + 1; end if;
      when 'not_in' then v_absent := v_absent + 1;
      else null;   -- off, later, upcoming: not deducted
    end case;
    if m.pay_type = 'hour' and x->>'status' in ('present', 'late', 'half') then
      select * into sh from public.staff_shifts where id = (x->>'shift_id')::uuid;
      v_len := case when sh.id is null then 8 else extract(epoch from (case when sh.ends > sh.starts then sh.ends - sh.starts else sh.ends - sh.starts + interval '24 hours' end)) / 3600 end;
      v_hours := v_hours + coalesce(extract(epoch from ((x->>'out_at')::timestamptz - (x->>'in_at')::timestamptz)) / 3600, v_len * case when x->>'status' = 'half' then 0.5 else 1 end);
    end if;
  end loop;
  if m.pay_type = 'month' then
    v_gross := m.pay_paise;
    v_ded := round(m.pay_paise::numeric / v_days * (v_absent + v_unpaid + v_out));
  elsif m.pay_type = 'day' then v_gross := round(m.pay_paise * v_work);
  elsif m.pay_type = 'hour' then v_gross := round(m.pay_paise * v_hours);
  end if;
  v_ded := least(v_ded, v_gross);
  select * into v_slip from public.staff_payslips where staff_id = p_staff and month = v_m0;
  -- advances still to recover: given up to this month's end, less what earlier payslips already recovered
  v_adv_due := coalesce((select sum(amount_paise) from public.staff_advances where staff_id = p_staff and given_on <= v_m1), 0)
             - coalesce((select sum(advance_paise) from public.staff_payslips where staff_id = p_staff and month < v_m0), 0);
  v_adv := case when v_slip.id is not null then v_slip.advance_paise else least(greatest(v_adv_due, 0), v_gross - v_ded) end;
  return jsonb_build_object('staff_id', p_staff, 'month', v_m0, 'pay_type', m.pay_type, 'pay_paise', m.pay_paise,
    'days_in_month', v_days, 'worked', v_work, 'absent', v_absent, 'unpaid_leave', v_unpaid, 'paid_leave', v_paid, 'not_employed', v_out,
    'hours', round(v_hours, 1), 'gross_paise', v_gross, 'deduction_paise', v_ded, 'advance_paise', v_adv,
    'advance_left_paise', greatest(v_adv_due - v_adv, 0), 'net_paise', v_gross - v_ded - v_adv,
    'complete', v_m1 < v_today,
    'paid', case when v_slip.id is null then null else jsonb_build_object('id', v_slip.id, 'net_paise', v_slip.net_paise, 'paid_on', v_slip.paid_on, 'method', v_slip.method) end);
end $$;

-- How full the property is on a day (0–100), for the leave warning
create or replace function public._st_busy(p_property uuid, p_day date) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select case when b.n = 0 then 0 else round(100.0 * (
           select count(*) from public.bookings k where k.property_id = p_property and k.status in ('pending', 'confirmed', 'checked_in', 'checked_out')
              and k.stay @> ((p_day + time '20:00') at time zone public._st_tz(p_property))) / b.n)::int end
    from (select count(*) n from public.beds where property_id = p_property and is_active) b
$$;

create or replace function public._st_client_key() returns text
language plpgsql stable set search_path = public, pg_temp as $$
declare h json; ip text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  ip := coalesce(h->>'cf-connecting-ip', split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1), h->>'x-real-ip');
  return md5('nammastay-staff:' || coalesce(nullif(btrim(ip), ''), 'unknown'));
end $$;

-- ---------------------------------------------------------------- the page
create or replace function public.staff_get(p_property uuid, p_month date default null) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare st public.staff_settings; v_today date; v_role public.member_role; v_sal boolean; v_month date; v_kind text;
begin
  v_role := public._st_check(p_property, false);
  st := public._st_settings(p_property);
  v_today := public._st_today(p_property);
  v_sal := public._st_can_salary(p_property);
  v_month := date_trunc('month', coalesce(p_month, v_today))::date;
  v_kind := (select kind::text from public.properties where id = p_property);
  if to_regclass('public.pg_properties') is not null and exists (select 1 from public.pg_properties where property_id = p_property) then v_kind := 'pg'; end if;
  if to_regclass('public.resort_properties') is not null and exists (select 1 from public.resort_properties where property_id = p_property) then v_kind := 'resort'; end if;
  return jsonb_build_object(
    'today', v_today, 'now', now(), 'kind', v_kind, 'role', v_role, 'can_salary', v_sal, 'month', v_month,
    'settings', jsonb_build_object('leave_days_year', st.leave_days_year, 'late_after_min', st.late_after_min,
                  'managers_see_salary', st.managers_see_salary, 'qr_token', st.qr_token),
    'shifts', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'starts', starts, 'ends', ends, 'sort', sort) order by sort, starts), '[]'::jsonb)
                 from public.staff_shifts where property_id = p_property),
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', m.id, 'name', m.name, 'phone', m.phone, 'role', m.role, 'live_in', m.live_in,
                   'pay_type', m.pay_type, 'pay_paise', case when v_sal then m.pay_paise end,
                   'weekly_off', m.weekly_off, 'shift_id', m.shift_id, 'joined_on', m.joined_on, 'left_on', m.left_on,
                   'has_pin', m.pin_hash is not null, 'id_kind', m.id_kind, 'id_last4', m.id_last4, 'id_doc', m.id_doc,
                   'needs_police', m.needs_police, 'police_doc', m.police_doc, 'address', m.address,
                   'emergency_name', m.emergency_name, 'emergency_phone', m.emergency_phone, 'note', m.note,
                   'active', m.left_on is null or m.left_on >= v_today,
                   'leave_used', (select coalesce(sum(least(l.date_to, (date_trunc('year', v_today) + interval '1 year - 1 day')::date)
                                                      - greatest(l.date_from, date_trunc('year', v_today)::date) + 1), 0)
                                    from public.staff_leave l where l.staff_id = m.id and l.status = 'approved' and l.kind in ('paid', 'sick')
                                     and l.date_to >= date_trunc('year', v_today)::date and l.date_from < (date_trunc('year', v_today) + interval '1 year')::date),
                   'today', public._st_day(m.id, v_today),
                   'week', (select jsonb_agg(public._st_day(m.id, d::date) order by d) from generate_series(v_today, v_today + 6, interval '1 day') d))
                 order by (m.left_on is not null and m.left_on < v_today), m.name), '[]'::jsonb)
                 from public.staff_members m
                where m.property_id = p_property and (m.left_on is null or m.left_on >= v_today - 60)),
    'leave', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'staff_id', l.staff_id, 'name', m.name, 'role', m.role,
                 'date_from', l.date_from, 'date_to', l.date_to, 'days', l.date_to - l.date_from + 1, 'kind', l.kind, 'reason', l.reason,
                 'status', l.status, 'busy_pct', (select max(public._st_busy(p_property, d::date)) from generate_series(l.date_from, l.date_to, interval '1 day') d),
                 'others_off', (select count(distinct l2.staff_id) from public.staff_leave l2 where l2.property_id = p_property and l2.id <> l.id
                                  and l2.status = 'approved' and l2.date_from <= l.date_to and l2.date_to >= l.date_from))
                 order by (l.status = 'pending') desc, l.date_from), '[]'::jsonb)
                from public.staff_leave l join public.staff_members m on m.id = l.staff_id
               where l.property_id = p_property and (l.status = 'pending' or (l.status = 'approved' and l.date_to >= v_today - 31))),
    'salary', case when v_sal then (select coalesce(jsonb_agg(public._st_salary(m.id, v_month) || jsonb_build_object('name', m.name, 'role', m.role) order by m.name), '[]'::jsonb)
                 from public.staff_members m where m.property_id = p_property
                  and (m.joined_on is null or m.joined_on <= (v_month + interval '1 month - 1 day')::date)
                  and (m.left_on is null or m.left_on >= v_month)) end,
    'advances', case when v_sal then (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'staff_id', a.staff_id, 'name', m.name, 'given_on', a.given_on,
                 'amount_paise', a.amount_paise, 'note', a.note) order by a.given_on desc), '[]'::jsonb)
                 from public.staff_advances a join public.staff_members m on m.id = a.staff_id
                where a.property_id = p_property and a.given_on >= v_month - 62) end);
end $$;

create or replace function public.staff_counts(p_property uuid) returns int
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.property_members m where m.property_id = p_property and m.user_id = auth.uid() and m.role in ('owner', 'manager')) then return 0; end if;
  return (select count(*) from public.staff_leave where property_id = p_property and status = 'pending')::int
       + (select count(*) from public.staff_members where property_id = p_property and (left_on is null or left_on >= public._st_today(p_property))
            and (id_doc is null or (needs_police and police_doc is null)))::int;
end $$;

-- ---------------------------------------------------------------- people
create or replace function public.staff_save(p_property uuid, p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_pin text := nullif(btrim(p->>'pin'), ''); v_pay text := coalesce(nullif(p->>'pay_type', ''), 'month');
        v_amt int := coalesce(nullif(p->>'pay_paise', '')::int, 0); v_sal boolean; v_shift uuid := nullif(p->>'shift_id', '')::uuid; v_off smallint[];
        v_join date := nullif(p->>'joined_on', '')::date; v_left date := nullif(p->>'left_on', '')::date;
begin
  perform public._st_check(p_property, false);
  perform public._st_settings(p_property);
  v_sal := public._st_can_salary(p_property);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the name.'; end if;
  if char_length(btrim(coalesce(p->>'role', ''))) < 2 then raise exception 'Choose or type the job, e.g. "Reception".'; end if;
  if nullif(p->>'phone', '') is not null and (p->>'phone') !~ '^\+?[0-9]{8,15}$' then raise exception 'Phone: digits only, e.g. 9876543210.'; end if;
  if v_pay not in ('month', 'day', 'hour', 'none') then raise exception 'Choose how they are paid.'; end if;
  if v_pay <> 'none' and v_sal and v_amt <= 0 then raise exception 'Enter the salary.'; end if;
  if v_pay = 'none' then v_amt := 0; end if;
  if v_pin is not null and v_pin !~ '^[0-9]{4}$' then raise exception 'PIN: 4 digits.'; end if;
  if v_shift is not null and not exists (select 1 from public.staff_shifts where id = v_shift and property_id = p_property) then raise exception 'Unknown shift.'; end if;
  if v_left is not null and v_join is not null and v_left < v_join then raise exception 'The leaving date is before the joining date.'; end if;
  v_off := case when jsonb_typeof(p->'weekly_off') = 'array' then array(select (x)::smallint from jsonb_array_elements_text(p->'weekly_off') x) else '{}' end;
  if v_id is null then
    insert into public.staff_members (property_id, name, phone, role, live_in, pay_type, pay_paise, weekly_off, shift_id, joined_on, left_on,
                                      id_kind, id_last4, needs_police, address, emergency_name, emergency_phone, note)
    values (p_property, btrim(p->>'name'), nullif(p->>'phone', ''), btrim(p->>'role'), coalesce((p->>'live_in')::boolean, false), v_pay,
            case when v_sal then v_amt else 0 end, v_off, v_shift, v_join, v_left,
            nullif(p->>'id_kind', ''), nullif(upper(right(regexp_replace(coalesce(p->>'id_number', ''), '\s', '', 'g'), 4)), ''),
            coalesce((p->>'needs_police')::boolean, false), nullif(btrim(p->>'address'), ''), nullif(btrim(p->>'emergency_name'), ''),
            nullif(p->>'emergency_phone', ''), nullif(btrim(p->>'note'), ''))
    returning id into v_id;
  else
    update public.staff_members set name = btrim(p->>'name'), phone = nullif(p->>'phone', ''), role = btrim(p->>'role'),
           live_in = coalesce((p->>'live_in')::boolean, false), pay_type = v_pay,
           pay_paise = case when v_sal then v_amt else pay_paise end,
           weekly_off = v_off, shift_id = v_shift, joined_on = v_join, left_on = v_left,
           id_kind = nullif(p->>'id_kind', ''),
           id_last4 = coalesce(nullif(upper(right(regexp_replace(coalesce(p->>'id_number', ''), '\s', '', 'g'), 4)), ''), case when nullif(p->>'id_kind', '') is null then null else id_last4 end),
           needs_police = coalesce((p->>'needs_police')::boolean, false), address = nullif(btrim(p->>'address'), ''),
           emergency_name = nullif(btrim(p->>'emergency_name'), ''), emergency_phone = nullif(p->>'emergency_phone', ''), note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Staff member not found.'; end if;
  end if;
  if v_pin is not null then update public.staff_members set pin_hash = md5(v_id::text || v_pin) where id = v_id; end if;
  return v_id;
exception when check_violation then raise exception 'Check the details — phone numbers digits only, ID: last 4 letters or digits.';
end $$;

create or replace function public.staff_delete(p_property uuid, p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, true);
  if exists (select 1 from public.staff_payslips where staff_id = p_id) then
    raise exception 'This person has salary records. Set a leaving date instead, so the records stay.';
  end if;
  delete from public.staff_members where id = p_id and property_id = p_property;
end $$;

create or replace function public.staff_doc_set(p_property uuid, p_staff uuid, p_kind text, p_path text) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, false);
  if p_kind not in ('id', 'police') then raise exception 'Unknown document.'; end if;
  if p_path is not null and p_path not like p_property::text || '/' || p_staff::text || '/%' then raise exception 'Upload the file again.'; end if;
  if p_kind = 'id' then update public.staff_members set id_doc = p_path where id = p_staff and property_id = p_property;
  else update public.staff_members set police_doc = p_path where id = p_staff and property_id = p_property; end if;
  if not found then raise exception 'Staff member not found.'; end if;
end $$;

-- ---------------------------------------------------------------- shifts & roster
create or replace function public.staff_shift_save(p_property uuid, p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_s time := nullif(p->>'starts', '')::time; v_e time := nullif(p->>'ends', '')::time;
begin
  perform public._st_check(p_property, false);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Name the shift, e.g. "Morning".'; end if;
  if v_s is null or v_e is null then raise exception 'Enter the start and end time.'; end if;
  if v_s = v_e then raise exception 'Start and end can’t be the same time.'; end if;
  if v_id is null then
    if (select count(*) from public.staff_shifts where property_id = p_property) >= 12 then raise exception 'Up to 12 shifts.'; end if;
    insert into public.staff_shifts (property_id, name, starts, ends, sort)
    values (p_property, btrim(p->>'name'), v_s, v_e, coalesce(nullif(p->>'sort', '')::int, (select coalesce(max(sort), 0) + 1 from public.staff_shifts where property_id = p_property)))
    returning id into v_id;
  else
    update public.staff_shifts set name = btrim(p->>'name'), starts = v_s, ends = v_e where id = v_id and property_id = p_property;
    if not found then raise exception 'Shift not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.staff_shift_delete(p_property uuid, p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, false);
  delete from public.staff_shifts where id = p_id and property_id = p_property;     -- usual shifts using it become "no shift"; roster days using it are cleared
end $$;

-- p_mode: 'shift' (p_shift) · 'off' · 'usual' (remove the change)
create or replace function public.staff_roster_set(p_property uuid, p_staff uuid, p_day date, p_mode text, p_shift uuid default null) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, false);
  if not exists (select 1 from public.staff_members where id = p_staff and property_id = p_property) then raise exception 'Staff member not found.'; end if;
  if p_mode = 'usual' then delete from public.staff_roster where staff_id = p_staff and day = p_day;
  elsif p_mode = 'off' then
    insert into public.staff_roster (property_id, staff_id, day, shift_id) values (p_property, p_staff, p_day, null)
    on conflict (staff_id, day) do update set shift_id = null;
  elsif p_mode = 'shift' then
    if not exists (select 1 from public.staff_shifts where id = p_shift and property_id = p_property) then raise exception 'Unknown shift.'; end if;
    insert into public.staff_roster (property_id, staff_id, day, shift_id) values (p_property, p_staff, p_day, p_shift)
    on conflict (staff_id, day) do update set shift_id = excluded.shift_id;
  else raise exception 'Choose a shift, day off or usual.';
  end if;
  return public._st_day(p_staff, p_day);
end $$;

-- ---------------------------------------------------------------- attendance (by hand)
-- p_status null = remove the mark (back to automatic); times are local "HH:MM"
create or replace function public.staff_mark(p_property uuid, p_staff uuid, p_day date, p_status text, p_in text default null, p_out text default null, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_tz text := public._st_tz(p_property); v_in timestamptz; v_out timestamptz; sh public.staff_shifts;
begin
  perform public._st_check(p_property, false);
  if not exists (select 1 from public.staff_members where id = p_staff and property_id = p_property) then raise exception 'Staff member not found.'; end if;
  if p_day > public._st_today(p_property) then raise exception 'You can mark today or earlier days only.'; end if;
  if p_status is null then delete from public.staff_attendance where staff_id = p_staff and day = p_day; return public._st_day(p_staff, p_day); end if;
  if p_status not in ('present', 'late', 'half', 'absent', 'off') then raise exception 'Choose present, late, half day, absent or off.'; end if;
  v_in := case when nullif(p_in, '') is not null then (p_day + p_in::time) at time zone v_tz end;
  select * into sh from public.staff_shifts where id = public._st_shift(p_staff, p_day);
  v_out := case when nullif(p_out, '') is not null then (p_day + p_out::time + case when p_out::time < coalesce(p_in::time, sh.starts, '00:00') then interval '1 day' else interval '0' end) at time zone v_tz end;
  insert into public.staff_attendance (property_id, staff_id, day, status, in_at, out_at, source, note, marked_by, updated_at)
  values (p_property, p_staff, p_day, p_status, v_in, v_out, 'manual', nullif(btrim(p_note), ''), auth.uid(), now())
  on conflict (staff_id, day) do update set status = excluded.status, in_at = coalesce(excluded.in_at, staff_attendance.in_at),
    out_at = coalesce(excluded.out_at, staff_attendance.out_at), note = coalesce(excluded.note, staff_attendance.note),
    source = 'manual', marked_by = auth.uid(), updated_at = now();
  return public._st_day(p_staff, p_day);
end $$;

-- ---------------------------------------------------------------- leave
create or replace function public.staff_leave_save(p_property uuid, p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_from date := nullif(p->>'date_from', '')::date; v_to date := coalesce(nullif(p->>'date_to', '')::date, nullif(p->>'date_from', '')::date);
        v_kind text := coalesce(nullif(p->>'kind', ''), 'paid'); v_ok boolean := coalesce((p->>'approve')::boolean, false);
begin
  perform public._st_check(p_property, false);
  if not exists (select 1 from public.staff_members where id = (p->>'staff_id')::uuid and property_id = p_property) then raise exception 'Choose the person.'; end if;
  if v_from is null then raise exception 'Pick the first day.'; end if;
  if v_to < v_from then raise exception 'The last day is before the first day.'; end if;
  if v_to - v_from > 60 then raise exception 'Up to 61 days at a time.'; end if;
  if v_kind not in ('paid', 'sick', 'unpaid') then raise exception 'Choose paid, sick or unpaid leave.'; end if;
  if exists (select 1 from public.staff_leave where staff_id = (p->>'staff_id')::uuid and status <> 'declined' and date_from <= v_to and date_to >= v_from) then
    raise exception 'There is already leave on some of these days.';
  end if;
  insert into public.staff_leave (property_id, staff_id, date_from, date_to, kind, reason, status, decided_by, decided_at)
  values (p_property, (p->>'staff_id')::uuid, v_from, v_to, v_kind, nullif(btrim(p->>'reason'), ''),
          case when v_ok then 'approved' else 'pending' end, case when v_ok then auth.uid() end, case when v_ok then now() end)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.staff_leave_decide(p_property uuid, p_id uuid, p_approve boolean, p_kind text default null) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, false);
  if p_kind is not null and p_kind not in ('paid', 'sick', 'unpaid') then raise exception 'Choose paid, sick or unpaid leave.'; end if;
  update public.staff_leave set status = case when p_approve then 'approved' else 'declined' end, kind = coalesce(p_kind, kind),
         decided_by = auth.uid(), decided_at = now()
   where id = p_id and property_id = p_property;
  if not found then raise exception 'Leave request not found.'; end if;
end $$;

create or replace function public.staff_leave_delete(p_property uuid, p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, false);
  delete from public.staff_leave where id = p_id and property_id = p_property;
end $$;

-- ---------------------------------------------------------------- salary
create or replace function public.staff_advance_save(p_property uuid, p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_amt int := nullif(p->>'amount_paise', '')::int; v_on date := coalesce(nullif(p->>'given_on', '')::date, public._st_today(p_property));
begin
  perform public._st_check(p_property, false);
  if not public._st_can_salary(p_property) then raise exception 'Only the owner can do this.'; end if;
  if not exists (select 1 from public.staff_members where id = (p->>'staff_id')::uuid and property_id = p_property) then raise exception 'Choose the person.'; end if;
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_on > public._st_today(p_property) then raise exception 'The date can’t be in the future.'; end if;
  if exists (select 1 from public.staff_payslips where staff_id = (p->>'staff_id')::uuid and month = date_trunc('month', v_on)::date) then
    raise exception 'That month’s salary is already paid — give the advance with a date in the next month.';
  end if;
  insert into public.staff_advances (property_id, staff_id, given_on, amount_paise, note)
  values (p_property, (p->>'staff_id')::uuid, v_on, v_amt, nullif(btrim(p->>'note'), '')) returning id into v_id;
  return v_id;
end $$;

create or replace function public.staff_advance_delete(p_property uuid, p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, false);
  if not public._st_can_salary(p_property) then raise exception 'Only the owner can do this.'; end if;
  if exists (select 1 from public.staff_advances a join public.staff_payslips s on s.staff_id = a.staff_id and s.month = date_trunc('month', a.given_on)::date where a.id = p_id) then
    raise exception 'That month’s salary is already paid — undo the payment first.';
  end if;
  delete from public.staff_advances where id = p_id and property_id = p_property;
end $$;

-- Pay one person's salary for a month: payslip + expense (category "salaries")
create or replace function public.staff_pay(p_property uuid, p_staff uuid, p_month date, p_method text default 'cash') returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare s jsonb; m public.staff_members; v_exp uuid; v_id uuid; v_m0 date := date_trunc('month', p_month)::date; v_today date := public._st_today(p_property);
begin
  perform public._st_check(p_property, false);
  if not public._st_can_salary(p_property) then raise exception 'Only the owner can do this.'; end if;
  select * into m from public.staff_members where id = p_staff and property_id = p_property;
  if not found then raise exception 'Staff member not found.'; end if;
  if coalesce(p_method, '') not in ('cash', 'upi', 'card', 'bank') then raise exception 'Choose how you paid: cash, UPI, card or bank.'; end if;
  if v_m0 > date_trunc('month', v_today)::date then raise exception 'That month hasn’t started yet.'; end if;
  if exists (select 1 from public.staff_payslips where staff_id = p_staff and month = v_m0) then raise exception 'Already paid for this month.'; end if;
  s := public._st_salary(p_staff, v_m0);
  if (s->>'net_paise')::int <= 0 then raise exception 'Nothing to pay for this month.'; end if;
  insert into public.expenses (property_id, spent_on, category, amount_paise, method, vendor, note, created_by)
  values (p_property, v_today, 'salaries', (s->>'net_paise')::int + (s->>'advance_paise')::int, p_method, left(m.name, 80),   -- the month's full salary cost (advances were cash given earlier)
          'Salary ' || to_char(v_m0, 'Mon YYYY') || ' · ' || m.role || case when (s->>'advance_paise')::int > 0 then ' (incl. advance ₹' || ((s->>'advance_paise')::int / 100) || ' given earlier)' else '' end,
          auth.uid())
  returning id into v_exp;
  insert into public.staff_payslips (property_id, staff_id, month, gross_paise, deduction_paise, advance_paise, net_paise, days_worked, paid_on, method, expense_id)
  values (p_property, p_staff, v_m0, (s->>'gross_paise')::int, (s->>'deduction_paise')::int, (s->>'advance_paise')::int, (s->>'net_paise')::int,
          (s->>'worked')::numeric, v_today, p_method, v_exp)
  returning id into v_id;
  return public._st_salary(p_staff, v_m0) || jsonb_build_object('payslip_id', v_id, 'name', m.name, 'role', m.role, 'phone', m.phone);
end $$;

-- Undo a salary payment (owner): removes the payslip and its expense
create or replace function public.staff_unpay(p_property uuid, p_payslip uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_exp uuid;
begin
  perform public._st_check(p_property, true);
  delete from public.staff_payslips where id = p_payslip and property_id = p_property returning expense_id into v_exp;
  if not found then raise exception 'Payment not found.'; end if;
  delete from public.expenses where id = v_exp and property_id = p_property and category = 'salaries';
end $$;

-- ---------------------------------------------------------------- settings
create or replace function public.staff_settings_save(p_property uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._st_check(p_property, true);
  perform public._st_settings(p_property);
  update public.staff_settings set
    leave_days_year = coalesce(nullif(p->>'leave_days_year', '')::int, leave_days_year),
    late_after_min = coalesce(nullif(p->>'late_after_min', '')::int, late_after_min),
    managers_see_salary = coalesce((p->>'managers_see_salary')::boolean, managers_see_salary),
    qr_token = case when coalesce((p->>'new_qr')::boolean, false) then gen_random_uuid() else qr_token end,
    updated_at = now()
   where property_id = p_property;
  return (select jsonb_build_object('qr_token', qr_token) from public.staff_settings where property_id = p_property);
exception when check_violation then raise exception 'Leave days: 0–60 a year. Late after: 0–120 minutes.';
end $$;

-- ---------------------------------------------------------------- QR check-in (public, no login: token + 4-digit PIN)
create or replace function public.staff_qr_info(p_token uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare st public.staff_settings; v_today date;
begin
  select * into st from public.staff_settings where qr_token = p_token;
  if not found or public._access_state(st.property_id) in ('expired', 'suspended') then raise exception 'This check-in QR is not valid any more. Ask the owner for the new one.'; end if;
  v_today := public._st_today(st.property_id);
  return jsonb_build_object('property', (select name from public.properties where id = st.property_id), 'today', v_today,
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', split_part(m.name, ' ', 1) || coalesce(' ' || left(nullif(split_part(m.name, ' ', 2), ''), 1) || '.', ''),
                'role', m.role, 'has_pin', m.pin_hash is not null,
                'state', case when exists (select 1 from public.staff_attendance a where a.staff_id = m.id and a.in_at is not null and a.out_at is null and a.day >= v_today - 1) then 'in'
                              when exists (select 1 from public.staff_attendance a where a.staff_id = m.id and a.day = v_today and a.out_at is not null) then 'done'
                              else 'out' end) order by m.name), '[]'::jsonb)
                from public.staff_members m where m.property_id = st.property_id and not m.live_in
                 and (m.left_on is null or m.left_on >= v_today) and (m.joined_on is null or m.joined_on <= v_today)));
end $$;

create or replace function public.staff_qr_punch(p_token uuid, p_staff uuid, p_pin text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare st public.staff_settings; m public.staff_members; v_key text := public._st_client_key(); v_today date; v_tz text; a public.staff_attendance;
        sh public.staff_shifts; v_start timestamptz; v_status text;
begin
  select * into st from public.staff_settings where qr_token = p_token;
  if not found or public._access_state(st.property_id) in ('expired', 'suspended') then raise exception 'This check-in QR is not valid any more. Ask the owner for the new one.'; end if;
  delete from public.staff_qr_tries where at < now() - interval '1 day';
  if (select count(*) from public.staff_qr_tries where key in (v_key, 'staff:' || p_staff::text) and at > now() - interval '10 minutes') >= 8 then
    raise exception 'Too many tries. Wait 10 minutes and try again, or ask the manager to mark you.';
  end if;
  select * into m from public.staff_members where id = p_staff and property_id = st.property_id;
  if not found or m.pin_hash is null or coalesce(p_pin, '') !~ '^[0-9]{4}$' or md5(m.id::text || p_pin) <> m.pin_hash then
    insert into public.staff_qr_tries (key) values (v_key), ('staff:' || p_staff::text);
    raise exception 'Wrong PIN. Try again — or ask the manager to set your PIN.';
  end if;
  v_tz := public._st_tz(st.property_id); v_today := (now() at time zone v_tz)::date;
  -- still checked in (today, or a night shift from yesterday)? → check out
  select * into a from public.staff_attendance where staff_id = p_staff and in_at is not null and out_at is null and day >= v_today - 1 order by day desc limit 1;
  if found then
    if now() - a.in_at < interval '2 minutes' then raise exception 'You checked in just now.'; end if;
    update public.staff_attendance set out_at = now(), updated_at = now() where staff_id = p_staff and day = a.day;
    return jsonb_build_object('action', 'out', 'name', m.name, 'at', now(), 'hours', round(extract(epoch from now() - a.in_at)::numeric / 3600, 1));
  end if;
  if exists (select 1 from public.staff_attendance where staff_id = p_staff and day = v_today and out_at is not null) then
    raise exception 'You already checked out today.';
  end if;
  select * into sh from public.staff_shifts where id = public._st_shift(p_staff, v_today);
  v_start := case when sh.id is not null then (v_today + sh.starts) at time zone v_tz end;
  v_status := case when v_start is not null and now() > v_start + make_interval(mins => st.late_after_min) then 'late' else 'present' end;
  insert into public.staff_attendance (property_id, staff_id, day, status, in_at, source, updated_at)
  values (st.property_id, p_staff, v_today, v_status, now(), 'qr', now())
  on conflict (staff_id, day) do update set status = case when staff_attendance.status in ('absent', 'off') then excluded.status else staff_attendance.status end,
    in_at = coalesce(staff_attendance.in_at, excluded.in_at), source = 'qr', updated_at = now();
  return jsonb_build_object('action', 'in', 'name', m.name, 'at', now(), 'late', v_status = 'late',
    'late_min', case when v_start is not null then greatest(0, floor(extract(epoch from now() - v_start) / 60))::int end, 'shift', sh.name);
end $$;

-- ---------------------------------------------------------------- permissions
do $$ declare f text; begin
  foreach f in array array['staff_get(uuid, date)', 'staff_counts(uuid)', 'staff_save(uuid, jsonb)', 'staff_delete(uuid, uuid)', 'staff_doc_set(uuid, uuid, text, text)',
    'staff_shift_save(uuid, jsonb)', 'staff_shift_delete(uuid, uuid)', 'staff_roster_set(uuid, uuid, date, text, uuid)',
    'staff_mark(uuid, uuid, date, text, text, text, text)', 'staff_leave_save(uuid, jsonb)', 'staff_leave_decide(uuid, uuid, boolean, text)',
    'staff_leave_delete(uuid, uuid)', 'staff_advance_save(uuid, jsonb)', 'staff_advance_delete(uuid, uuid)', 'staff_pay(uuid, uuid, date, text)',
    'staff_unpay(uuid, uuid)', 'staff_settings_save(uuid, jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['staff_qr_info(uuid)', 'staff_qr_punch(uuid, uuid, text)'] loop      -- the staff phone page (no login)
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
  foreach f in array array['_st_tz(uuid)', '_st_today(uuid)', '_st_check(uuid, boolean)', '_st_can_salary(uuid)', '_st_settings(uuid)', '_st_shift(uuid, date)',
    '_st_works(uuid, date)', '_st_day(uuid, date)', '_st_salary(uuid, date)', '_st_busy(uuid, date)', '_st_client_key()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

select to_regprocedure('public.staff_get(uuid, date)') is not null and exists (select 1 from storage.buckets where id = 'staff-docs' and not public) as staff_installed;
