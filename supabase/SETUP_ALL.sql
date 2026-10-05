-- =====================================================================
-- NammaStay · SETUP_ALL.sql — the complete backend in one file
-- = 001 + 002 + 003 + 006 + 007 + 008 … 022 + 023_platform_invoices_reminders
-- Run once on a NEW Supabase project (SQL Editor → paste → Run).
-- Then run 004_seed.sql (your hostel + owner) and the optional schedules (005, ota, reminders).
-- ALREADY LIVE? Don't re-run this — run only the newest migration(s) you haven't run yet.
-- =====================================================================


-- >>>>>>>>>>>>>>>>>>>> 001_schema.sql
-- =====================================================================
-- NammaStay · 001_schema.sql
-- Tables, constraints, indexes and triggers.
-- Run in Supabase → SQL Editor, in order: 001, 002, 003, then 004.
--
-- Design rules
--   • Money is stored in paise (integer). ₹700 = 70000. No floating point.
--   • Every row carries property_id, so one database can serve many
--     properties (NammaStay as a product) and every query is scoped.
--   • Composite foreign keys (id, property_id) stop a booking in one
--     property from pointing at a bed or guest from another property.
--   • The database itself refuses double-booked beds (exclusion constraint),
--     so two staff clicking at the same moment can't both win.
-- =====================================================================

create extension if not exists btree_gist with schema extensions;
create extension if not exists pg_trgm   with schema extensions;

-- ---------- Types ----------
create type public.member_role    as enum ('owner','manager','front_desk','accountant');
create type public.booking_status as enum ('pending','confirmed','checked_in','checked_out','cancelled','no_show');
create type public.booking_source as enum ('walk_in','direct','ota','referral');
create type public.payment_method as enum ('upi','cash','card','bank');
create type public.payment_kind   as enum ('payment','refund');
create type public.bed_position   as enum ('lower','upper','single');
create type public.id_doc_type    as enum ('aadhaar','passport','driving_licence','pan','voter_id','other');

-- ---------- Properties & staff ----------
create table public.properties (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(btrim(name)) between 2 and 120),
  kind          text not null default 'hostel' check (kind in ('hostel','hotel','homestay')),
  address       text check (char_length(address) <= 300),
  city          text check (char_length(city) <= 80),
  phone         text check (char_length(phone) <= 20),
  email         text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  upi_id        text check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,256}@[A-Za-z]{2,64}$'),
  timezone      text not null default 'Asia/Kolkata',
  checkin_time  time not null default '14:00',
  checkout_time time not null default '11:00',
  id_doc_retention_days int not null default 180 check (id_doc_retention_days between 1 and 3650),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.property_members (
  property_id  uuid not null references public.properties(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         public.member_role not null,
  display_name text check (char_length(display_name) <= 80),
  email        text,
  last_seen_at timestamptz,
  created_at   timestamptz not null default now(),
  primary key (property_id, user_id)
);
create index property_members_user on public.property_members (user_id);

-- ---------- Rooms & beds ----------
create table public.rooms (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  description text check (char_length(description) <= 200),
  sort        int not null default 0,
  created_at  timestamptz not null default now(),
  unique (property_id, name),
  unique (id, property_id)
);

create table public.beds (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null,
  room_id     uuid not null,
  label       text not null check (char_length(btrim(label)) between 1 and 40),
  position    public.bed_position not null default 'single',
  rate_paise  int  not null check (rate_paise between 0 and 10000000),
  is_active   boolean not null default true,
  sort        int not null default 0,
  created_at  timestamptz not null default now(),
  unique (room_id, label),
  unique (id, property_id),
  foreign key (room_id, property_id) references public.rooms(id, property_id) on delete restrict
);
create index beds_property on public.beds (property_id, sort);

-- Maintenance / out-of-service periods for a bed
create table public.bed_blocks (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null,
  bed_id      uuid not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  period      tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  reason      text not null check (char_length(btrim(reason)) between 2 and 200),
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  check (ends_at > starts_at),
  foreign key (bed_id, property_id) references public.beds(id, property_id) on delete cascade,
  constraint bed_blocks_no_overlap exclude using gist (bed_id with =, period with &&)
);
create index bed_blocks_property on public.bed_blocks using gist (property_id, period);

-- ---------- Guests ----------
create table public.guests (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  full_name   text not null check (char_length(btrim(full_name)) between 2 and 120),
  phone       text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  email       text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  dob         date check (dob is null or dob > '1900-01-01'),
  nationality text check (char_length(nationality) <= 60),
  id_type     public.id_doc_type,
  id_number   text check (char_length(id_number) <= 40),   -- Aadhaar is stored masked: XXXX XXXX 1234
  id_doc_path text,                                          -- file in the private "guest-ids" bucket
  notes       text check (char_length(notes) <= 2000),
  tags        text[] not null default '{}',
  consent_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, property_id)
);
create index guests_property_created on public.guests (property_id, created_at desc);
create index guests_property_phone   on public.guests (property_id, phone);
create index guests_name_trgm  on public.guests using gin (full_name extensions.gin_trgm_ops);
create index guests_phone_trgm on public.guests using gin (phone extensions.gin_trgm_ops);

-- ---------- Bookings ----------
create sequence public.booking_code_seq start 1001;

create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  code          text not null unique default ('BK-' || nextval('public.booking_code_seq')),
  guest_id      uuid not null,
  bed_id        uuid not null,
  visitors      smallint not null default 1 check (visitors between 1 and 20),
  check_in_at   timestamptz not null,
  check_out_at  timestamptz not null,
  stay          tstzrange generated always as (tstzrange(check_in_at, check_out_at, '[)')) stored,
  nights        smallint not null check (nights between 1 and 366),
  rate_paise    int not null check (rate_paise >= 0),
  total_paise   int not null check (total_paise >= 0),
  paid_paise    int not null default 0 check (paid_paise >= 0),
  balance_paise int generated always as (total_paise - paid_paise) stored,
  status        public.booking_status not null default 'pending',
  source        public.booking_source not null default 'walk_in',
  note          text check (char_length(note) <= 2000),
  send_confirmation boolean not null default false,
  self_checkin_token uuid not null default gen_random_uuid() unique,
  self_checkin_at    timestamptz,
  self_checkin_count smallint not null default 0,
  arrived_at    timestamptz,
  departed_at   timestamptz,
  cancelled_at  timestamptz,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (check_out_at > check_in_at),
  check (check_out_at - check_in_at <= interval '367 days'),
  unique (id, property_id),
  foreign key (guest_id, property_id) references public.guests(id, property_id) on delete restrict,
  foreign key (bed_id,   property_id) references public.beds(id,   property_id) on delete restrict,
  -- THE key safety check: one bed can't have two live bookings that overlap in time.
  constraint bookings_no_double_booking exclude using gist (bed_id with =, stay with &&)
    where (status in ('pending','confirmed','checked_in'))
);
create index bookings_list     on public.bookings (property_id, check_in_at desc, id desc);
create index bookings_status   on public.bookings (property_id, status, check_in_at desc);
create index bookings_checkout on public.bookings (property_id, check_out_at);
create index bookings_stay     on public.bookings using gist (property_id, stay);
create index bookings_guest    on public.bookings (guest_id, check_in_at desc);
-- "Pending dues" = money still owed by guests who are staying or have stayed
create index bookings_due      on public.bookings (property_id)
  where balance_paise > 0 and status in ('checked_in','checked_out');

-- ---------- Payments (append-only ledger) ----------
create sequence public.payment_code_seq start 10001;

create table public.payments (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null,
  booking_id   uuid not null,
  code         text not null unique default ('TXN-' || nextval('public.payment_code_seq')),
  kind         public.payment_kind not null default 'payment',
  method       public.payment_method not null,
  amount_paise int  not null check (amount_paise > 0 and amount_paise <= 100000000),
  reference    text check (char_length(reference) <= 64),   -- UPI UTR / card slip no.
  note         text check (char_length(note) <= 500),
  received_at  timestamptz not null default now(),
  received_by  uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete restrict
);
-- The same UPI transaction (UTR) can't be entered twice.
create unique index payments_upi_ref_unique on public.payments (property_id, reference)
  where method = 'upi' and kind = 'payment' and reference is not null;
create index payments_list    on public.payments (property_id, received_at desc, id desc);
create index payments_method  on public.payments (property_id, method, received_at desc);
create index payments_booking on public.payments (booking_id, received_at);

-- ---------- Notifications (in-app badge) ----------
create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,  -- null = everyone at the property
  kind        text not null,
  title       text not null,
  body        text,
  booking_id  uuid,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index notifications_unread on public.notifications (property_id, created_at desc) where read_at is null;
create index notifications_recent on public.notifications (property_id, created_at desc);

-- ---------- Audit log (booking activity timeline) ----------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  property_id uuid not null,
  entity      text not null,
  entity_id   uuid not null,
  booking_id  uuid,
  action      text not null,
  details     jsonb not null default '{}',
  actor       uuid,
  at          timestamptz not null default now()
);
create index audit_booking  on public.audit_log (booking_id, at);
create index audit_property on public.audit_log (property_id, at desc);

-- =====================================================================
-- Trigger functions
-- =====================================================================

create or replace function public._touch_updated_at() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger properties_touch before update on public.properties for each row execute function public._touch_updated_at();
create trigger guests_touch     before update on public.guests     for each row execute function public._touch_updated_at();
create trigger bookings_touch   before update on public.bookings   for each row execute function public._touch_updated_at();

-- Keep bookings.paid_paise equal to the payments ledger
create or replace function public._payments_sync_booking() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.bookings b
     set paid_paise = coalesce((
           select sum(case p.kind when 'payment' then p.amount_paise else -p.amount_paise end)
             from public.payments p where p.booking_id = new.booking_id), 0)
   where b.id = new.booking_id;
  return new;
end $$;
create trigger payments_sync after insert on public.payments
  for each row execute function public._payments_sync_booking();

-- Payments are a ledger: no edits, no deletes. Corrections are refunds.
create or replace function public._payments_immutable() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  raise exception 'Payments can''t be edited or deleted. Record a refund instead.';
end $$;
create trigger payments_no_update before update or delete on public.payments
  for each row execute function public._payments_immutable();

-- Booking activity + staff notifications
create or replace function public._bookings_audit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_guest text;
begin
  if tg_op = 'INSERT' then
    select full_name into v_guest from public.guests where id = new.guest_id;
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'created',
            jsonb_build_object('status', new.status, 'total_paise', new.total_paise), auth.uid());
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (new.property_id, 'booking_created',
            'New booking ' || new.code,
            v_guest || ' · ' || to_char(new.check_in_at at time zone 'Asia/Kolkata', 'DD Mon') ||
            ' – ' || to_char(new.check_out_at at time zone 'Asia/Kolkata', 'DD Mon'),
            new.id);
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'status',
            jsonb_build_object('from', old.status, 'to', new.status), auth.uid());
  end if;
  if new.check_in_at is distinct from old.check_in_at
     or new.check_out_at is distinct from old.check_out_at
     or new.bed_id is distinct from old.bed_id then
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'changed',
            jsonb_build_object('check_in_at', new.check_in_at, 'check_out_at', new.check_out_at,
                               'bed_changed', new.bed_id is distinct from old.bed_id,
                               'total_paise', new.total_paise), auth.uid());
  end if;
  if new.self_checkin_at is distinct from old.self_checkin_at and new.self_checkin_at is not null then
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'self_checkin', '{}'::jsonb, null);
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (new.property_id, 'self_checkin', 'Self check-in submitted', new.code, new.id);
  end if;
  return new;
end $$;
create trigger bookings_audit after insert or update on public.bookings
  for each row execute function public._bookings_audit();

create or replace function public._payments_audit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (new.property_id, 'payment', new.id, new.booking_id, new.kind::text,
          jsonb_build_object('amount_paise', new.amount_paise, 'method', new.method, 'code', new.code),
          auth.uid());
  return new;
end $$;
create trigger payments_audit after insert on public.payments
  for each row execute function public._payments_audit();

-- Live in-app badge: stream new notifications to signed-in staff
alter publication supabase_realtime add table public.notifications;


-- >>>>>>>>>>>>>>>>>>>> 002_security.sql
-- =====================================================================
-- NammaStay · 002_security.sql
-- Who can see and change what. Row Level Security (RLS) on every table,
-- explicit grants, and the private bucket for guest ID photos.
--
-- Roles
--   owner       everything, incl. team and settings
--   manager     bookings, rooms, payments, reports, property settings
--   front_desk  check-in/out, bookings, guest profiles, payments
--   accountant  payments & reports; read-only elsewhere; no guest ID data
--
-- Writes to bookings and payments go ONLY through the functions in 003,
-- which validate every rule. Staff can't insert/update those tables directly.
-- =====================================================================

-- ---------- Helper: which properties can the signed-in user access? ----------
create or replace function public.my_property_ids(p_roles public.member_role[] default null)
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select property_id from public.property_members
   where user_id = auth.uid()
     and (p_roles is null or role = any (p_roles))
$$;

create or replace function public._assert_role(p_property uuid, p_roles public.member_role[])
returns public.member_role
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.member_role;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '42501';
  end if;
  select role into r from public.property_members
   where property_id = p_property and user_id = auth.uid();
  if r is null or not (r = any (p_roles)) then
    raise exception 'You don''t have permission to do this.' using errcode = '42501';
  end if;
  return r;
end $$;

-- ---------- Enable RLS everywhere ----------
alter table public.properties       enable row level security;
alter table public.property_members enable row level security;
alter table public.rooms            enable row level security;
alter table public.beds             enable row level security;
alter table public.bed_blocks       enable row level security;
alter table public.guests           enable row level security;
alter table public.bookings         enable row level security;
alter table public.payments         enable row level security;
alter table public.notifications    enable row level security;
alter table public.audit_log        enable row level security;

-- ---------- Policies ----------
-- properties
create policy properties_select on public.properties for select to authenticated
  using (id in (select public.my_property_ids()));
create policy properties_update on public.properties for update to authenticated
  using      (id in (select public.my_property_ids(array['owner','manager']::public.member_role[])))
  with check (id in (select public.my_property_ids(array['owner','manager']::public.member_role[])));

-- staff list (read-only here; changes via add_member / remove_member)
create policy members_select on public.property_members for select to authenticated
  using (property_id in (select public.my_property_ids()));

-- rooms & beds: everyone reads, owner/manager edit
create policy rooms_select on public.rooms for select to authenticated
  using (property_id in (select public.my_property_ids()));
create policy rooms_write on public.rooms for all to authenticated
  using      (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])))
  with check (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])));

create policy beds_select on public.beds for select to authenticated
  using (property_id in (select public.my_property_ids()));
create policy beds_write on public.beds for all to authenticated
  using      (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])))
  with check (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])));

create policy blocks_select on public.bed_blocks for select to authenticated
  using (property_id in (select public.my_property_ids()));
create policy blocks_write on public.bed_blocks for all to authenticated
  using      (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])))
  with check (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])));

-- guests: personal data → no accountant access
create policy guests_select on public.guests for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])));
create policy guests_update on public.guests for update to authenticated
  using      (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])))
  with check (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])));

-- bookings & payments: read for all staff; writes only through functions
create policy bookings_select on public.bookings for select to authenticated
  using (property_id in (select public.my_property_ids()));
create policy payments_select on public.payments for select to authenticated
  using (property_id in (select public.my_property_ids()));

-- notifications: your property, addressed to everyone or to you
create policy notif_select on public.notifications for select to authenticated
  using (property_id in (select public.my_property_ids())
         and (user_id is null or user_id = (select auth.uid())));
create policy notif_update on public.notifications for update to authenticated
  using      (property_id in (select public.my_property_ids())
              and (user_id is null or user_id = (select auth.uid())))
  with check (property_id in (select public.my_property_ids()));

create policy audit_select on public.audit_log for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])));

-- ---------- Grants (explicit; nothing for anonymous visitors) ----------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select on public.properties, public.property_members, public.rooms, public.beds,
                public.bed_blocks, public.guests, public.bookings, public.payments,
                public.notifications, public.audit_log to authenticated;

grant update (name, kind, address, city, phone, email, upi_id, checkin_time, checkout_time,
              id_doc_retention_days) on public.properties to authenticated;
grant insert, update, delete on public.rooms, public.beds, public.bed_blocks to authenticated;
grant update (full_name, phone, email, dob, nationality, notes, tags) on public.guests to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- ---------- Private storage bucket for ID photos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('guest-ids', 'guest-ids', false, 5242880,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Path layout:  {property_id}/{booking self-check-in token}/{file}
-- Guests (not signed in) may upload ONLY into a folder whose token belongs to
-- a live booking of that property, max 3 files per booking.
create or replace function public.checkin_upload_allowed(p_name text)
returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  parts text[] := string_to_array(p_name, '/');
  v_ok boolean;
  v_count int;
begin
  if array_length(parts, 1) <> 3
     or parts[1] !~ '^[0-9a-f-]{36}$' or parts[2] !~ '^[0-9a-f-]{36}$' then
    return false;
  end if;
  select true into v_ok from public.bookings
   where property_id = parts[1]::uuid
     and self_checkin_token = parts[2]::uuid
     and status in ('pending','confirmed','checked_in')
     and check_out_at > now();
  if v_ok is not true then return false; end if;
  select count(*) into v_count from storage.objects
   where bucket_id = 'guest-ids' and name like parts[1] || '/' || parts[2] || '/%';
  return v_count < 3;
end $$;

create policy "guest-ids: staff read" on storage.objects for select to authenticated
  using (bucket_id = 'guest-ids' and exists (
    select 1 from public.my_property_ids(array['owner','manager','front_desk']::public.member_role[]) pid
     where pid::text = (storage.foldername(name))[1]));

create policy "guest-ids: staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'guest-ids' and exists (
    select 1 from public.my_property_ids(array['owner','manager','front_desk']::public.member_role[]) pid
     where pid::text = (storage.foldername(name))[1]));

create policy "guest-ids: guest self check-in upload" on storage.objects for insert to anon
  with check (bucket_id = 'guest-ids' and public.checkin_upload_allowed(name));


-- >>>>>>>>>>>>>>>>>>>> 003_functions.sql
-- =====================================================================
-- NammaStay · 003_functions.sql
-- Every query the app runs. The browser calls these with supabase.rpc().
-- Each function checks the caller's role first, validates input, and only
-- returns one page of rows at a time, so screens stay fast at lakhs of rows.
-- =====================================================================

-- ---------- Small helpers ----------
create or replace function public._tz(p_property uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select timezone from public.properties where id = p_property
$$;

create or replace function public._local_date(p_property uuid, p_ts timestamptz) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (p_ts at time zone public._tz(p_property))::date
$$;

-- A bed counts as occupied on a night if a stay covers 8 PM local time that day.
create or replace function public._night(p_tz text, p_day date) returns timestamptz
language sql stable set search_path = public, pg_temp as $$
  select (p_day + time '20:00') at time zone p_tz
$$;

create or replace function public._day_start(p_tz text, p_day date) returns timestamptz
language sql stable set search_path = public, pg_temp as $$
  select p_day::timestamp at time zone p_tz
$$;

-- "98400 12233" → "+919840012233"; keeps an explicit country code if given.
create or replace function public._clean_phone(p text) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare d text;
begin
  if p is null or btrim(p) = '' then return null; end if;
  d := regexp_replace(p, '[^0-9]', '', 'g');
  if btrim(p) like '+%' then return '+' || d; end if;
  if length(d) = 10 then return '+91' || d; end if;
  if length(d) = 12 and d like '91%' then return '+' || d; end if;
  return d;
end $$;

-- Aadhaar is never stored in full: only the last 4 digits are kept.
create or replace function public._mask_id(p_type text, p_num text) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare d text;
begin
  if p_num is null or btrim(p_num) = '' then return null; end if;
  if p_type = 'aadhaar' then
    d := regexp_replace(p_num, '[^0-9]', '', 'g');
    if length(d) = 12 or length(d) = 4 then
      return 'XXXX XXXX ' || right(d, 4);
    end if;
    raise exception 'Aadhaar number must have 12 digits.';
  end if;
  return upper(regexp_replace(btrim(p_num), '\s+', ' ', 'g'));
end $$;

create or replace function public._check_dob(p_dob date) returns void
language plpgsql stable set search_path = public, pg_temp as $$
begin
  if p_dob is null then return; end if;
  if p_dob > current_date then raise exception 'Date of birth can''t be in the future.'; end if;
  if p_dob < current_date - interval '120 years' then raise exception 'Please check the date of birth.'; end if;
end $$;

-- ---------- Session ----------
create or replace function public.my_memberships()
returns table (property_id uuid, property_name text, role public.member_role, display_name text)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.property_id, p.name, m.role, m.display_name
    from public.property_members m join public.properties p on p.id = m.property_id
   where m.user_id = auth.uid()
   order by p.name
$$;

create or replace function public.touch_presence(p_property uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.property_members set last_seen_at = now()
   where property_id = p_property and user_id = auth.uid()
     and (last_seen_at is null or last_seen_at < now() - interval '5 minutes')
$$;

-- =====================================================================
-- Bookings
-- =====================================================================

create or replace function public.create_booking(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prop   uuid := (p->>'property_id')::uuid;
  v_in     timestamptz := (p->>'check_in_at')::timestamptz;
  v_out    timestamptz := (p->>'check_out_at')::timestamptz;
  v_status public.booking_status := coalesce(nullif(p->>'status', ''), 'pending')::public.booking_status;
  v_guest  uuid := nullif(p->>'guest_id', '')::uuid;
  v_bed    public.beds%rowtype;
  v_nights int;
  v_b      public.bookings%rowtype;
  v_pay    jsonb := p->'payment';
  v_dob    date := nullif(p#>>'{guest,dob}', '')::date;
begin
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);

  if v_in is null or v_out is null then raise exception 'Check-in and check-out are required.'; end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;
  if v_in < now() - interval '2 days' then raise exception 'Check-in can''t be more than 2 days in the past.'; end if;
  if v_in > now() + interval '2 years' then raise exception 'Check-in is too far in the future.'; end if;
  if v_status not in ('pending','confirmed','checked_in') then raise exception 'A new booking must be pending, confirmed or checked in.'; end if;
  if v_status = 'checked_in' and public._local_date(v_prop, v_in) > public._local_date(v_prop, now()) then
    raise exception 'You can only check in a guest whose stay starts today.';
  end if;

  select * into v_bed from public.beds where id = (p->>'bed_id')::uuid and property_id = v_prop;
  if not found then raise exception 'Please choose a bed.'; end if;
  if not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  if v_guest is null then
    if coalesce(btrim(p#>>'{guest,full_name}'), '') = '' then raise exception 'Guest name is required.'; end if;
    perform public._check_dob(v_dob);
    insert into public.guests (property_id, full_name, phone, email, dob, nationality, id_type, id_number, id_doc_path, consent_at)
    values (v_prop,
            btrim(p#>>'{guest,full_name}'),
            public._clean_phone(p#>>'{guest,phone}'),
            nullif(lower(btrim(p#>>'{guest,email}')), ''),
            v_dob,
            nullif(btrim(p#>>'{guest,nationality}'), ''),
            nullif(p#>>'{guest,id_type}', '')::public.id_doc_type,
            public._mask_id(nullif(p#>>'{guest,id_type}', ''), p#>>'{guest,id_number}'),
            nullif(p#>>'{guest,id_doc_path}', ''),
            now())
    returning id into v_guest;
  elsif not exists (select 1 from public.guests where id = v_guest and property_id = v_prop) then
    raise exception 'Guest not found.';
  end if;

  v_nights := greatest(1, public._local_date(v_prop, v_out) - public._local_date(v_prop, v_in));

  begin
    insert into public.bookings (property_id, guest_id, bed_id, visitors, check_in_at, check_out_at,
                                 nights, rate_paise, total_paise, status, source, note,
                                 send_confirmation, arrived_at)
    values (v_prop, v_guest, v_bed.id,
            coalesce(nullif(p->>'visitors', '')::smallint, 1),
            v_in, v_out, v_nights, v_bed.rate_paise, v_nights * v_bed.rate_paise,
            v_status,
            coalesce(nullif(p->>'source', ''), 'walk_in')::public.booking_source,
            nullif(btrim(p->>'note'), ''),
            coalesce((p->>'send_confirmation')::boolean, false),
            case when v_status = 'checked_in' then now() end)
    returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  if v_pay is not null and coalesce((v_pay->>'amount_paise')::int, 0) > 0 then
    perform public.record_payment(v_b.id, (v_pay->>'amount_paise')::int, v_pay->>'method',
                                  v_pay->>'reference', 'payment', null);
  end if;

  return jsonb_build_object('id', v_b.id, 'code', v_b.code, 'nights', v_nights,
                            'total_paise', v_b.total_paise,
                            'self_checkin_token', v_b.self_checkin_token);
end $$;

create or replace function public.update_booking(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_bed  public.beds%rowtype;
  v_in   timestamptz;
  v_out  timestamptz;
  v_rate int;
  v_nights int;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if v_b.status not in ('pending','confirmed','checked_in') then
    raise exception 'This booking is % and can''t be changed.', replace(v_b.status::text, '_', ' ');
  end if;

  v_in  := coalesce((p->>'check_in_at')::timestamptz,  v_b.check_in_at);
  v_out := coalesce((p->>'check_out_at')::timestamptz, v_b.check_out_at);
  if v_b.status = 'checked_in' and v_in <> v_b.check_in_at then
    raise exception 'Guest is already checked in; only the check-out can change.';
  end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;

  select * into v_bed from public.beds
   where id = coalesce(nullif(p->>'bed_id', '')::uuid, v_b.bed_id) and property_id = v_b.property_id;
  if not found then raise exception 'Bed not found.'; end if;
  if v_bed.id <> v_b.bed_id and not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  v_rate   := case when v_bed.id = v_b.bed_id then v_b.rate_paise else v_bed.rate_paise end;
  v_nights := greatest(1, public._local_date(v_b.property_id, v_out) - public._local_date(v_b.property_id, v_in));
  if v_nights * v_rate < v_b.paid_paise then
    raise exception 'New total is less than what''s already paid. Record a refund first.';
  end if;

  begin
    update public.bookings
       set check_in_at = v_in, check_out_at = v_out, bed_id = v_bed.id,
           rate_paise = v_rate, nights = v_nights, total_paise = v_nights * v_rate,
           visitors = coalesce(nullif(p->>'visitors', '')::smallint, visitors),
           note = case when p ? 'note' then nullif(btrim(p->>'note'), '') else note end
     where id = p_booking
     returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  return jsonb_build_object('id', v_b.id, 'total_paise', v_b.total_paise, 'nights', v_b.nights);
end $$;

-- confirm | check_in | check_out | cancel | no_show
create or replace function public.booking_action(p_booking uuid, p_action text, p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b public.bookings%rowtype;
  v_today date;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  v_today := public._local_date(v_b.property_id, now());

  if p_action = 'confirm' then
    if v_b.status <> 'pending' then raise exception 'Only pending bookings can be confirmed.'; end if;
    update public.bookings set status = 'confirmed' where id = p_booking;

  elsif p_action = 'check_in' then
    if v_b.status not in ('pending','confirmed') then raise exception 'This booking can''t be checked in.'; end if;
    if public._local_date(v_b.property_id, v_b.check_in_at) > v_today then
      raise exception 'Check-in is on %. Change the dates to check in early.',
        to_char(v_b.check_in_at at time zone public._tz(v_b.property_id), 'DD Mon');
    end if;
    if v_b.check_out_at <= now() then raise exception 'This stay has already ended.'; end if;
    update public.bookings set status = 'checked_in', arrived_at = now() where id = p_booking;

  elsif p_action = 'check_out' then
    if v_b.status <> 'checked_in' then raise exception 'Only checked-in guests can be checked out.'; end if;
    if v_b.balance_paise > 0 and not p_force then
      raise exception 'Balance of ₹% is still due. Record the payment first.',
        to_char(v_b.balance_paise / 100.0, 'FM99,99,99,990.00');
    end if;
    update public.bookings
       set status = 'checked_out', departed_at = now(),
           check_out_at = least(check_out_at, now())   -- early departure frees the bed
     where id = p_booking;

  elsif p_action = 'cancel' then
    if v_b.status not in ('pending','confirmed') then raise exception 'Only pending or confirmed bookings can be cancelled.'; end if;
    update public.bookings set status = 'cancelled', cancelled_at = now() where id = p_booking;

  elsif p_action = 'no_show' then
    if v_b.status not in ('pending','confirmed') then raise exception 'Only pending or confirmed bookings can be marked no-show.'; end if;
    if public._local_date(v_b.property_id, v_b.check_in_at) > v_today then
      raise exception 'The guest isn''t due yet.';
    end if;
    update public.bookings set status = 'no_show' where id = p_booking;

  else
    raise exception 'Unknown action.';
  end if;

  return jsonb_build_object('id', p_booking, 'action', p_action);
end $$;

-- Payments are append-only. A refund is a separate negative entry.
create or replace function public.record_payment(
  p_booking uuid, p_amount_paise int, p_method text, p_reference text default null,
  p_kind text default 'payment', p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_ref  text := nullif(upper(regexp_replace(coalesce(p_reference, ''), '\s', '', 'g')), '');
  v_pay  public.payments%rowtype;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;

  if p_kind = 'refund' then
    perform public._assert_role(v_b.property_id, array['owner','manager']::public.member_role[]);
  else
    perform public._assert_role(v_b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  end if;

  if p_amount_paise is null or p_amount_paise <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if p_method not in ('upi','cash','card','bank') then raise exception 'Choose a payment method.'; end if;

  if p_kind = 'payment' then
    if v_b.status in ('cancelled','no_show') then raise exception 'Can''t take payment on a % booking.', v_b.status; end if;
    if p_amount_paise > v_b.balance_paise then
      raise exception 'Amount is more than the balance due (₹%).', to_char(v_b.balance_paise / 100.0, 'FM99,99,99,990.00');
    end if;
    if p_method = 'upi' and (v_ref is null or v_ref !~ '^[0-9A-Z]{6,35}$') then
      raise exception 'Enter the UPI transaction ID (UTR) from the guest''s payment screen.';
    end if;
  elsif p_kind = 'refund' then
    if p_amount_paise > v_b.paid_paise then raise exception 'Refund is more than the amount paid.'; end if;
  else
    raise exception 'Unknown payment type.';
  end if;

  begin
    insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, note)
    values (v_b.property_id, v_b.id, p_kind::public.payment_kind, p_method::public.payment_method,
            p_amount_paise, v_ref, nullif(btrim(p_note), ''))
    returning * into v_pay;
  exception when unique_violation then
    raise exception 'UPI transaction % was already recorded.', v_ref using errcode = '23505';
  end;

  return jsonb_build_object('id', v_pay.id, 'code', v_pay.code);
end $$;

-- ---------- Booking lists (keyset pagination: fast on page 1 and page 5,000) ----------
create or replace function public.list_bookings(
  p_property uuid, p_status text default null, p_q text default null,
  p_cursor_check_in timestamptz default null, p_cursor_id uuid default null, p_limit int default 30)
returns table (id uuid, code text, guest_id uuid, guest_name text, guest_phone text,
               room_name text, bed_label text, check_in_at timestamptz, check_out_at timestamptz,
               total_paise int, paid_paise int, balance_paise int,
               status public.booking_status, source public.booking_source)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  v_role   public.member_role;
  v_q      text := nullif(btrim(p_q), '');
  v_digits text;
  v_like   text;
begin
  v_role   := public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  v_like   := '%' || replace(replace(coalesce(v_q, ''), '%', ''), '_', '') || '%';

  return query
  select b.id, b.code, b.guest_id, g.full_name,
         case when v_role = 'accountant' then null else g.phone end,
         r.name, bd.label, b.check_in_at, b.check_out_at,
         b.total_paise, b.paid_paise, b.balance_paise, b.status, b.source
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    join public.beds  bd on bd.id = b.bed_id
    join public.rooms r  on r.id = bd.room_id
   where b.property_id = p_property
     and (p_status is null or b.status = p_status::public.booking_status)
     and (v_q is not null or b.check_out_at >= now() - interval '30 days')
     and (v_q is null
          or upper(b.code) = upper(v_q)
          or (v_digits <> '' and b.code = 'BK-' || v_digits)
          or g.full_name ilike v_like
          or (length(v_digits) >= 4 and g.phone like '%' || v_digits || '%'))
     and (p_cursor_check_in is null or (b.check_in_at, b.id) < (p_cursor_check_in, p_cursor_id))
   order by b.check_in_at desc, b.id desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

create or replace function public.booking_status_counts(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status, count(*) n from public.bookings
           where property_id = p_property and check_out_at >= now() - interval '30 days'
           group by status) s;
  return v || jsonb_build_object('all', (select coalesce(sum(value::int), 0) from jsonb_each_text(v)));
end $$;

create or replace function public.occupancy_series(p_property uuid, p_from date, p_to date)
returns table (day date, occupied int, total int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_tz text; v_total int;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if p_to < p_from or p_to - p_from > 400 then raise exception 'Choose a range of up to 400 days.'; end if;
  v_tz := public._tz(p_property);
  select count(*) into v_total from public.beds where property_id = p_property and is_active;
  return query
  select d::date,
         (select count(*) from public.bookings b
           where b.property_id = p_property
             and b.status in ('pending','confirmed','checked_in','checked_out')
             and b.stay @> public._night(v_tz, d::date))::int,
         v_total
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d;
end $$;

create or replace function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_role public.member_role;
  v      jsonb;
begin
  select * into v_b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  v_role := public._assert_role(v_b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);

  select jsonb_build_object(
    'booking', to_jsonb(v_b) - 'self_checkin_token'
               || case when v_role <> 'accountant'
                       then jsonb_build_object('self_checkin_token', v_b.self_checkin_token) else '{}'::jsonb end,
    'guest', case when v_role = 'accountant'
                  then jsonb_build_object('id', g.id, 'full_name', g.full_name)
                  else jsonb_build_object('id', g.id, 'full_name', g.full_name, 'phone', g.phone,
                         'email', g.email, 'nationality', g.nationality, 'id_type', g.id_type,
                         'id_number', g.id_number, 'id_doc_path', g.id_doc_path, 'dob', g.dob) end,
    'bed',  jsonb_build_object('id', bd.id, 'label', bd.label, 'room', r.name),
    'property', jsonb_build_object('id', p.id, 'name', p.name, 'upi_id', p.upi_id, 'timezone', p.timezone),
    'created_by', (select coalesce(m.display_name, m.email) from public.property_members m
                    where m.property_id = v_b.property_id and m.user_id = v_b.created_by),
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
                    'code', x.code, 'kind', x.kind, 'method', x.method, 'amount_paise', x.amount_paise,
                    'reference', x.reference, 'received_at', x.received_at) order by x.received_at)
                  from public.payments x where x.booking_id = v_b.id), '[]'::jsonb),
    'activity', case when v_role = 'accountant' then '[]'::jsonb else
                coalesce((select jsonb_agg(jsonb_build_object(
                    'action', a.action, 'details', a.details, 'at', a.at,
                    'by', (select coalesce(m.display_name, m.email) from public.property_members m
                            where m.property_id = a.property_id and m.user_id = a.actor)) order by a.at)
                  from public.audit_log a where a.booking_id = v_b.id), '[]'::jsonb) end)
  into v
  from public.guests g, public.beds bd, public.rooms r, public.properties p
  where g.id = v_b.guest_id and bd.id = v_b.bed_id and r.id = bd.room_id and p.id = v_b.property_id;
  return v;
end $$;

-- ---------- Dashboard ----------
create or replace function public.dashboard_summary(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz    text;
  v_today date;
  t0 timestamptz; t1 timestamptz; y0 timestamptz;
  v_beds int; v_occ int; v_occ_y int;
  v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz    := public._tz(p_property);
  v_today := (now() at time zone v_tz)::date;
  t0 := public._day_start(v_tz, v_today);
  t1 := t0 + interval '1 day';
  y0 := t0 - interval '1 day';

  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  select count(*) into v_occ from public.bookings
   where property_id = p_property and status in ('pending','confirmed','checked_in')
     and stay @> public._night(v_tz, v_today);
  select count(*) into v_occ_y from public.bookings
   where property_id = p_property and status in ('pending','confirmed','checked_in','checked_out')
     and stay @> public._night(v_tz, v_today - 1);

  select jsonb_build_object(
    'today', v_today,
    'beds_total', v_beds,
    'beds_occupied', v_occ,
    'beds_occupied_yesterday', v_occ_y,
    'checkins_today', (select count(*) from public.bookings where property_id = p_property
                        and check_in_at >= t0 and check_in_at < t1 and status in ('pending','confirmed','checked_in')),
    'checkins_pending', (select count(*) from public.bookings where property_id = p_property
                        and check_in_at >= t0 and check_in_at < t1 and status in ('pending','confirmed')),
    'checkouts_today', (select count(*) from public.bookings where property_id = p_property
                        and check_out_at >= t0 and check_out_at < t1 and status in ('checked_in','checked_out')),
    'checkouts_late', (select count(*) from public.bookings where property_id = p_property
                        and status = 'checked_in' and check_out_at < now()),
    'revenue_today', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                        from public.payments where property_id = p_property and received_at >= t0 and received_at < t1),
    'revenue_yesterday', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                        from public.payments where property_id = p_property and received_at >= y0 and received_at < t0),
    'dues_paise', (select coalesce(sum(balance_paise), 0) from public.bookings where property_id = p_property
                        and balance_paise > 0 and status in ('checked_in','checked_out')),
    'dues_count', (select count(*) from public.bookings where property_id = p_property
                        and balance_paise > 0 and status in ('checked_in','checked_out')),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('day', s.day, 'occupied', s.occupied) order by s.day), '[]'::jsonb)
                 from public.occupancy_series(p_property, v_today - 6, v_today) s),
    'arriving', (select coalesce(jsonb_agg(x order by x->>'check_in_at'), '[]'::jsonb) from (
                   select jsonb_build_object('id', b.id, 'guest', g.full_name, 'room', r.name, 'bed', bd.label,
                          'check_in_at', b.check_in_at, 'status', b.status) x
                     from public.bookings b join public.guests g on g.id = b.guest_id
                     join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                    where b.property_id = p_property and b.check_in_at >= t0 and b.check_in_at < t1
                      and b.status in ('pending','confirmed','checked_in')
                    order by b.check_in_at limit 8) q),
    'departing', (select coalesce(jsonb_agg(x order by x->>'check_out_at'), '[]'::jsonb) from (
                   select jsonb_build_object('id', b.id, 'guest', g.full_name, 'room', r.name, 'bed', bd.label,
                          'check_out_at', b.check_out_at, 'status', b.status,
                          'overdue', b.status = 'checked_in' and b.check_out_at < now()) x
                     from public.bookings b join public.guests g on g.id = b.guest_id
                     join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                    where b.property_id = p_property
                      and ((b.check_out_at >= t0 and b.check_out_at < t1 and b.status in ('checked_in','checked_out'))
                           or (b.status = 'checked_in' and b.check_out_at < t0))
                    order by b.check_out_at limit 8) q)
  ) into v;
  return v;
end $$;

-- ---------- Rooms board & calendar ----------
create or replace function public.bed_board(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; t0 timestamptz; t1 timestamptz; v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, (now() at time zone v_tz)::date);
  t1 := t0 + interval '1 day';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'name', r.name, 'description', r.description,
           'beds', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', bd.id, 'label', bd.label, 'position', bd.position,
                      'rate_paise', bd.rate_paise, 'is_active', bd.is_active,
                      'block', (select k.reason from public.bed_blocks k
                                 where k.bed_id = bd.id and k.period @> now() limit 1),
                      'booking', (select jsonb_build_object('id', b.id, 'guest', g.full_name, 'status', b.status,
                                          'check_out_at', b.check_out_at)
                                    from public.bookings b join public.guests g on g.id = b.guest_id
                                   where b.bed_id = bd.id and b.status in ('pending','confirmed','checked_in')
                                     and b.stay && tstzrange(t0, t1, '[)')
                                   order by (b.status = 'checked_in') desc, b.check_in_at limit 1)
                    ) order by bd.sort, bd.label), '[]'::jsonb)
                    from public.beds bd where bd.room_id = r.id)
         ) order by r.sort, r.name), '[]'::jsonb)
    into v
    from public.rooms r where r.property_id = p_property;
  return v;
end $$;

create or replace function public.calendar_range(p_property uuid, p_from date, p_days int default 9) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; t0 timestamptz; t1 timestamptz;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if p_days < 1 or p_days > 62 then raise exception 'Choose between 1 and 62 days.'; end if;
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_from + p_days);
  return jsonb_build_object(
    'beds', (select coalesce(jsonb_agg(jsonb_build_object('id', bd.id, 'label', bd.label, 'room', r.name,
                     'room_id', r.id) order by r.sort, r.name, bd.sort, bd.label), '[]'::jsonb)
               from public.beds bd join public.rooms r on r.id = bd.room_id
              where bd.property_id = p_property and bd.is_active),
    'bookings', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'bed_id', b.bed_id, 'guest', g.full_name,
                     'status', b.status, 'balance_paise', b.balance_paise, 'paid_paise', b.paid_paise,
                     'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at)), '[]'::jsonb)
               from public.bookings b join public.guests g on g.id = b.guest_id
              where b.property_id = p_property and b.stay && tstzrange(t0, t1, '[)')
                and b.status in ('pending','confirmed','checked_in','checked_out')),
    'blocks', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'bed_id', k.bed_id, 'reason', k.reason,
                     'starts_at', k.starts_at, 'ends_at', k.ends_at)), '[]'::jsonb)
               from public.bed_blocks k
              where k.property_id = p_property and k.period && tstzrange(t0, t1, '[)')));
end $$;

create or replace function public.available_beds(p_property uuid, p_in timestamptz, p_out timestamptz)
returns table (id uuid, label text, room_id uuid, room_name text, rate_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query
  select bd.id, bd.label, r.id, r.name, bd.rate_paise
    from public.beds bd join public.rooms r on r.id = bd.room_id
   where bd.property_id = p_property and bd.is_active
     and not exists (select 1 from public.bookings b where b.bed_id = bd.id
                      and b.status in ('pending','confirmed','checked_in')
                      and b.stay && tstzrange(p_in, p_out, '[)'))
     and not exists (select 1 from public.bed_blocks k where k.bed_id = bd.id
                      and k.period && tstzrange(p_in, p_out, '[)'))
   order by r.sort, r.name, bd.sort, bd.label;
end $$;

create or replace function public.set_bed_block(p_bed uuid, p_from timestamptz, p_to timestamptz, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bed public.beds%rowtype; v_id uuid;
begin
  select * into v_bed from public.beds where id = p_bed;
  if not found then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_bed.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if exists (select 1 from public.bookings b where b.bed_id = p_bed
              and b.status in ('pending','confirmed','checked_in') and b.stay && tstzrange(p_from, p_to, '[)')) then
    raise exception '% has bookings in that period. Move them first.', v_bed.label;
  end if;
  begin
    insert into public.bed_blocks (property_id, bed_id, starts_at, ends_at, reason)
    values (v_bed.property_id, p_bed, p_from, p_to, p_reason) returning id into v_id;
  exception when exclusion_violation then
    raise exception '% is already blocked for part of that period.', v_bed.label;
  end;
  return v_id;
end $$;

-- ---------- Payments ----------
create or replace function public.list_payments(
  p_property uuid, p_method text default null, p_from date default null, p_to date default null,
  p_cursor_at timestamptz default null, p_cursor_id uuid default null, p_limit int default 30)
returns table (id uuid, code text, booking_id uuid, booking_code text, guest_name text,
               kind public.payment_kind, method public.payment_method, amount_paise int,
               reference text, received_at timestamptz, booking_balance_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_tz text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  return query
  select x.id, x.code, b.id, b.code, g.full_name, x.kind, x.method, x.amount_paise,
         x.reference, x.received_at, b.balance_paise
    from public.payments x
    join public.bookings b on b.id = x.booking_id
    join public.guests   g on g.id = b.guest_id
   where x.property_id = p_property
     and (p_method is null or x.method = p_method::public.payment_method)
     and (p_from is null or x.received_at >= public._day_start(v_tz, p_from))
     and (p_to   is null or x.received_at <  public._day_start(v_tz, p_to + 1))
     and (p_cursor_at is null or (x.received_at, x.id) < (p_cursor_at, p_cursor_id))
   order by x.received_at desc, x.id desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

create or replace function public.payment_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; t0 timestamptz; t1 timestamptz; pt0 timestamptz; v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_to + 1);
  pt0 := t0 - (t1 - t0);
  select jsonb_build_object(
    'revenue', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end)
                        filter (where received_at >= t0), 0),
    'previous', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end)
                        filter (where received_at < t0), 0),
    'upi',  coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'upi'  and received_at >= t0), 0),
    'cash', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'cash' and received_at >= t0), 0),
    'card', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'card' and received_at >= t0), 0),
    'bank', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'bank' and received_at >= t0), 0))
    into v
    from public.payments
   where property_id = p_property and received_at >= pt0 and received_at < t1;
  return v || jsonb_build_object(
    'dues_paise', (select coalesce(sum(balance_paise), 0) from public.bookings where property_id = p_property
                    and balance_paise > 0 and status in ('checked_in','checked_out')),
    'dues_count', (select count(*) from public.bookings where property_id = p_property
                    and balance_paise > 0 and status in ('checked_in','checked_out')));
end $$;

-- ---------- Guests ----------
create or replace function public.guest_profile(p_guest uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_g public.guests%rowtype;
begin
  select * into v_g from public.guests where id = p_guest;
  if not found then raise exception 'Guest not found.'; end if;
  perform public._assert_role(v_g.property_id, array['owner','manager','front_desk']::public.member_role[]);
  return jsonb_build_object(
    'guest', to_jsonb(v_g),
    'visits', (select count(*) from public.bookings where guest_id = p_guest and status in ('confirmed','checked_in','checked_out')),
    'spend_paise', (select coalesce(sum(paid_paise), 0) from public.bookings where guest_id = p_guest),
    'last_stay', (select jsonb_build_object('check_in_at', check_in_at, 'check_out_at', check_out_at)
                    from public.bookings where guest_id = p_guest and status in ('checked_in','checked_out')
                   order by check_in_at desc limit 1),
    'current', (select jsonb_build_object('id', b.id, 'room', r.name, 'bed', bd.label, 'check_out_at', b.check_out_at)
                  from public.bookings b join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                 where b.guest_id = p_guest and b.status = 'checked_in' limit 1),
    'stays', (select coalesce(jsonb_agg(s order by s->>'check_in_at' desc), '[]'::jsonb) from (
                select jsonb_build_object('id', b.id, 'code', b.code, 'room', r.name, 'bed', bd.label,
                       'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at,
                       'paid_paise', b.paid_paise, 'status', b.status) s
                  from public.bookings b join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                 where b.guest_id = p_guest order by b.check_in_at desc limit 50) q));
end $$;

create or replace function public.search_guests(p_property uuid, p_q text)
returns table (id uuid, full_name text, phone text, email text, nationality text, last_check_in timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_q text := btrim(coalesce(p_q, '')); v_digits text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  v_digits := regexp_replace(v_q, '[^0-9]', '', 'g');
  if length(v_q) < 3 then return; end if;
  return query
  select g.id, g.full_name, g.phone, g.email, g.nationality,
         (select max(b.check_in_at) from public.bookings b where b.guest_id = g.id)
    from public.guests g
   where g.property_id = p_property
     and ((length(v_digits) >= 6 and g.phone like '%' || v_digits || '%')
          or g.full_name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
   order by g.created_at desc
   limit 8;
end $$;

-- ---------- Reports ----------
create or replace function public.report_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz text; t0 timestamptz; t1 timestamptz;
  v_days int; v_beds int; v_revenue bigint; v_bed_nights bigint;
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Choose a range of up to one year.'; end if;
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_to + 1);
  v_days := p_to - p_from + 1;
  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0) into v_revenue
    from public.payments where property_id = p_property and received_at >= t0 and received_at < t1;
  select coalesce(sum(occupied), 0) into v_bed_nights from public.occupancy_series(p_property, p_from, p_to);

  return jsonb_build_object(
    'revenue', v_revenue,
    'days', v_days,
    'beds', v_beds,
    'occupancy', case when v_beds * v_days = 0 then 0 else round(v_bed_nights::numeric / (v_beds * v_days), 4) end,
    'revpab', case when v_beds * v_days = 0 then 0 else round(v_revenue::numeric / (v_beds * v_days)) end,
    'alos', (select coalesce(round(avg(nights), 1), 0) from public.bookings where property_id = p_property
              and check_in_at >= t0 and check_in_at < t1 and status in ('confirmed','checked_in','checked_out')),
    'weekly', (select coalesce(jsonb_agg(w order by w->>'start'), '[]'::jsonb) from (
                 select jsonb_build_object('start', ws::date,
                   'digital', coalesce(sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end)
                                        filter (where x.method <> 'cash'), 0),
                   'cash',    coalesce(sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end)
                                        filter (where x.method = 'cash'), 0)) w
                   from generate_series(p_from::timestamp, p_to::timestamp, interval '7 days') ws
                   left join public.payments x
                     on x.property_id = p_property
                    and x.received_at >= public._day_start(v_tz, ws::date)
                    and x.received_at <  least(public._day_start(v_tz, ws::date + 7), t1)
                  group by ws) q),
    'rooms', (select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'beds', rb.n,
                 'occupancy', case when rb.n * v_days = 0 then 0 else round(rn.nights::numeric / (rb.n * v_days), 4) end,
                 'revenue', coalesce(rv.amt, 0)) order by r.sort, r.name), '[]'::jsonb)
               from public.rooms r
               cross join lateral (select count(*) n from public.beds where room_id = r.id and is_active) rb
               cross join lateral (select count(*) nights
                                     from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
                                     join public.bookings b on b.stay @> public._night(v_tz, d::date)
                                     join public.beds bd on bd.id = b.bed_id
                                    where bd.room_id = r.id and b.property_id = p_property
                                      and b.status in ('pending','confirmed','checked_in','checked_out')) rn
               cross join lateral (select sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end) amt
                                     from public.payments x join public.bookings b on b.id = x.booking_id
                                     join public.beds bd on bd.id = b.bed_id
                                    where bd.room_id = r.id and x.property_id = p_property
                                      and x.received_at >= t0 and x.received_at < t1) rv
              where r.property_id = p_property),
    'sources', (select coalesce(jsonb_object_agg(source, n), '{}'::jsonb) from (
                  select source, count(*) n from public.bookings where property_id = p_property
                     and check_in_at >= t0 and check_in_at < t1 and status not in ('cancelled') group by source) s),
    'nationalities', (select coalesce(jsonb_agg(jsonb_build_object('name', nat, 'n', n) order by n desc), '[]'::jsonb) from (
                  select coalesce(nullif(g.nationality, ''), 'Unknown') nat, count(*) n
                    from public.bookings b join public.guests g on g.id = b.guest_id
                   where b.property_id = p_property and b.check_in_at >= t0 and b.check_in_at < t1
                     and b.status not in ('cancelled')
                   group by 1 order by 2 desc limit 6) q));
end $$;

-- ---------- Team ----------
create or replace function public.list_members(p_property uuid)
returns table (user_id uuid, display_name text, email text, role public.member_role, last_seen_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return query select m.user_id, m.display_name, m.email, m.role, m.last_seen_at
                 from public.property_members m where m.property_id = p_property
                order by m.role, m.display_name;
end $$;

-- Add someone who already has a login (invite them first: Supabase → Authentication → Users → Invite).
create or replace function public.add_member(p_property uuid, p_email text, p_role text, p_name text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select id into v_user from auth.users where lower(email) = lower(btrim(p_email));
  if v_user is null then
    raise exception 'No login exists for %. Invite them from Supabase → Authentication → Users first.', p_email;
  end if;
  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (p_property, v_user, p_role::public.member_role, nullif(btrim(p_name), ''), lower(btrim(p_email)))
  on conflict (property_id, user_id)
  do update set role = excluded.role, display_name = coalesce(excluded.display_name, property_members.display_name);
end $$;

create or replace function public.remove_member(p_property uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if (select role from public.property_members where property_id = p_property and user_id = p_user) = 'owner'
     and (select count(*) from public.property_members where property_id = p_property and role = 'owner') <= 1 then
    raise exception 'A property needs at least one owner.';
  end if;
  delete from public.property_members where property_id = p_property and user_id = p_user;
end $$;

-- ---------- Notifications ----------
create or replace function public.mark_notifications_read(p_property uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.notifications set read_at = now()
   where property_id = p_property and read_at is null
     and (user_id is null or user_id = auth.uid())
     and property_id in (select public.my_property_ids())
$$;

-- =====================================================================
-- Guest self check-in (no login; the link contains an unguessable token)
-- =====================================================================
create or replace function public.selfcheckin_get(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  select jsonb_build_object(
           'property_id', p.id, 'property', p.name, 'code', b.code, 'status', b.status,
           'room', r.name, 'bed', bd.label, 'nights', b.nights,
           'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at,
           'full_name', g.full_name, 'submitted', b.self_checkin_at is not null)
    into v
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    join public.beds bd on bd.id = b.bed_id
    join public.rooms r on r.id = bd.room_id
    join public.properties p on p.id = b.property_id
   where b.self_checkin_token = p_token
     and b.status in ('pending','confirmed','checked_in')
     and b.check_out_at > now();
  if v is null then raise exception 'This check-in link is invalid or has expired. Please ask the front desk.'; end if;
  return v;
end $$;

create or replace function public.selfcheckin_submit(p_token uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b   public.bookings%rowtype;
  v_dob date := nullif(p->>'dob', '')::date;
  v_doc text := nullif(p->>'id_doc_path', '');
begin
  select * into v_b from public.bookings
   where self_checkin_token = p_token and status in ('pending','confirmed','checked_in') and check_out_at > now()
   for update;
  if not found then raise exception 'This check-in link is invalid or has expired. Please ask the front desk.'; end if;
  if v_b.self_checkin_count >= 5 then raise exception 'Too many attempts. Please finish check-in at the front desk.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then
    raise exception 'Please confirm your details and accept the house rules.';
  end if;
  if coalesce(btrim(p->>'full_name'), '') = '' then raise exception 'Full name is required.'; end if;
  if v_dob is null then raise exception 'Date of birth is required.'; end if;
  perform public._check_dob(v_dob);
  if v_dob > current_date - interval '18 years' then
    raise exception 'Guests must be 18 or older to check in.';
  end if;
  if coalesce(p->>'id_type', '') = '' then raise exception 'Choose a proof of identity.'; end if;
  if v_doc is not null and v_doc not like v_b.property_id::text || '/' || p_token::text || '/%' then
    raise exception 'ID upload is invalid. Please try again.';
  end if;

  update public.guests
     set full_name   = btrim(p->>'full_name'),
         dob         = v_dob,
         phone       = coalesce(public._clean_phone(p->>'phone'), phone),
         email       = coalesce(nullif(lower(btrim(p->>'email')), ''), email),
         nationality = coalesce(nullif(btrim(p->>'nationality'), ''), nationality),
         id_type     = (p->>'id_type')::public.id_doc_type,
         id_number   = coalesce(public._mask_id(p->>'id_type', p->>'id_number'), id_number),
         id_doc_path = coalesce(v_doc, id_doc_path),
         consent_at  = now()
   where id = v_b.guest_id;

  update public.bookings
     set self_checkin_at = now(), self_checkin_count = self_checkin_count + 1
   where id = v_b.id;

  return jsonb_build_object('ok', true, 'code', v_b.code);
end $$;

-- =====================================================================
-- Retention: ID photos are deleted N days after the guest's last stay.
-- Called only by the purge-id-docs Edge Function (service role).
-- =====================================================================
create or replace function public.id_docs_due_for_purge(p_limit int default 200)
returns table (guest_id uuid, path text)
language sql stable security definer set search_path = public, pg_temp as $$
  select g.id, g.id_doc_path
    from public.guests g join public.properties p on p.id = g.property_id
   where g.id_doc_path is not null
     and not exists (select 1 from public.bookings b where b.guest_id = g.id
                      and b.check_out_at > now() - make_interval(days => p.id_doc_retention_days))
   limit p_limit
$$;

create or replace function public.mark_id_doc_purged(p_guest uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.guests set id_doc_path = null where id = p_guest
$$;

-- =====================================================================
-- Execute permissions: nothing by default, then exactly what each role needs
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.my_property_ids(public.member_role[]),
  public.my_memberships(),
  public.touch_presence(uuid),
  public.create_booking(jsonb),
  public.update_booking(uuid, jsonb),
  public.booking_action(uuid, text, boolean),
  public.record_payment(uuid, int, text, text, text, text),
  public.list_bookings(uuid, text, text, timestamptz, uuid, int),
  public.booking_status_counts(uuid),
  public.occupancy_series(uuid, date, date),
  public.booking_detail(uuid),
  public.dashboard_summary(uuid),
  public.bed_board(uuid),
  public.calendar_range(uuid, date, int),
  public.available_beds(uuid, timestamptz, timestamptz),
  public.set_bed_block(uuid, timestamptz, timestamptz, text),
  public.list_payments(uuid, text, date, date, timestamptz, uuid, int),
  public.payment_summary(uuid, date, date),
  public.guest_profile(uuid),
  public.search_guests(uuid, text),
  public.report_summary(uuid, date, date),
  public.list_members(uuid),
  public.add_member(uuid, text, text, text),
  public.remove_member(uuid, uuid),
  public.mark_notifications_read(uuid)
to authenticated;

-- Guests (not signed in) can only use these three
grant execute on function
  public.selfcheckin_get(uuid),
  public.selfcheckin_submit(uuid, jsonb),
  public.checkin_upload_allowed(text)
to anon, authenticated;

grant execute on function public.id_docs_due_for_purge(int), public.mark_id_doc_purged(uuid) to service_role;


-- >>>>>>>>>>>>>>>>>>>> 006_marketing.sql
-- =====================================================================
-- NammaStay · 006_marketing.sql
-- Backend for the marketing homepage (index.html):
--   • "Get early access" form → leads table
--   • spam protection: hidden honeypot field, duplicate check, rate limit
--   • you (platform admin) manage leads in the app at /leads.html
--   • email alert per lead via the notify-lead Edge Function
--
-- Run AFTER 001–003. Then make yourself a platform admin (bottom of file).
-- =====================================================================

-- ---------- Who runs NammaStay (you) — separate from hostel staff roles ----------
create table public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

-- ---------- Leads ----------
create type public.lead_status as enum ('new','contacted','demo_booked','won','lost');

create table public.leads (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(btrim(name)) between 2 and 80),
  phone         text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  email         text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  property_name text check (char_length(property_name) <= 120),
  city          text check (char_length(city) <= 80),
  property_type text check (property_type is null or property_type in ('hostel','homestay','hotel','other')),
  beds          int  check (beds is null or beds between 1 and 5000),
  message       text check (char_length(message) <= 1000),
  source        text check (char_length(source) <= 300),     -- utm / referrer
  status        public.lead_status not null default 'new',
  notes         text check (char_length(notes) <= 2000),     -- your private follow-up notes
  contacted_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (phone is not null or email is not null)
);
create index leads_recent on public.leads (created_at desc, id desc);
create index leads_status on public.leads (status, created_at desc);
create index leads_email  on public.leads (lower(email));
create index leads_phone  on public.leads (phone);
create trigger leads_touch before update on public.leads for each row execute function public._touch_updated_at();

alter table public.platform_admins enable row level security;
alter table public.leads enable row level security;
create policy leads_admin_select on public.leads for select to authenticated using (public.is_platform_admin());
create policy admins_self_select on public.platform_admins for select to authenticated using (user_id = (select auth.uid()));

revoke all on public.leads, public.platform_admins from anon, authenticated;
grant select on public.leads, public.platform_admins to authenticated;   -- RLS limits it to admins

-- ---------- Public form submit (no login) ----------
create or replace function public.submit_lead(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_phone text := public._clean_phone(p->>'phone');
  v_email text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_type  text := nullif(p->>'property_type', '');
  v_beds  int;
begin
  -- Bots fill the hidden "website" field; humans never see it. Pretend success.
  if coalesce(p->>'website', '') <> '' then return jsonb_build_object('ok', true); end if;

  if char_length(v_name) < 2 then raise exception 'Please enter your name.'; end if;
  if v_phone is null and v_email is null then raise exception 'Please enter a phone number or email so we can reach you.'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please check the phone number.'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please check the email address.'; end if;
  if v_type is not null and v_type not in ('hostel','homestay','hotel','other') then v_type := 'other'; end if;
  begin v_beds := nullif(p->>'beds', '')::int; exception when others then v_beds := null; end;
  if v_beds is not null and (v_beds < 1 or v_beds > 5000) then v_beds := null; end if;

  -- Same person again within 10 minutes: accept quietly, don't duplicate
  if exists (select 1 from public.leads
              where created_at > now() - interval '10 minutes'
                and ((v_phone is not null and phone = v_phone) or (v_email is not null and lower(email) = v_email))) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  -- Flood guard for the whole form
  if (select count(*) from public.leads where created_at > now() - interval '1 minute') >= 20 then
    raise exception 'We''re getting a lot of requests right now. Please try again in a minute.';
  end if;

  insert into public.leads (name, phone, email, property_name, city, property_type, beds, message, source)
  values (left(v_name, 80), v_phone, v_email,
          left(nullif(btrim(p->>'property_name'), ''), 120), left(nullif(btrim(p->>'city'), ''), 80),
          v_type, v_beds, left(nullif(btrim(p->>'message'), ''), 1000), left(nullif(btrim(p->>'source'), ''), 300));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Admin: manage leads (used by /leads.html) ----------
create or replace function public.list_leads(
  p_status text default null, p_q text default null,
  p_cursor_at timestamptz default null, p_cursor_id uuid default null, p_limit int default 50)
returns setof public.leads
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := nullif(btrim(p_q), ''); v_d text;
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  v_d := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  return query
  select * from public.leads l
   where (p_status is null or l.status = p_status::public.lead_status)
     and (v_q is null or l.name ilike '%' || v_q || '%' or l.email ilike '%' || v_q || '%'
          or l.property_name ilike '%' || v_q || '%' or l.city ilike '%' || v_q || '%'
          or (length(v_d) >= 4 and l.phone like '%' || v_d || '%'))
     and (p_cursor_at is null or (l.created_at, l.id) < (p_cursor_at, p_cursor_id))
   order by l.created_at desc, l.id desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;

create or replace function public.lead_counts() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status, count(*) n from public.leads group by status) s;
  return v || jsonb_build_object('all', (select count(*) from public.leads),
                                 'last_7_days', (select count(*) from public.leads where created_at > now() - interval '7 days'));
end $$;

create or replace function public.update_lead(p_id uuid, p_status text default null, p_notes text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  update public.leads
     set status = coalesce(p_status::public.lead_status, status),
         notes  = coalesce(p_notes, notes),
         contacted_at = case when p_status is not null and p_status <> 'new' and contacted_at is null then now() else contacted_at end
   where id = p_id;
  if not found then raise exception 'Lead not found.'; end if;
end $$;

-- ---------- Execute permissions ----------
revoke execute on function public.is_platform_admin(), public.submit_lead(jsonb),
  public.list_leads(text, text, timestamptz, uuid, int), public.lead_counts(), public.update_lead(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.submit_lead(jsonb) to anon, authenticated;
grant execute on function public.is_platform_admin(), public.list_leads(text, text, timestamptz, uuid, int),
  public.lead_counts(), public.update_lead(uuid, text, text) to authenticated;

-- ---------- Make yourself the platform admin ----------
-- Replace the email with your own login (the same one used in 004_seed.sql), then run:
-- insert into public.platform_admins (user_id)
--   select id from auth.users where lower(email) = lower('owner@example.com')
-- on conflict do nothing;


-- >>>>>>>>>>>>>>>>>>>> 007_subscriptions.sql
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


-- >>>>>>>>>>>>>>>>>>>> 008_delete_booking.sql
-- =====================================================================
-- NammaStay · 008_delete_booking.sql
-- Delete a booking that was entered by mistake — any status, including a
-- guest who is checked in right now. Only that stay is removed; the guest's
-- profile and their other bookings are untouched, and the bed becomes free.
--
--   • Owner / manager: can delete any booking (its payments are deleted too).
--   • Front desk: only bookings created in the last 24 hours with no payments.
--   • A full copy (booking, guest name, payments, reason, who, when) is kept
--     in the activity log, so a deletion can always be traced.
--
-- Run AFTER 001–003 (and 006/007 if you use them).
-- (If you ran the earlier 008_delete_guest.sql, that's harmless — leave it.)
-- =====================================================================

-- Payments stay append-only, EXCEPT when delete_booking removes a wrong booking.
create or replace function public._payments_immutable() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' and current_setting('nammastay.deleting_booking', true) = 'on' then
    return old;
  end if;
  raise exception 'Payments can''t be edited or deleted. Record a refund instead.';
end $$;

create or replace function public.delete_booking(p_booking uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b        public.bookings%rowtype;
  v_role   public.member_role;
  v_pay    jsonb;
  v_guest  text;
  v_count  int;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  v_role := public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Please choose a reason for deleting.'; end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.received_at), '[]'::jsonb), count(*)
    into v_pay, v_count
    from public.payments p where p.booking_id = b.id;

  if v_role = 'front_desk' and (v_count > 0 or b.created_at < now() - interval '24 hours') then
    raise exception 'Front desk can only delete bookings made in the last 24 hours with no payments. Please ask the owner or manager.';
  end if;

  select full_name into v_guest from public.guests where id = b.guest_id;

  -- keep a full copy for the record
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'deleted',
          jsonb_build_object('reason', left(btrim(p_reason), 200), 'code', b.code, 'guest', v_guest,
                             'booking', to_jsonb(b), 'payments', v_pay), auth.uid());

  perform set_config('nammastay.deleting_booking', 'on', true);
  delete from public.payments where booking_id = b.id;
  delete from public.bookings where id = b.id;
  perform set_config('nammastay.deleting_booking', 'off', true);

  delete from public.notifications where booking_id = b.id;

  return jsonb_build_object('ok', true, 'code', b.code, 'guest', v_guest, 'payments_removed', v_count,
                            'amount_removed_paise', b.paid_paise);
end $$;

-- Deleted bookings, for the owner's records (Settings → Deleted bookings)
create or replace function public.list_deleted_bookings(p_property uuid, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'at', a.at, 'code', a.details->>'code', 'guest', a.details->>'guest', 'reason', a.details->>'reason',
            'check_in_at', a.details#>>'{booking,check_in_at}', 'check_out_at', a.details#>>'{booking,check_out_at}',
            'total_paise', (a.details#>>'{booking,total_paise}')::int, 'paid_paise', (a.details#>>'{booking,paid_paise}')::int,
            'by', (select coalesce(m.display_name, m.email) from public.property_members m
                    where m.property_id = a.property_id and m.user_id = a.actor)) order by a.at desc), '[]'::jsonb)
    from (select * from public.audit_log where property_id = p_property and entity = 'booking' and action = 'deleted'
          order by at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) a);
end $$;

revoke execute on function public.delete_booking(uuid, text), public.list_deleted_bookings(uuid, int) from public, anon, authenticated;
grant execute on function public.delete_booking(uuid, text), public.list_deleted_bookings(uuid, int) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 009_edit_guest.sql
-- =====================================================================
-- NammaStay · 009_edit_guest.sql
-- Edit a guest's profile (owner / manager / front desk):
-- name, phone, email, date of birth, nationality, ID type & number,
-- ID photo and notes. Same cleaning rules as a new booking:
-- phone gets +91 if 10 digits, Aadhaar is stored masked (last 4 only).
-- Run AFTER 001–003.
-- =====================================================================

create or replace function public.update_guest(p_guest uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  g        public.guests%rowtype;
  v_phone  text;
  v_email  text;
  v_dob    date;
  v_type   public.id_doc_type;
  v_old_doc text;
  v_changed text[] := '{}';
begin
  select * into g from public.guests where id = p_guest for update;
  if not found then raise exception 'Guest not found.'; end if;
  perform public._assert_role(g.property_id, array['owner','manager','front_desk']::public.member_role[]);

  if p ? 'full_name' and coalesce(char_length(btrim(p->>'full_name')), 0) < 2 then
    raise exception 'Please enter the guest’s full name.';
  end if;
  v_phone := case when p ? 'phone' then public._clean_phone(p->>'phone') else g.phone end;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please check the phone number.'; end if;
  v_email := case when p ? 'email' then nullif(lower(btrim(p->>'email')), '') else g.email end;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please check the email address.'; end if;
  v_dob := case when p ? 'dob' then nullif(p->>'dob', '')::date else g.dob end;
  perform public._check_dob(v_dob);
  v_type := case when p ? 'id_type' then nullif(p->>'id_type', '')::public.id_doc_type else g.id_type end;
  v_old_doc := g.id_doc_path;

  if p ? 'id_doc_path' and nullif(p->>'id_doc_path', '') is not null
     and p->>'id_doc_path' not like g.property_id::text || '/%' then
    raise exception 'ID photo upload is invalid. Please try again.';
  end if;

  update public.guests set
    full_name   = case when p ? 'full_name' then left(btrim(p->>'full_name'), 120) else full_name end,
    phone       = v_phone,
    email       = v_email,
    dob         = v_dob,
    nationality = case when p ? 'nationality' then nullif(left(btrim(p->>'nationality'), 60), '') else nationality end,
    id_type     = v_type,
    id_number   = case when p ? 'id_number' then public._mask_id(v_type::text, p->>'id_number') else id_number end,
    id_doc_path = case when p ? 'id_doc_path' and nullif(p->>'id_doc_path', '') is not null then p->>'id_doc_path' else id_doc_path end,
    notes       = case when p ? 'notes' then nullif(left(btrim(p->>'notes'), 2000), '') else notes end
  where id = p_guest
  returning * into g;

  -- record which fields changed (not the values — they're personal data)
  select array_agg(k) into v_changed from jsonb_object_keys(p) k
   where k in ('full_name','phone','email','dob','nationality','id_type','id_number','id_doc_path','notes');
  insert into public.audit_log (property_id, entity, entity_id, action, details, actor)
  values (g.property_id, 'guest', g.id, 'edited', jsonb_build_object('fields', coalesce(to_jsonb(v_changed), '[]'::jsonb)), auth.uid());

  return jsonb_build_object('id', g.id,
    'old_id_doc_path', case when g.id_doc_path is distinct from v_old_doc then v_old_doc end);
end $$;

-- Staff may delete an old ID photo of their own property when replacing it
drop policy if exists "guest-ids: owner delete" on storage.objects;
drop policy if exists "guest-ids: staff delete" on storage.objects;
create policy "guest-ids: staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'guest-ids' and exists (
    select 1 from public.my_property_ids(array['owner','manager','front_desk']::public.member_role[]) pid
     where pid::text = (storage.foldername(name))[1]));

revoke execute on function public.update_guest(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.update_guest(uuid, jsonb) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 010_id_front_back.sql
-- =====================================================================
-- NammaStay · 010_id_front_back.sql
-- ID photos: front AND back side for each guest.
--   • guests.id_doc_back_path (new column)
--   • create_booking, selfcheckin_submit, booking_detail, update_guest
--     now accept / return the back image too (otherwise unchanged)
--   • automatic ID-photo cleanup deletes both sides
-- Run AFTER 001–003 and 009.
-- =====================================================================

alter table public.guests add column if not exists id_doc_back_path text;

-- Guests uploading on their online check-in link may now add front + back
-- (+ one retry), so allow up to 4 files per booking link.
create or replace function public.checkin_upload_allowed(p_name text)
returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  parts text[] := string_to_array(p_name, '/');
  v_ok boolean;
  v_count int;
begin
  if array_length(parts, 1) <> 3
     or parts[1] !~ '^[0-9a-f-]{36}$' or parts[2] !~ '^[0-9a-f-]{36}$' then
    return false;
  end if;
  select true into v_ok from public.bookings
   where property_id = parts[1]::uuid
     and self_checkin_token = parts[2]::uuid
     and status in ('pending','confirmed','checked_in')
     and check_out_at > now();
  if v_ok is not true then return false; end if;
  select count(*) into v_count from storage.objects
   where bucket_id = 'guest-ids' and name like parts[1] || '/' || parts[2] || '/%';
  return v_count < 4;
end $$;

create or replace function public.create_booking(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prop   uuid := (p->>'property_id')::uuid;
  v_in     timestamptz := (p->>'check_in_at')::timestamptz;
  v_out    timestamptz := (p->>'check_out_at')::timestamptz;
  v_status public.booking_status := coalesce(nullif(p->>'status', ''), 'pending')::public.booking_status;
  v_guest  uuid := nullif(p->>'guest_id', '')::uuid;
  v_bed    public.beds%rowtype;
  v_nights int;
  v_b      public.bookings%rowtype;
  v_pay    jsonb := p->'payment';
  v_dob    date := nullif(p#>>'{guest,dob}', '')::date;
begin
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);

  if v_in is null or v_out is null then raise exception 'Check-in and check-out are required.'; end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;
  if v_in < now() - interval '2 days' then raise exception 'Check-in can''t be more than 2 days in the past.'; end if;
  if v_in > now() + interval '2 years' then raise exception 'Check-in is too far in the future.'; end if;
  if v_status not in ('pending','confirmed','checked_in') then raise exception 'A new booking must be pending, confirmed or checked in.'; end if;
  if v_status = 'checked_in' and public._local_date(v_prop, v_in) > public._local_date(v_prop, now()) then
    raise exception 'You can only check in a guest whose stay starts today.';
  end if;

  select * into v_bed from public.beds where id = (p->>'bed_id')::uuid and property_id = v_prop;
  if not found then raise exception 'Please choose a bed.'; end if;
  if not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  if v_guest is null then
    if coalesce(btrim(p#>>'{guest,full_name}'), '') = '' then raise exception 'Guest name is required.'; end if;
    if coalesce(p#>>'{guest,id_doc_path}', '') not in ('') and p#>>'{guest,id_doc_path}' not like v_prop::text || '/%'
       or coalesce(p#>>'{guest,id_doc_back_path}', '') not in ('') and p#>>'{guest,id_doc_back_path}' not like v_prop::text || '/%' then
      raise exception 'ID photo upload is invalid. Please try again.';
    end if;
    perform public._check_dob(v_dob);
    insert into public.guests (property_id, full_name, phone, email, dob, nationality, id_type, id_number, id_doc_path, id_doc_back_path, consent_at)
    values (v_prop,
            btrim(p#>>'{guest,full_name}'),
            public._clean_phone(p#>>'{guest,phone}'),
            nullif(lower(btrim(p#>>'{guest,email}')), ''),
            v_dob,
            nullif(btrim(p#>>'{guest,nationality}'), ''),
            nullif(p#>>'{guest,id_type}', '')::public.id_doc_type,
            public._mask_id(nullif(p#>>'{guest,id_type}', ''), p#>>'{guest,id_number}'),
            nullif(p#>>'{guest,id_doc_path}', ''),
            nullif(p#>>'{guest,id_doc_back_path}', ''),
            now())
    returning id into v_guest;
  elsif not exists (select 1 from public.guests where id = v_guest and property_id = v_prop) then
    raise exception 'Guest not found.';
  end if;

  v_nights := greatest(1, public._local_date(v_prop, v_out) - public._local_date(v_prop, v_in));

  begin
    insert into public.bookings (property_id, guest_id, bed_id, visitors, check_in_at, check_out_at,
                                 nights, rate_paise, total_paise, status, source, note,
                                 send_confirmation, arrived_at)
    values (v_prop, v_guest, v_bed.id,
            coalesce(nullif(p->>'visitors', '')::smallint, 1),
            v_in, v_out, v_nights, v_bed.rate_paise, v_nights * v_bed.rate_paise,
            v_status,
            coalesce(nullif(p->>'source', ''), 'walk_in')::public.booking_source,
            nullif(btrim(p->>'note'), ''),
            coalesce((p->>'send_confirmation')::boolean, false),
            case when v_status = 'checked_in' then now() end)
    returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  if v_pay is not null and coalesce((v_pay->>'amount_paise')::int, 0) > 0 then
    perform public.record_payment(v_b.id, (v_pay->>'amount_paise')::int, v_pay->>'method',
                                  v_pay->>'reference', 'payment', null);
  end if;

  return jsonb_build_object('id', v_b.id, 'code', v_b.code, 'nights', v_nights,
                            'total_paise', v_b.total_paise,
                            'self_checkin_token', v_b.self_checkin_token);
end $$;

create or replace function public.selfcheckin_submit(p_token uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b   public.bookings%rowtype;
  v_dob date := nullif(p->>'dob', '')::date;
  v_doc text := nullif(p->>'id_doc_path', '');
  v_back text := nullif(p->>'id_doc_back_path', '');
begin
  select * into v_b from public.bookings
   where self_checkin_token = p_token and status in ('pending','confirmed','checked_in') and check_out_at > now()
   for update;
  if not found then raise exception 'This check-in link is invalid or has expired. Please ask the front desk.'; end if;
  if v_b.self_checkin_count >= 5 then raise exception 'Too many attempts. Please finish check-in at the front desk.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then
    raise exception 'Please confirm your details and accept the house rules.';
  end if;
  if coalesce(btrim(p->>'full_name'), '') = '' then raise exception 'Full name is required.'; end if;
  if v_dob is null then raise exception 'Date of birth is required.'; end if;
  perform public._check_dob(v_dob);
  if v_dob > current_date - interval '18 years' then
    raise exception 'Guests must be 18 or older to check in.';
  end if;
  if coalesce(p->>'id_type', '') = '' then raise exception 'Choose a proof of identity.'; end if;
  if (v_doc is not null and v_doc not like v_b.property_id::text || '/' || p_token::text || '/%')
     or (v_back is not null and v_back not like v_b.property_id::text || '/' || p_token::text || '/%') then
    raise exception 'ID upload is invalid. Please try again.';
  end if;

  update public.guests
     set full_name   = btrim(p->>'full_name'),
         dob         = v_dob,
         phone       = coalesce(public._clean_phone(p->>'phone'), phone),
         email       = coalesce(nullif(lower(btrim(p->>'email')), ''), email),
         nationality = coalesce(nullif(btrim(p->>'nationality'), ''), nationality),
         id_type     = (p->>'id_type')::public.id_doc_type,
         id_number   = coalesce(public._mask_id(p->>'id_type', p->>'id_number'), id_number),
         id_doc_path = coalesce(v_doc, id_doc_path),
         id_doc_back_path = coalesce(v_back, id_doc_back_path),
         consent_at  = now()
   where id = v_b.guest_id;

  update public.bookings
     set self_checkin_at = now(), self_checkin_count = self_checkin_count + 1
   where id = v_b.id;

  return jsonb_build_object('ok', true, 'code', v_b.code);
end $$;

create or replace function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_role public.member_role;
  v      jsonb;
begin
  select * into v_b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  v_role := public._assert_role(v_b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);

  select jsonb_build_object(
    'booking', to_jsonb(v_b) - 'self_checkin_token'
               || case when v_role <> 'accountant'
                       then jsonb_build_object('self_checkin_token', v_b.self_checkin_token) else '{}'::jsonb end,
    'guest', case when v_role = 'accountant'
                  then jsonb_build_object('id', g.id, 'full_name', g.full_name)
                  else jsonb_build_object('id', g.id, 'full_name', g.full_name, 'phone', g.phone,
                         'email', g.email, 'nationality', g.nationality, 'id_type', g.id_type,
                         'id_number', g.id_number, 'id_doc_path', g.id_doc_path,
                         'id_doc_back_path', g.id_doc_back_path, 'dob', g.dob) end,
    'bed',  jsonb_build_object('id', bd.id, 'label', bd.label, 'room', r.name),
    'property', jsonb_build_object('id', p.id, 'name', p.name, 'upi_id', p.upi_id, 'timezone', p.timezone),
    'created_by', (select coalesce(m.display_name, m.email) from public.property_members m
                    where m.property_id = v_b.property_id and m.user_id = v_b.created_by),
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
                    'code', x.code, 'kind', x.kind, 'method', x.method, 'amount_paise', x.amount_paise,
                    'reference', x.reference, 'received_at', x.received_at) order by x.received_at)
                  from public.payments x where x.booking_id = v_b.id), '[]'::jsonb),
    'activity', case when v_role = 'accountant' then '[]'::jsonb else
                coalesce((select jsonb_agg(jsonb_build_object(
                    'action', a.action, 'details', a.details, 'at', a.at,
                    'by', (select coalesce(m.display_name, m.email) from public.property_members m
                            where m.property_id = a.property_id and m.user_id = a.actor)) order by a.at)
                  from public.audit_log a where a.booking_id = v_b.id), '[]'::jsonb) end)
  into v
  from public.guests g, public.beds bd, public.rooms r, public.properties p
  where g.id = v_b.guest_id and bd.id = v_b.bed_id and r.id = bd.room_id and p.id = v_b.property_id;
  return v;
end $$;

create or replace function public.update_guest(p_guest uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  g        public.guests%rowtype;
  v_phone  text;
  v_email  text;
  v_dob    date;
  v_type   public.id_doc_type;
  v_old_doc text;
  v_old_back text;
  v_changed text[] := '{}';
begin
  select * into g from public.guests where id = p_guest for update;
  if not found then raise exception 'Guest not found.'; end if;
  perform public._assert_role(g.property_id, array['owner','manager','front_desk']::public.member_role[]);

  if p ? 'full_name' and coalesce(char_length(btrim(p->>'full_name')), 0) < 2 then
    raise exception 'Please enter the guest’s full name.';
  end if;
  v_phone := case when p ? 'phone' then public._clean_phone(p->>'phone') else g.phone end;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please check the phone number.'; end if;
  v_email := case when p ? 'email' then nullif(lower(btrim(p->>'email')), '') else g.email end;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please check the email address.'; end if;
  v_dob := case when p ? 'dob' then nullif(p->>'dob', '')::date else g.dob end;
  perform public._check_dob(v_dob);
  v_type := case when p ? 'id_type' then nullif(p->>'id_type', '')::public.id_doc_type else g.id_type end;
  v_old_doc := g.id_doc_path;
  v_old_back := g.id_doc_back_path;

  if (p ? 'id_doc_path' and nullif(p->>'id_doc_path', '') is not null and p->>'id_doc_path' not like g.property_id::text || '/%')
     or (p ? 'id_doc_back_path' and nullif(p->>'id_doc_back_path', '') is not null and p->>'id_doc_back_path' not like g.property_id::text || '/%') then
    raise exception 'ID photo upload is invalid. Please try again.';
  end if;

  update public.guests set
    full_name   = case when p ? 'full_name' then left(btrim(p->>'full_name'), 120) else full_name end,
    phone       = v_phone,
    email       = v_email,
    dob         = v_dob,
    nationality = case when p ? 'nationality' then nullif(left(btrim(p->>'nationality'), 60), '') else nationality end,
    id_type     = v_type,
    id_number   = case when p ? 'id_number' then public._mask_id(v_type::text, p->>'id_number') else id_number end,
    id_doc_path = case when p ? 'id_doc_path' and nullif(p->>'id_doc_path', '') is not null then p->>'id_doc_path' else id_doc_path end,
    id_doc_back_path = case when p ? 'id_doc_back_path' and nullif(p->>'id_doc_back_path', '') is not null then p->>'id_doc_back_path' else id_doc_back_path end,
    notes       = case when p ? 'notes' then nullif(left(btrim(p->>'notes'), 2000), '') else notes end
  where id = p_guest
  returning * into g;

  -- record which fields changed (not the values — they're personal data)
  select array_agg(k) into v_changed from jsonb_object_keys(p) k
   where k in ('full_name','phone','email','dob','nationality','id_type','id_number','id_doc_path','id_doc_back_path','notes');
  insert into public.audit_log (property_id, entity, entity_id, action, details, actor)
  values (g.property_id, 'guest', g.id, 'edited', jsonb_build_object('fields', coalesce(to_jsonb(v_changed), '[]'::jsonb)), auth.uid());

  return jsonb_build_object('id', g.id,
    'old_id_doc_path', case when g.id_doc_path is distinct from v_old_doc then v_old_doc end,
    'old_id_doc_back_path', case when g.id_doc_back_path is distinct from v_old_back then v_old_back end);
end $$;

create or replace function public.id_docs_due_for_purge(p_limit int default 200)
returns table (guest_id uuid, path text)
language sql stable security definer set search_path = public, pg_temp as $$
  select x.id, x.path from (
    select g.id, unnest(array_remove(array[g.id_doc_path, g.id_doc_back_path], null)) as path, g.property_id
      from public.guests g
     where (g.id_doc_path is not null or g.id_doc_back_path is not null)) x
  join public.properties p on p.id = x.property_id
  where not exists (select 1 from public.bookings b where b.guest_id = x.id
                     and b.check_out_at > now() - make_interval(days => p.id_doc_retention_days))
  limit p_limit
$$;

create or replace function public.mark_id_doc_purged(p_guest uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.guests set id_doc_path = null, id_doc_back_path = null where id = p_guest
$$;


-- >>>>>>>>>>>>>>>>>>>> 011_admin_panel.sql
-- =====================================================================
-- NammaStay · 011_admin_panel.sql
-- Admin panel for you (platform admin) to run NammaStay for other properties:
--   • overview: counts by status, est. monthly revenue, sign-ups per week,
--     bookings across all properties, "needs attention" lists
--   • one property in detail: owner, staff, usage, subscription history
--   • actions: extend, complimentary, SUSPEND / reactivate, private notes
-- Suspension is enforced in the database like expiry (no new bookings,
-- rooms, beds or staff). Run AFTER 007_subscriptions.sql.
-- =====================================================================

alter table public.subscriptions
  add column if not exists is_suspended boolean not null default false,
  add column if not exists suspended_reason text check (char_length(suspended_reason) <= 300),
  add column if not exists suspended_at timestamptz,
  add column if not exists admin_note text check (char_length(admin_note) <= 4000);

-- complimentary | trial | active | grace | expired | suspended
create or replace function public._access_state(p_property uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; v_end timestamptz; v_grace int;
begin
  select * into s from public.subscriptions where property_id = p_property;
  if not found then return 'expired'; end if;
  if s.is_suspended then return 'suspended'; end if;
  if s.is_complimentary then return 'complimentary'; end if;
  if s.paid_until is not null and s.paid_until > now() then return 'active'; end if;
  if s.trial_ends_at > now() and (s.paid_until is null or s.paid_until <= now()) then return 'trial'; end if;
  v_end := greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at));
  select grace_days into v_grace from public.platform_settings where id = 1;
  if now() < v_end + make_interval(days => v_grace) then return 'grace'; end if;
  return 'expired';
end $$;

create or replace function public._require_access() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public._access_state(new.property_id) = 'suspended' then
    raise exception 'This property''s NammaStay account is suspended. Please contact NammaStay support.'
      using errcode = 'P0402', hint = 'account_suspended';
  end if;
  if public._access_state(new.property_id) = 'expired' then
    raise exception 'This property''s NammaStay subscription has ended. The owner can renew in Settings → Billing.'
      using errcode = 'P0402', hint = 'subscription_expired';
  end if;
  return new;
end $$;

-- ---------- Overview ----------
create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform public._assert_platform_admin();
  with st as (
    select p.id, p.name, p.city, p.created_at, s.trial_ends_at, s.paid_until, s.plan_id, s.is_complimentary,
           public._access_state(p.id) as state,
           (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1) as owner_email,
           (select max(b.created_at) from public.bookings b where b.property_id = p.id) as last_booking_at,
           (select max(m.last_seen_at) from public.property_members m where m.property_id = p.id) as last_seen_at
      from public.properties p join public.subscriptions s on s.property_id = p.id)
  select jsonb_build_object(
    'total', (select count(*) from st),
    'counts', (select coalesce(jsonb_object_agg(state, n), '{}'::jsonb) from (select state, count(*) n from st group by state) c),
    'mrr_paise', (select coalesce(round(sum(pl.price_paise::numeric / pl.period_months)), 0)
                    from st join public.plans pl on pl.id = st.plan_id where st.state = 'active'),
    'signups_30d', (select count(*) from st where created_at > now() - interval '30 days'),
    'bookings_30d', (select count(*) from public.bookings where created_at > now() - interval '30 days'),
    'guest_payments_30d_paise', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                                   from public.payments where received_at > now() - interval '30 days'),
    'pending_payments', (select count(*) from public.subscription_payments where status = 'pending'),
    'weekly_signups', (select coalesce(jsonb_agg(jsonb_build_object('week', w::date,
                          'n', (select count(*) from st where created_at >= w and created_at < w + interval '7 days')) order by w), '[]'::jsonb)
                         from generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '1 week') w),
    'trial_ending', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'ends_at', trial_ends_at) order by trial_ends_at), '[]'::jsonb)
                       from st where state = 'trial' and trial_ends_at < now() + interval '3 days'),
    'payment_due', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'ended_at', greatest(trial_ends_at, coalesce(paid_until, trial_ends_at))) order by paid_until), '[]'::jsonb)
                      from st where state = 'grace'),
    'inactive', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'last_booking_at', last_booking_at, 'last_seen_at', last_seen_at) order by coalesce(last_seen_at, created_at)), '[]'::jsonb)
                   from st where state in ('trial','active') and created_at < now() - interval '7 days'
                     and coalesce(last_booking_at, created_at) < now() - interval '14 days'),
    'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'state', state, 'created_at', created_at, 'trial_ends_at', trial_ends_at, 'paid_until', paid_until, 'plan_id', plan_id,
                        'beds', (select count(*) from public.beds b where b.property_id = st.id and b.is_active),
                        'bookings_30d', (select count(*) from public.bookings b where b.property_id = st.id and b.created_at > now() - interval '30 days'),
                        'last_seen_at', last_seen_at) order by created_at desc), '[]'::jsonb) from st)
  ) into v;
  return v;
end $$;

-- ---------- One property in detail ----------
create or replace function public.admin_property(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  if not exists (select 1 from public.properties where id = p_property) then raise exception 'Property not found.'; end if;
  return (select jsonb_build_object(
    'property', jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'address', p.address, 'city', p.city,
                                   'phone', p.phone, 'email', p.email, 'upi_id', p.upi_id, 'created_at', p.created_at),
    'subscription', to_jsonb(s) || jsonb_build_object('state', public._access_state(p.id)),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('name', m.display_name, 'email', m.email, 'role', m.role,
                  'last_seen_at', m.last_seen_at) order by m.role, m.created_at), '[]'::jsonb)
                from public.property_members m where m.property_id = p.id),
    'usage', jsonb_build_object(
       'rooms', (select count(*) from public.rooms where property_id = p.id),
       'beds', (select count(*) from public.beds where property_id = p.id and is_active),
       'guests', (select count(*) from public.guests where property_id = p.id),
       'bookings_total', (select count(*) from public.bookings where property_id = p.id),
       'bookings_30d', (select count(*) from public.bookings where property_id = p.id and created_at > now() - interval '30 days'),
       'guest_payments_30d_paise', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                                     from public.payments where property_id = p.id and received_at > now() - interval '30 days'),
       'last_booking_at', (select max(created_at) from public.bookings where property_id = p.id),
       'last_seen_at', (select max(last_seen_at) from public.property_members where property_id = p.id)),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', sp.id, 'plan_id', sp.plan_id, 'amount_paise', sp.amount_paise, 'utr', sp.utr,
                  'status', sp.status, 'submitted_at', sp.submitted_at, 'review_note', sp.review_note,
                  'period_start', sp.period_start, 'period_end', sp.period_end) order by sp.submitted_at desc), '[]'::jsonb)
                 from public.subscription_payments sp where sp.property_id = p.id))
    from public.properties p join public.subscriptions s on s.property_id = p.id where p.id = p_property);
end $$;

-- ---------- Actions ----------
-- p: { extend_days?, complimentary?, suspend?, suspend_reason?, admin_note? }
create or replace function public.admin_set_property(p_property uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_days int := nullif(p->>'extend_days', '')::int;
begin
  perform public._assert_platform_admin();
  if v_days is not null and (v_days < -3650 or v_days > 3650) then raise exception 'Enter a sensible number of days.'; end if;
  if coalesce((p->>'suspend')::boolean, false) and coalesce(btrim(p->>'suspend_reason'), '') = '' then
    raise exception 'Add a short reason for suspending (the owner sees it).';
  end if;
  update public.subscriptions set
    paid_until = case when v_days is null or v_days = 0 then paid_until
                      else greatest(now(), coalesce(paid_until, now()), trial_ends_at) + make_interval(days => v_days) end,
    is_complimentary = coalesce((p->>'complimentary')::boolean, is_complimentary),
    is_suspended = coalesce((p->>'suspend')::boolean, is_suspended),
    suspended_reason = case when p ? 'suspend' then case when (p->>'suspend')::boolean then left(btrim(p->>'suspend_reason'), 300) end else suspended_reason end,
    suspended_at = case when p ? 'suspend' then case when (p->>'suspend')::boolean then coalesce(suspended_at, now()) end else suspended_at end,
    admin_note = case when p ? 'admin_note' then nullif(left(btrim(p->>'admin_note'), 4000), '') else admin_note end
  where property_id = p_property;
  if not found then raise exception 'Property not found.'; end if;
  if p ? 'suspend' then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'subscription',
            case when (p->>'suspend')::boolean then 'Account suspended' else 'Account reactivated' end,
            case when (p->>'suspend')::boolean then left(btrim(p->>'suspend_reason'), 300) else 'You can take new bookings again.' end);
  end if;
end $$;

-- Owners see why they're suspended (banner + Billing tab)
create or replace function public.property_suspension(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return (select jsonb_build_object('suspended', is_suspended, 'reason', suspended_reason, 'since', suspended_at)
            from public.subscriptions where property_id = p_property);
end $$;

revoke execute on function public.admin_overview(), public.admin_property(uuid), public.admin_set_property(uuid, jsonb),
  public.property_suspension(uuid) from public, anon, authenticated;
grant execute on function public.admin_overview(), public.admin_property(uuid), public.admin_set_property(uuid, jsonb),
  public.property_suspension(uuid) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 012_delete_guest.sql
-- =====================================================================
-- NammaStay · 012_delete_guest.sql
-- Delete a guest completely (owner / manager only): the guest profile,
-- ALL their bookings (any status) and the payments on those bookings.
-- A copy of every deleted booking is kept in the activity log
-- (Settings → Deleted bookings), marked "Guest deleted: <reason>".
-- Returns the ID photo paths so the app can delete the files too.
-- Run AFTER 008_delete_booking.sql and 010_id_front_back.sql.
-- =====================================================================

drop function if exists public.delete_guest(uuid);        -- earlier "erase details" version, replaced

create or replace function public.delete_guest(p_guest uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  g        public.guests%rowtype;
  b        public.bookings%rowtype;
  v_pay    jsonb;
  v_count  int := 0;
  v_paid   bigint := 0;
begin
  select * into g from public.guests where id = p_guest for update;
  if not found then raise exception 'Guest not found.'; end if;
  perform public._assert_role(g.property_id, array['owner','manager']::public.member_role[]);
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Please choose a reason for deleting.'; end if;

  perform set_config('nammastay.deleting_booking', 'on', true);
  for b in select * from public.bookings where guest_id = p_guest for update loop
    select coalesce(jsonb_agg(to_jsonb(p) order by p.received_at), '[]'::jsonb) into v_pay
      from public.payments p where p.booking_id = b.id;
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (b.property_id, 'booking', b.id, b.id, 'deleted',
            jsonb_build_object('reason', 'Guest deleted: ' || left(btrim(p_reason), 180), 'code', b.code, 'guest', g.full_name,
                               'booking', to_jsonb(b), 'payments', v_pay), auth.uid());
    delete from public.payments where booking_id = b.id;
    delete from public.notifications where booking_id = b.id;
    delete from public.bookings where id = b.id;
    v_count := v_count + 1;
    v_paid := v_paid + b.paid_paise;
  end loop;
  perform set_config('nammastay.deleting_booking', 'off', true);

  delete from public.guests where id = p_guest;

  insert into public.audit_log (property_id, entity, entity_id, action, details, actor)
  values (g.property_id, 'guest', g.id, 'deleted',
          jsonb_build_object('guest', g.full_name, 'reason', left(btrim(p_reason), 200),
                             'bookings_removed', v_count, 'paid_removed_paise', v_paid), auth.uid());

  return jsonb_build_object('ok', true, 'guest', g.full_name, 'bookings_removed', v_count, 'paid_removed_paise', v_paid,
                            'id_doc_paths', to_jsonb(array_remove(array[g.id_doc_path, g.id_doc_back_path], null)));
end $$;

revoke execute on function public.delete_guest(uuid, text) from public, anon, authenticated;
grant execute on function public.delete_guest(uuid, text) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 013_admin_add_property.sql
-- =====================================================================
-- NammaStay · 013_admin_add_property.sql
-- Let the platform admin add a property FOR a customer:
--   • creates the property (+ free trial or complimentary access)
--   • links the owner by email — right away if they already have a login,
--     otherwise when they sign up with that email (property_invites)
--   • optionally adds you as manager so you can set up rooms & beds
-- Run AFTER 007_subscriptions.sql and 011_admin_panel.sql.
-- =====================================================================

create table public.property_invites (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  email        text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role         public.member_role not null default 'owner',
  display_name text check (char_length(display_name) <= 80),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  claimed_by   uuid references auth.users(id) on delete set null,
  claimed_at   timestamptz,
  unique (property_id, email)
);
create index property_invites_email on public.property_invites (lower(email)) where claimed_at is null;
alter table public.property_invites enable row level security;       -- only reachable through the functions below
revoke all on public.property_invites from anon, authenticated;

create or replace function public.admin_create_property(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_email text := lower(btrim(coalesce(p->>'owner_email', '')));
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_owner uuid;
  v_prop  uuid;
  v_days  int := nullif(p->>'trial_days', '')::int;
begin
  perform public._assert_platform_admin();
  if char_length(v_name) < 2 then raise exception 'Enter the property name.'; end if;
  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the owner’s email address.'; end if;
  if v_days is not null and (v_days < 0 or v_days > 365) then raise exception 'Trial days must be between 0 and 365.'; end if;

  insert into public.properties (name, kind, city, address, phone, email)
  values (left(v_name, 120), coalesce(nullif(p->>'kind', ''), 'hostel'),
          left(nullif(btrim(p->>'city'), ''), 80), left(nullif(btrim(p->>'address'), ''), 300),
          left(nullif(btrim(p->>'phone'), ''), 20), v_email)
  returning id into v_prop;                                   -- trigger starts the standard free trial

  update public.subscriptions set
    trial_ends_at    = case when v_days is not null then now() + make_interval(days => v_days) else trial_ends_at end,
    is_complimentary = coalesce((p->>'complimentary')::boolean, false),
    admin_note       = nullif(left(btrim(coalesce(p->>'admin_note', '')), 4000), '')
  where property_id = v_prop;

  -- optional: you as manager, to set up rooms and beds for them
  if coalesce((p->>'add_me')::boolean, false) then
    insert into public.property_members (property_id, user_id, role, display_name, email)
    select v_prop, auth.uid(), 'manager', 'NammaStay support', u.email from auth.users u where u.id = auth.uid()
    on conflict do nothing;
  end if;

  -- owner: link now if they already have a login, otherwise when they sign up
  select id into v_owner from auth.users where lower(email) = v_email;
  insert into public.property_invites (property_id, email, role, display_name, claimed_by, claimed_at)
  values (v_prop, v_email, 'owner', nullif(left(btrim(coalesce(p->>'owner_name', '')), 80), ''),
          v_owner, case when v_owner is not null then now() end);
  if v_owner is not null then
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (v_prop, v_owner, 'owner', nullif(left(btrim(coalesce(p->>'owner_name', '')), 80), ''), v_email)
    on conflict (property_id, user_id) do update set role = 'owner';
  end if;

  return jsonb_build_object('property_id', v_prop, 'owner_linked', v_owner is not null,
    'trial_ends_at', (select trial_ends_at from public.subscriptions where property_id = v_prop));
end $$;

-- Called by the app after sign-in: link any properties waiting for this email
create or replace function public.claim_property_invites() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_email text; v_n int := 0; r record;
begin
  if v_uid is null then return 0; end if;
  select lower(email) into v_email from auth.users where id = v_uid;
  for r in select * from public.property_invites where lower(email) = v_email and claimed_at is null for update loop
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (r.property_id, v_uid, r.role, r.display_name, v_email)
    on conflict (property_id, user_id) do update set role = excluded.role;
    update public.property_invites set claimed_by = v_uid, claimed_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.admin_property_invites(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('email', email, 'role', role, 'name', display_name,
            'created_at', created_at, 'claimed_at', claimed_at) order by created_at), '[]'::jsonb)
            from public.property_invites where property_id = p_property);
end $$;

revoke execute on function public.admin_create_property(jsonb), public.claim_property_invites(), public.admin_property_invites(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_create_property(jsonb), public.claim_property_invites(), public.admin_property_invites(uuid)
  to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 014_hotels_homestays.sql
-- =====================================================================
-- NammaStay · 014_hotels_homestays.sql
-- Hotels & homestays sell ROOMS (not dorm beds). Each bookable unit
-- (row in "beds") now has:
--   • max_guests         how many people fit (dorm bed = 1)
--   • base_guests        guests included in the nightly rate
--   • extra_guest_paise  charge per extra ADULT per night above base_guests
-- Bookings record adults (visitors) + children and the extra charge.
-- Total = nights × (rate + extra). Children are free by default.
-- The property type (properties.kind) decides the words the app uses.
-- Run AFTER 010_id_front_back.sql.
-- =====================================================================

alter table public.beds
  add column if not exists max_guests  smallint not null default 1 check (max_guests between 1 and 20),
  add column if not exists base_guests smallint not null default 1 check (base_guests between 1 and 20),
  add column if not exists extra_guest_paise int not null default 0 check (extra_guest_paise between 0 and 10000000);

alter table public.bookings
  add column if not exists children    smallint not null default 0 check (children between 0 and 20),
  add column if not exists extra_paise int not null default 0 check (extra_paise >= 0);

create or replace function public.create_booking(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prop   uuid := (p->>'property_id')::uuid;
  v_in     timestamptz := (p->>'check_in_at')::timestamptz;
  v_out    timestamptz := (p->>'check_out_at')::timestamptz;
  v_status public.booking_status := coalesce(nullif(p->>'status', ''), 'pending')::public.booking_status;
  v_guest  uuid := nullif(p->>'guest_id', '')::uuid;
  v_bed    public.beds%rowtype;
  v_nights int;
  v_b      public.bookings%rowtype;
  v_pay    jsonb := p->'payment';
  v_dob    date := nullif(p#>>'{guest,dob}', '')::date;
  v_adults int;
  v_children int;
  v_extra  int;
begin
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);

  if v_in is null or v_out is null then raise exception 'Check-in and check-out are required.'; end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;
  if v_in < now() - interval '2 days' then raise exception 'Check-in can''t be more than 2 days in the past.'; end if;
  if v_in > now() + interval '2 years' then raise exception 'Check-in is too far in the future.'; end if;
  if v_status not in ('pending','confirmed','checked_in') then raise exception 'A new booking must be pending, confirmed or checked in.'; end if;
  if v_status = 'checked_in' and public._local_date(v_prop, v_in) > public._local_date(v_prop, now()) then
    raise exception 'You can only check in a guest whose stay starts today.';
  end if;

  select * into v_bed from public.beds where id = (p->>'bed_id')::uuid and property_id = v_prop;
  if not found then raise exception 'Please choose a bed.'; end if;
  if not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  if v_guest is null then
    if coalesce(btrim(p#>>'{guest,full_name}'), '') = '' then raise exception 'Guest name is required.'; end if;
    if coalesce(p#>>'{guest,id_doc_path}', '') not in ('') and p#>>'{guest,id_doc_path}' not like v_prop::text || '/%'
       or coalesce(p#>>'{guest,id_doc_back_path}', '') not in ('') and p#>>'{guest,id_doc_back_path}' not like v_prop::text || '/%' then
      raise exception 'ID photo upload is invalid. Please try again.';
    end if;
    perform public._check_dob(v_dob);
    insert into public.guests (property_id, full_name, phone, email, dob, nationality, id_type, id_number, id_doc_path, id_doc_back_path, consent_at)
    values (v_prop,
            btrim(p#>>'{guest,full_name}'),
            public._clean_phone(p#>>'{guest,phone}'),
            nullif(lower(btrim(p#>>'{guest,email}')), ''),
            v_dob,
            nullif(btrim(p#>>'{guest,nationality}'), ''),
            nullif(p#>>'{guest,id_type}', '')::public.id_doc_type,
            public._mask_id(nullif(p#>>'{guest,id_type}', ''), p#>>'{guest,id_number}'),
            nullif(p#>>'{guest,id_doc_path}', ''),
            nullif(p#>>'{guest,id_doc_back_path}', ''),
            now())
    returning id into v_guest;
  elsif not exists (select 1 from public.guests where id = v_guest and property_id = v_prop) then
    raise exception 'Guest not found.';
  end if;

  v_nights := greatest(1, public._local_date(v_prop, v_out) - public._local_date(v_prop, v_in));
  v_adults := greatest(1, coalesce(nullif(p->>'visitors', '')::int, 1));
  v_children := greatest(0, coalesce(nullif(p->>'children', '')::int, 0));
  if v_adults + v_children > v_bed.max_guests then
    raise exception '% fits up to % guest%.', v_bed.label, v_bed.max_guests, case when v_bed.max_guests = 1 then '' else 's' end;
  end if;
  v_extra := greatest(0, v_adults - v_bed.base_guests) * v_bed.extra_guest_paise;

  begin
    insert into public.bookings (property_id, guest_id, bed_id, visitors, children, extra_paise, check_in_at, check_out_at,
                                 nights, rate_paise, total_paise, status, source, note,
                                 send_confirmation, arrived_at)
    values (v_prop, v_guest, v_bed.id,
            v_adults, v_children, v_extra,
            v_in, v_out, v_nights, v_bed.rate_paise, v_nights * (v_bed.rate_paise + v_extra),
            v_status,
            coalesce(nullif(p->>'source', ''), 'walk_in')::public.booking_source,
            nullif(btrim(p->>'note'), ''),
            coalesce((p->>'send_confirmation')::boolean, false),
            case when v_status = 'checked_in' then now() end)
    returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  if v_pay is not null and coalesce((v_pay->>'amount_paise')::int, 0) > 0 then
    perform public.record_payment(v_b.id, (v_pay->>'amount_paise')::int, v_pay->>'method',
                                  v_pay->>'reference', 'payment', null);
  end if;

  return jsonb_build_object('id', v_b.id, 'code', v_b.code, 'nights', v_nights, 'guest_id', v_b.guest_id,
                            'total_paise', v_b.total_paise,
                            'self_checkin_token', v_b.self_checkin_token);
end $$;

create or replace function public.update_booking(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_bed  public.beds%rowtype;
  v_in   timestamptz;
  v_out  timestamptz;
  v_rate int;
  v_nights int;
  v_adults int;
  v_children int;
  v_extra int;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if v_b.status not in ('pending','confirmed','checked_in') then
    raise exception 'This booking is % and can''t be changed.', replace(v_b.status::text, '_', ' ');
  end if;

  v_in  := coalesce((p->>'check_in_at')::timestamptz,  v_b.check_in_at);
  v_out := coalesce((p->>'check_out_at')::timestamptz, v_b.check_out_at);
  if v_b.status = 'checked_in' and v_in <> v_b.check_in_at then
    raise exception 'Guest is already checked in; only the check-out can change.';
  end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;

  select * into v_bed from public.beds
   where id = coalesce(nullif(p->>'bed_id', '')::uuid, v_b.bed_id) and property_id = v_b.property_id;
  if not found then raise exception 'Bed not found.'; end if;
  if v_bed.id <> v_b.bed_id and not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  v_rate   := case when v_bed.id = v_b.bed_id then v_b.rate_paise else v_bed.rate_paise end;
  v_nights := greatest(1, public._local_date(v_b.property_id, v_out) - public._local_date(v_b.property_id, v_in));
  v_adults := greatest(1, coalesce(nullif(p->>'visitors', '')::int, v_b.visitors));
  v_children := greatest(0, coalesce(nullif(p->>'children', '')::int, v_b.children));
  -- check capacity only when guests or the room change (older bookings keep working)
  if (p ? 'visitors' or p ? 'children' or v_bed.id <> v_b.bed_id) and v_adults + v_children > v_bed.max_guests then
    raise exception '% fits up to % guest%.', v_bed.label, v_bed.max_guests, case when v_bed.max_guests = 1 then '' else 's' end;
  end if;
  v_extra := greatest(0, v_adults - v_bed.base_guests) * v_bed.extra_guest_paise;
  if v_nights * (v_rate + v_extra) < v_b.paid_paise then
    raise exception 'New total is less than what''s already paid. Record a refund first.';
  end if;

  begin
    update public.bookings
       set check_in_at = v_in, check_out_at = v_out, bed_id = v_bed.id,
           rate_paise = v_rate, nights = v_nights, total_paise = v_nights * (v_rate + v_extra),
           visitors = v_adults, children = v_children, extra_paise = v_extra,
           note = case when p ? 'note' then nullif(btrim(p->>'note'), '') else note end
     where id = p_booking
     returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  return jsonb_build_object('id', v_b.id, 'total_paise', v_b.total_paise, 'nights', v_b.nights);
end $$;

-- available rooms/beds now also tell the app their capacity and extra-guest charge
drop function if exists public.available_beds(uuid, timestamptz, timestamptz);
create function public.available_beds(p_property uuid, p_in timestamptz, p_out timestamptz)
returns table (id uuid, label text, room_id uuid, room_name text, rate_paise int,
               max_guests smallint, base_guests smallint, extra_guest_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query
  select bd.id, bd.label, r.id, r.name, bd.rate_paise, bd.max_guests, bd.base_guests, bd.extra_guest_paise
    from public.beds bd join public.rooms r on r.id = bd.room_id
   where bd.property_id = p_property and bd.is_active
     and not exists (select 1 from public.bookings b where b.bed_id = bd.id
                      and b.status in ('pending','confirmed','checked_in')
                      and b.stay && tstzrange(p_in, p_out, '[)'))
     and not exists (select 1 from public.bed_blocks k where k.bed_id = bd.id
                      and k.period && tstzrange(p_in, p_out, '[)'))
   order by r.sort, r.name, bd.sort, bd.label;
end $$;
revoke execute on function public.available_beds(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.available_beds(uuid, timestamptz, timestamptz) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 015_plans_by_type.sql
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


-- >>>>>>>>>>>>>>>>>>>> 016_extras.sql
-- =====================================================================
-- NammaStay · 016_extras.sql
-- Extra charges on a booking: food, laundry, rentals, transport, tours…
--   • extra_items       each property's price list (owner / manager edit)
--   • booking_charges   what was added to a guest's bill (qty × price)
--   • bookings.charges_paise = sum of the booking's charges; the booking
--     total (and so the balance due) = stay + extras
-- Charges are added / removed only through add_charge / remove_charge.
-- A charge can't be removed if that would make the total less than what
-- the guest has already paid (record a refund instead).
-- Run AFTER 014_hotels_homestays.sql.
-- =====================================================================

create table public.extra_items (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 80),
  category     text not null default 'other' check (category in ('food','laundry','rental','transport','tour','other')),
  price_paise  int  not null check (price_paise between 0 and 100000000),
  unit         text not null default 'each' check (char_length(unit) <= 30),
  is_active    boolean not null default true,
  sort         int not null default 0,
  created_at   timestamptz not null default now()
);
create index extra_items_prop on public.extra_items (property_id, is_active, sort);

alter table public.bookings add column if not exists charges_paise int not null default 0 check (charges_paise >= 0);

create table public.booking_charges (
  id                uuid primary key default gen_random_uuid(),
  property_id       uuid not null,
  booking_id        uuid not null,
  item_id           uuid references public.extra_items(id) on delete set null,
  name              text not null check (char_length(btrim(name)) between 1 and 80),
  category          text not null default 'other' check (category in ('food','laundry','rental','transport','tour','other')),
  qty               numeric(8,2) not null check (qty > 0 and qty <= 999),
  unit_price_paise  int not null check (unit_price_paise between 0 and 100000000),
  amount_paise      int not null check (amount_paise >= 0),
  note              text check (char_length(note) <= 200),
  charged_on        date not null default current_date,
  created_by        uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index booking_charges_booking on public.booking_charges (booking_id, created_at);
create index booking_charges_prop on public.booking_charges (property_id, charged_on);

-- ---------- security ----------
alter table public.extra_items enable row level security;
alter table public.booking_charges enable row level security;
create policy extras_select on public.extra_items for select to authenticated
  using (property_id in (select public.my_property_ids()));
create policy extras_write on public.extra_items for all to authenticated
  using      (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])))
  with check (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])));
create policy charges_select on public.booking_charges for select to authenticated
  using (property_id in (select public.my_property_ids()));
revoke all on public.extra_items, public.booking_charges from anon, authenticated;
grant select, insert, update, delete on public.extra_items to authenticated;
grant select on public.booking_charges to authenticated;          -- writes only through the functions below

-- ---------- add / remove ----------
-- p: { item_id?  |  name + unit_price_paise (+ category) ,  qty, note?, charged_on? }
create or replace function public.add_charge(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b      public.bookings%rowtype;
  it     public.extra_items%rowtype;
  v_qty  numeric := coalesce(nullif(p->>'qty', '')::numeric, 1);
  v_name text; v_cat text; v_price int; v_amt int; v_id uuid;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if b.status in ('cancelled','no_show') then raise exception 'This booking is cancelled — extras can’t be added.'; end if;
  if v_qty <= 0 or v_qty > 999 then raise exception 'Enter a quantity between 0.5 and 999.'; end if;

  if nullif(p->>'item_id', '') is not null then
    select * into it from public.extra_items where id = (p->>'item_id')::uuid and property_id = b.property_id;
    if not found then raise exception 'That item isn’t in your price list any more.'; end if;
    v_name := it.name; v_cat := it.category;
    v_price := coalesce(nullif(p->>'unit_price_paise', '')::int, it.price_paise);   -- staff may adjust the price
  else
    v_name := btrim(coalesce(p->>'name', ''));
    if char_length(v_name) < 1 then raise exception 'Enter what the extra is for.'; end if;
    v_cat := coalesce(nullif(p->>'category', ''), 'other');
    v_price := nullif(p->>'unit_price_paise', '')::int;
    if v_price is null or v_price < 0 then raise exception 'Enter the price.'; end if;
  end if;
  v_amt := round(v_qty * v_price);

  insert into public.booking_charges (property_id, booking_id, item_id, name, category, qty, unit_price_paise, amount_paise, note, charged_on)
  values (b.property_id, b.id, it.id, left(v_name, 80), v_cat, v_qty, v_price, v_amt,
          nullif(left(btrim(coalesce(p->>'note', '')), 200), ''),
          coalesce(nullif(p->>'charged_on', '')::date, public._local_date(b.property_id, now())))
  returning id into v_id;
  update public.bookings set charges_paise = charges_paise + v_amt, total_paise = total_paise + v_amt where id = b.id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'extra_added', jsonb_build_object('name', v_name, 'qty', v_qty, 'amount_paise', v_amt), auth.uid());
  return jsonb_build_object('id', v_id, 'amount_paise', v_amt);
end $$;

create or replace function public.remove_charge(p_charge uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.booking_charges%rowtype; b public.bookings%rowtype;
begin
  select * into c from public.booking_charges where id = p_charge;
  if not found then raise exception 'Extra not found.'; end if;
  select * into b from public.bookings where id = c.booking_id for update;
  perform public._assert_role(c.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if b.total_paise - c.amount_paise < b.paid_paise then
    raise exception 'The guest has already paid for this. Record a refund instead of removing it.';
  end if;
  delete from public.booking_charges where id = p_charge;
  update public.bookings set charges_paise = greatest(0, charges_paise - c.amount_paise), total_paise = total_paise - c.amount_paise where id = b.id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'extra_removed', jsonb_build_object('name', c.name, 'amount_paise', c.amount_paise), auth.uid());
end $$;

-- stay changes keep the extras in the total
create or replace function public.update_booking(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_bed  public.beds%rowtype;
  v_in   timestamptz;
  v_out  timestamptz;
  v_rate int;
  v_nights int;
  v_adults int;
  v_children int;
  v_extra int;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if v_b.status not in ('pending','confirmed','checked_in') then
    raise exception 'This booking is % and can''t be changed.', replace(v_b.status::text, '_', ' ');
  end if;

  v_in  := coalesce((p->>'check_in_at')::timestamptz,  v_b.check_in_at);
  v_out := coalesce((p->>'check_out_at')::timestamptz, v_b.check_out_at);
  if v_b.status = 'checked_in' and v_in <> v_b.check_in_at then
    raise exception 'Guest is already checked in; only the check-out can change.';
  end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;

  select * into v_bed from public.beds
   where id = coalesce(nullif(p->>'bed_id', '')::uuid, v_b.bed_id) and property_id = v_b.property_id;
  if not found then raise exception 'Bed not found.'; end if;
  if v_bed.id <> v_b.bed_id and not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  v_rate   := case when v_bed.id = v_b.bed_id then v_b.rate_paise else v_bed.rate_paise end;
  v_nights := greatest(1, public._local_date(v_b.property_id, v_out) - public._local_date(v_b.property_id, v_in));
  v_adults := greatest(1, coalesce(nullif(p->>'visitors', '')::int, v_b.visitors));
  v_children := greatest(0, coalesce(nullif(p->>'children', '')::int, v_b.children));
  -- check capacity only when guests or the room change (older bookings keep working)
  if (p ? 'visitors' or p ? 'children' or v_bed.id <> v_b.bed_id) and v_adults + v_children > v_bed.max_guests then
    raise exception '% fits up to % guest%.', v_bed.label, v_bed.max_guests, case when v_bed.max_guests = 1 then '' else 's' end;
  end if;
  v_extra := greatest(0, v_adults - v_bed.base_guests) * v_bed.extra_guest_paise;
  if v_nights * (v_rate + v_extra) + v_b.charges_paise < v_b.paid_paise then
    raise exception 'New total is less than what''s already paid. Record a refund first.';
  end if;

  begin
    update public.bookings
       set check_in_at = v_in, check_out_at = v_out, bed_id = v_bed.id,
           rate_paise = v_rate, nights = v_nights, total_paise = v_nights * (v_rate + v_extra) + charges_paise,
           visitors = v_adults, children = v_children, extra_paise = v_extra,
           note = case when p ? 'note' then nullif(btrim(p->>'note'), '') else note end
     where id = p_booking
     returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  return jsonb_build_object('id', v_b.id, 'total_paise', v_b.total_paise, 'nights', v_b.nights);
end $$;

revoke execute on function public.add_charge(uuid, jsonb), public.remove_charge(uuid) from public, anon, authenticated;
grant execute on function public.add_charge(uuid, jsonb), public.remove_charge(uuid) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 017_role_permissions.sql
-- =====================================================================
-- NammaStay · 017_role_permissions.sql
-- The owner decides what Manager, Front desk and Accountant may do
-- (Settings → Users & roles → What each role can do). Enforced here in the
-- database, so a switched-off feature can't be used from any device.
-- The owner can always do everything. Fixed safety limits from earlier
-- migrations still apply (e.g. only owner/manager can refund or delete a
-- whole guest; the accountant can't change bookings).
-- Run AFTER 016_extras.sql.
-- =====================================================================

alter table public.properties add column if not exists role_permissions jsonb not null default '{}'::jsonb
  check (jsonb_typeof(role_permissions) = 'object');

-- Defaults when the owner hasn't changed anything
create or replace function public._perm_default(p_role public.member_role, p_perm text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select case p_role
    when 'owner'      then true
    when 'manager'    then true
    when 'front_desk' then p_perm in ('view_payments','record_payments','cancel_bookings','delete_bookings','add_extras')
    when 'accountant' then p_perm in ('view_reports','view_payments','export_data')
    else false end
$$;

create or replace function public._allowed(p_property uuid, p_perm text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_role public.member_role; v_set jsonb;
begin
  if auth.uid() is null then return true; end if;                -- SQL editor, scheduled jobs
  select role into v_role from public.property_members where property_id = p_property and user_id = auth.uid();
  if v_role is null then return false; end if;
  if v_role = 'owner' then return true; end if;
  select role_permissions -> (v_role::text) -> p_perm into v_set from public.properties where id = p_property;
  if v_set is not null and jsonb_typeof(v_set) = 'boolean' then return v_set::text::boolean; end if;
  return public._perm_default(v_role, p_perm);
end $$;

create or replace function public._require_perm(p_property uuid, p_perm text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public._allowed(p_property, p_perm) then
    raise exception '%', case p_perm
      when 'view_reports'    then 'Your role can’t see reports. Ask the owner.'
      when 'view_payments'   then 'Your role can’t see payments. Ask the owner.'
      when 'record_payments' then 'Your role can’t take payments. Ask the owner.'
      when 'refunds'         then 'Your role can’t give refunds. Ask the owner.'
      when 'cancel_bookings' then 'Your role can’t cancel bookings. Ask the owner.'
      when 'delete_bookings' then 'Your role can’t delete bookings. Ask the owner.'
      when 'delete_guests'   then 'Your role can’t delete guests. Ask the owner.'
      when 'manage_rooms'    then 'Your role can’t change rooms, beds or prices. Ask the owner.'
      when 'add_extras'      then 'Your role can’t add or remove extras. Ask the owner.'
      else 'Your role can’t do this. Ask the owner.' end
      using errcode = '42501';
  end if;
end $$;

-- ---------- enforcement ----------
create or replace function public._perm_payments() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_perm(new.property_id, case new.kind when 'refund' then 'refunds' else 'record_payments' end);
  return new;
end $$;
drop trigger if exists perm_payments on public.payments;
create trigger perm_payments before insert on public.payments for each row execute function public._perm_payments();

create or replace function public._perm_bookings() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then perform public._require_perm(old.property_id, 'delete_bookings'); return old; end if;
  if new.status = 'cancelled' and old.status <> 'cancelled' then perform public._require_perm(new.property_id, 'cancel_bookings'); end if;
  return new;
end $$;
drop trigger if exists perm_bookings on public.bookings;
create trigger perm_bookings before update of status or delete on public.bookings for each row execute function public._perm_bookings();

create or replace function public._perm_guests() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public._require_perm(old.property_id, 'delete_guests'); return old; end $$;
drop trigger if exists perm_guests on public.guests;
create trigger perm_guests before delete on public.guests for each row execute function public._perm_guests();

create or replace function public._perm_rooms() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_perm(coalesce(new.property_id, old.property_id), 'manage_rooms');
  return coalesce(new, old);
end $$;
drop trigger if exists perm_rooms on public.rooms;
drop trigger if exists perm_beds on public.beds;
drop trigger if exists perm_extra_items on public.extra_items;
create trigger perm_rooms before insert or update or delete on public.rooms for each row execute function public._perm_rooms();
create trigger perm_beds before insert or update or delete on public.beds for each row execute function public._perm_rooms();
create trigger perm_extra_items before insert or update or delete on public.extra_items for each row execute function public._perm_rooms();

create or replace function public._perm_charges() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_perm(coalesce(new.property_id, old.property_id), 'add_extras');
  return coalesce(new, old);
end $$;
drop trigger if exists perm_charges on public.booking_charges;
create trigger perm_charges before insert or delete on public.booking_charges for each row execute function public._perm_charges();

-- payments are only visible to roles allowed to see them (booking screens still show a booking's own payments)
drop policy if exists payments_select on public.payments;
create policy payments_select on public.payments for select to authenticated
  using (property_id in (select public.my_property_ids()) and public._allowed(property_id, 'view_payments'));

create or replace function public.report_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz text; t0 timestamptz; t1 timestamptz;
  v_days int; v_beds int; v_revenue bigint; v_bed_nights bigint;
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_reports');
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Choose a range of up to one year.'; end if;
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_to + 1);
  v_days := p_to - p_from + 1;
  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0) into v_revenue
    from public.payments where property_id = p_property and received_at >= t0 and received_at < t1;
  select coalesce(sum(occupied), 0) into v_bed_nights from public.occupancy_series(p_property, p_from, p_to);

  return jsonb_build_object(
    'revenue', v_revenue,
    'days', v_days,
    'beds', v_beds,
    'occupancy', case when v_beds * v_days = 0 then 0 else round(v_bed_nights::numeric / (v_beds * v_days), 4) end,
    'revpab', case when v_beds * v_days = 0 then 0 else round(v_revenue::numeric / (v_beds * v_days)) end,
    'alos', (select coalesce(round(avg(nights), 1), 0) from public.bookings where property_id = p_property
              and check_in_at >= t0 and check_in_at < t1 and status in ('confirmed','checked_in','checked_out')),
    'weekly', (select coalesce(jsonb_agg(w order by w->>'start'), '[]'::jsonb) from (
                 select jsonb_build_object('start', ws::date,
                   'digital', coalesce(sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end)
                                        filter (where x.method <> 'cash'), 0),
                   'cash',    coalesce(sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end)
                                        filter (where x.method = 'cash'), 0)) w
                   from generate_series(p_from::timestamp, p_to::timestamp, interval '7 days') ws
                   left join public.payments x
                     on x.property_id = p_property
                    and x.received_at >= public._day_start(v_tz, ws::date)
                    and x.received_at <  least(public._day_start(v_tz, ws::date + 7), t1)
                  group by ws) q),
    'rooms', (select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'beds', rb.n,
                 'occupancy', case when rb.n * v_days = 0 then 0 else round(rn.nights::numeric / (rb.n * v_days), 4) end,
                 'revenue', coalesce(rv.amt, 0)) order by r.sort, r.name), '[]'::jsonb)
               from public.rooms r
               cross join lateral (select count(*) n from public.beds where room_id = r.id and is_active) rb
               cross join lateral (select count(*) nights
                                     from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
                                     join public.bookings b on b.stay @> public._night(v_tz, d::date)
                                     join public.beds bd on bd.id = b.bed_id
                                    where bd.room_id = r.id and b.property_id = p_property
                                      and b.status in ('pending','confirmed','checked_in','checked_out')) rn
               cross join lateral (select sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end) amt
                                     from public.payments x join public.bookings b on b.id = x.booking_id
                                     join public.beds bd on bd.id = b.bed_id
                                    where bd.room_id = r.id and x.property_id = p_property
                                      and x.received_at >= t0 and x.received_at < t1) rv
              where r.property_id = p_property),
    'sources', (select coalesce(jsonb_object_agg(source, n), '{}'::jsonb) from (
                  select source, count(*) n from public.bookings where property_id = p_property
                     and check_in_at >= t0 and check_in_at < t1 and status not in ('cancelled') group by source) s),
    'nationalities', (select coalesce(jsonb_agg(jsonb_build_object('name', nat, 'n', n) order by n desc), '[]'::jsonb) from (
                  select coalesce(nullif(g.nationality, ''), 'Unknown') nat, count(*) n
                    from public.bookings b join public.guests g on g.id = b.guest_id
                   where b.property_id = p_property and b.check_in_at >= t0 and b.check_in_at < t1
                     and b.status not in ('cancelled')
                   group by 1 order by 2 desc limit 6) q));
end $$;

create or replace function public.list_payments(
  p_property uuid, p_method text default null, p_from date default null, p_to date default null,
  p_cursor_at timestamptz default null, p_cursor_id uuid default null, p_limit int default 30)
returns table (id uuid, code text, booking_id uuid, booking_code text, guest_name text,
               kind public.payment_kind, method public.payment_method, amount_paise int,
               reference text, received_at timestamptz, booking_balance_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_tz text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_payments');
  v_tz := public._tz(p_property);
  return query
  select x.id, x.code, b.id, b.code, g.full_name, x.kind, x.method, x.amount_paise,
         x.reference, x.received_at, b.balance_paise
    from public.payments x
    join public.bookings b on b.id = x.booking_id
    join public.guests   g on g.id = b.guest_id
   where x.property_id = p_property
     and (p_method is null or x.method = p_method::public.payment_method)
     and (p_from is null or x.received_at >= public._day_start(v_tz, p_from))
     and (p_to   is null or x.received_at <  public._day_start(v_tz, p_to + 1))
     and (p_cursor_at is null or (x.received_at, x.id) < (p_cursor_at, p_cursor_id))
   order by x.received_at desc, x.id desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

create or replace function public.payment_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; t0 timestamptz; t1 timestamptz; pt0 timestamptz; v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_payments');
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_to + 1);
  pt0 := t0 - (t1 - t0);
  select jsonb_build_object(
    'revenue', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end)
                        filter (where received_at >= t0), 0),
    'previous', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end)
                        filter (where received_at < t0), 0),
    'upi',  coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'upi'  and received_at >= t0), 0),
    'cash', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'cash' and received_at >= t0), 0),
    'card', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'card' and received_at >= t0), 0),
    'bank', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'bank' and received_at >= t0), 0))
    into v
    from public.payments
   where property_id = p_property and received_at >= pt0 and received_at < t1;
  return v || jsonb_build_object(
    'dues_paise', (select coalesce(sum(balance_paise), 0) from public.bookings where property_id = p_property
                    and balance_paise > 0 and status in ('checked_in','checked_out')),
    'dues_count', (select count(*) from public.bookings where property_id = p_property
                    and balance_paise > 0 and status in ('checked_in','checked_out')));
end $$;

-- ---------- owner edits the permissions ----------
-- p: { "manager": { "refunds": false, … }, "front_desk": { … }, "accountant": { … } }
create or replace function public.set_role_permissions(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb := '{}'::jsonb; r text; k text;
  v_perms text[] := array['view_reports','view_payments','record_payments','refunds','cancel_bookings','delete_bookings',
                          'delete_guests','manage_rooms','add_extras','export_data'];
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  foreach r in array array['manager','front_desk','accountant'] loop
    if p ? r and jsonb_typeof(p->r) = 'object' then
      v := v || jsonb_build_object(r, (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
                                        from jsonb_each(p->r) where key = any (v_perms) and jsonb_typeof(value) = 'boolean'));
    end if;
  end loop;
  update public.properties set role_permissions = v where id = p_property;
  return v;
end $$;

revoke execute on function public._perm_default(public.member_role, text), public._allowed(uuid, text), public._require_perm(uuid, text),
  public._perm_payments(), public._perm_bookings(), public._perm_guests(), public._perm_rooms(), public._perm_charges(),
  public.set_role_permissions(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.set_role_permissions(uuid, jsonb), public._allowed(uuid, text) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 018_invoice_offers.sql
-- =====================================================================
-- NammaStay · 018_invoice_offers.sql
--   1. GST invoice / bill — numbered per financial year (INV/2026-27/0001),
--      prices include GST; CGST + SGST split; room GST automatic by nightly
--      rate (nil ≤ ₹1,000 · 5% ≤ ₹7,500 · 18% above) or a fixed rate.
--      Confirm the rates with your CA.
--   2. Regular-guest offers — off by default; e.g. 2nd stay 5%, 5th stay 10%.
-- Run AFTER 017_role_permissions.sql.
-- =====================================================================

alter table public.properties
  add column if not exists legal_name text check (char_length(legal_name) <= 120),
  add column if not exists gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'),
  add column if not exists gst_mode text not null default 'none' check (gst_mode in ('none','auto','fixed')),
  add column if not exists gst_rate numeric(5,2) not null default 5 check (gst_rate between 0 and 28),
  add column if not exists extras_gst_rate numeric(5,2) not null default 5 check (extras_gst_rate between 0 and 28),
  add column if not exists invoice_prefix text not null default 'INV' check (invoice_prefix ~ '^[A-Z0-9-]{1,10}$'),
  add column if not exists offers jsonb not null default '{"enabled": false, "tiers": [{"from_stay": 2, "pct": 5}, {"from_stay": 5, "pct": 10}]}'::jsonb
    check (jsonb_typeof(offers) = 'object');
grant update (legal_name, gstin, gst_mode, gst_rate, extras_gst_rate, invoice_prefix, offers)
  on public.properties to authenticated;                  -- RLS: owner / manager

alter table public.bookings
  add column if not exists discount_pct numeric(5,2) not null default 0 check (discount_pct between 0 and 100),
  add column if not exists discount_paise int not null default 0 check (discount_paise >= 0);

-- =====================================================================
-- 2. Regular-guest offers
-- =====================================================================
-- % off for this guest's NEXT stay (offers.tiers: from_stay = 2 means "second stay onwards")
create or replace function public._offer_pct(p_property uuid, p_guest uuid) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o jsonb; v_prev int; v_pct numeric := 0; t jsonb;
begin
  select offers into o from public.properties where id = p_property;
  if o is null or coalesce((o->>'enabled')::boolean, false) is not true or p_guest is null then return 0; end if;
  select count(*) into v_prev from public.bookings where guest_id = p_guest and status in ('checked_in','checked_out');
  for t in select * from jsonb_array_elements(coalesce(o->'tiers', '[]'::jsonb)) loop
    if (t->>'from_stay')::int <= v_prev + 1 and (t->>'pct')::numeric > v_pct then v_pct := least((t->>'pct')::numeric, 50); end if;
  end loop;
  return v_pct;
end $$;

-- Owner / manager can change or remove the offer on one booking
create or replace function public.set_booking_discount(p_booking uuid, p_pct numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings%rowtype; v_stay int; v_disc int;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager']::public.member_role[]);
  if p_pct < 0 or p_pct > 50 then raise exception 'Discount must be between 0 and 50%%.'; end if;
  v_stay := b.nights * (b.rate_paise + b.extra_paise);
  v_disc := round(v_stay * p_pct / 100.0);
  if v_stay - v_disc + b.charges_paise < b.paid_paise then raise exception 'The new total would be less than what’s already paid. Record a refund first.'; end if;
  update public.bookings set discount_pct = p_pct, discount_paise = v_disc, total_paise = v_stay - v_disc + charges_paise where id = b.id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'discount', jsonb_build_object('pct', p_pct, 'amount_paise', v_disc), auth.uid());
end $$;

create or replace function public.create_booking(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prop   uuid := (p->>'property_id')::uuid;
  v_in     timestamptz := (p->>'check_in_at')::timestamptz;
  v_out    timestamptz := (p->>'check_out_at')::timestamptz;
  v_status public.booking_status := coalesce(nullif(p->>'status', ''), 'pending')::public.booking_status;
  v_guest  uuid := nullif(p->>'guest_id', '')::uuid;
  v_bed    public.beds%rowtype;
  v_nights int;
  v_b      public.bookings%rowtype;
  v_pay    jsonb := p->'payment';
  v_dob    date := nullif(p#>>'{guest,dob}', '')::date;
  v_adults int;
  v_children int;
  v_extra  int;
  v_stay   int;
  v_pct    numeric := 0;
  v_disc   int := 0;
begin
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);

  if v_in is null or v_out is null then raise exception 'Check-in and check-out are required.'; end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;
  if v_in < now() - interval '2 days' then raise exception 'Check-in can''t be more than 2 days in the past.'; end if;
  if v_in > now() + interval '2 years' then raise exception 'Check-in is too far in the future.'; end if;
  if v_status not in ('pending','confirmed','checked_in') then raise exception 'A new booking must be pending, confirmed or checked in.'; end if;
  if v_status = 'checked_in' and public._local_date(v_prop, v_in) > public._local_date(v_prop, now()) then
    raise exception 'You can only check in a guest whose stay starts today.';
  end if;

  select * into v_bed from public.beds where id = (p->>'bed_id')::uuid and property_id = v_prop;
  if not found then raise exception 'Please choose a bed.'; end if;
  if not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  if v_guest is null then
    if coalesce(btrim(p#>>'{guest,full_name}'), '') = '' then raise exception 'Guest name is required.'; end if;
    if coalesce(p#>>'{guest,id_doc_path}', '') not in ('') and p#>>'{guest,id_doc_path}' not like v_prop::text || '/%'
       or coalesce(p#>>'{guest,id_doc_back_path}', '') not in ('') and p#>>'{guest,id_doc_back_path}' not like v_prop::text || '/%' then
      raise exception 'ID photo upload is invalid. Please try again.';
    end if;
    perform public._check_dob(v_dob);
    insert into public.guests (property_id, full_name, phone, email, dob, nationality, id_type, id_number, id_doc_path, id_doc_back_path, consent_at)
    values (v_prop,
            btrim(p#>>'{guest,full_name}'),
            public._clean_phone(p#>>'{guest,phone}'),
            nullif(lower(btrim(p#>>'{guest,email}')), ''),
            v_dob,
            nullif(btrim(p#>>'{guest,nationality}'), ''),
            nullif(p#>>'{guest,id_type}', '')::public.id_doc_type,
            public._mask_id(nullif(p#>>'{guest,id_type}', ''), p#>>'{guest,id_number}'),
            nullif(p#>>'{guest,id_doc_path}', ''),
            nullif(p#>>'{guest,id_doc_back_path}', ''),
            now())
    returning id into v_guest;
  elsif not exists (select 1 from public.guests where id = v_guest and property_id = v_prop) then
    raise exception 'Guest not found.';
  end if;

  v_nights := greatest(1, public._local_date(v_prop, v_out) - public._local_date(v_prop, v_in));
  v_adults := greatest(1, coalesce(nullif(p->>'visitors', '')::int, 1));
  v_children := greatest(0, coalesce(nullif(p->>'children', '')::int, 0));
  if v_adults + v_children > v_bed.max_guests then
    raise exception '% fits up to % guest%.', v_bed.label, v_bed.max_guests, case when v_bed.max_guests = 1 then '' else 's' end;
  end if;
  v_extra := greatest(0, v_adults - v_bed.base_guests) * v_bed.extra_guest_paise;
  v_stay := v_nights * (v_bed.rate_paise + v_extra);

  begin
    v_pct  := public._offer_pct(v_prop, v_guest);                        -- regular-guest offer (0 when off)
    v_disc := round(v_stay * v_pct / 100.0);
    insert into public.bookings (property_id, guest_id, bed_id, visitors, children, extra_paise, discount_pct, discount_paise, check_in_at, check_out_at,
                                 nights, rate_paise, total_paise, status, source, note,
                                 send_confirmation, arrived_at)
    values (v_prop, v_guest, v_bed.id,
            v_adults, v_children, v_extra, v_pct, v_disc,
            v_in, v_out, v_nights, v_bed.rate_paise, v_stay - v_disc,
            v_status,
            coalesce(nullif(p->>'source', ''), 'walk_in')::public.booking_source,
            nullif(btrim(p->>'note'), ''),
            coalesce((p->>'send_confirmation')::boolean, false),
            case when v_status = 'checked_in' then now() end)
    returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  if v_pay is not null and coalesce((v_pay->>'amount_paise')::int, 0) > 0 then
    perform public.record_payment(v_b.id, (v_pay->>'amount_paise')::int, v_pay->>'method',
                                  v_pay->>'reference', 'payment', null);
  end if;

  return jsonb_build_object('id', v_b.id, 'code', v_b.code, 'nights', v_nights, 'guest_id', v_b.guest_id, 'discount_pct', v_pct, 'discount_paise', v_disc,
                            'total_paise', v_b.total_paise,
                            'self_checkin_token', v_b.self_checkin_token);
end $$;

create or replace function public.update_booking(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_bed  public.beds%rowtype;
  v_in   timestamptz;
  v_out  timestamptz;
  v_rate int;
  v_nights int;
  v_adults int;
  v_children int;
  v_extra int;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if v_b.status not in ('pending','confirmed','checked_in') then
    raise exception 'This booking is % and can''t be changed.', replace(v_b.status::text, '_', ' ');
  end if;

  v_in  := coalesce((p->>'check_in_at')::timestamptz,  v_b.check_in_at);
  v_out := coalesce((p->>'check_out_at')::timestamptz, v_b.check_out_at);
  if v_b.status = 'checked_in' and v_in <> v_b.check_in_at then
    raise exception 'Guest is already checked in; only the check-out can change.';
  end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;

  select * into v_bed from public.beds
   where id = coalesce(nullif(p->>'bed_id', '')::uuid, v_b.bed_id) and property_id = v_b.property_id;
  if not found then raise exception 'Bed not found.'; end if;
  if v_bed.id <> v_b.bed_id and not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  v_rate   := case when v_bed.id = v_b.bed_id then v_b.rate_paise else v_bed.rate_paise end;
  v_nights := greatest(1, public._local_date(v_b.property_id, v_out) - public._local_date(v_b.property_id, v_in));
  v_adults := greatest(1, coalesce(nullif(p->>'visitors', '')::int, v_b.visitors));
  v_children := greatest(0, coalesce(nullif(p->>'children', '')::int, v_b.children));
  -- check capacity only when guests or the room change (older bookings keep working)
  if (p ? 'visitors' or p ? 'children' or v_bed.id <> v_b.bed_id) and v_adults + v_children > v_bed.max_guests then
    raise exception '% fits up to % guest%.', v_bed.label, v_bed.max_guests, case when v_bed.max_guests = 1 then '' else 's' end;
  end if;
  v_extra := greatest(0, v_adults - v_bed.base_guests) * v_bed.extra_guest_paise;
  if v_nights * (v_rate + v_extra) - round(v_nights * (v_rate + v_extra) * v_b.discount_pct / 100.0) + v_b.charges_paise < v_b.paid_paise then
    raise exception 'New total is less than what''s already paid. Record a refund first.';
  end if;

  begin
    update public.bookings
       set check_in_at = v_in, check_out_at = v_out, bed_id = v_bed.id,
           rate_paise = v_rate, nights = v_nights,
           discount_paise = round(v_nights * (v_rate + v_extra) * discount_pct / 100.0),
           total_paise = v_nights * (v_rate + v_extra) - round(v_nights * (v_rate + v_extra) * discount_pct / 100.0) + charges_paise,
           visitors = v_adults, children = v_children, extra_paise = v_extra,
           note = case when p ? 'note' then nullif(btrim(p->>'note'), '') else note end
     where id = p_booking
     returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  return jsonb_build_object('id', v_b.id, 'total_paise', v_b.total_paise, 'nights', v_b.nights);
end $$;

-- =====================================================================
-- 1. Invoices
-- =====================================================================
create table public.invoice_counters (
  property_id uuid not null references public.properties(id) on delete cascade,
  fy          text not null,
  last_no     int  not null default 0,
  primary key (property_id, fy)
);
create table public.invoices (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null,
  booking_id  uuid not null,
  number      text not null,
  fy          text not null,
  issued_at   timestamptz not null default now(),
  total_paise int not null,
  doc         jsonb not null,
  created_by  uuid default auth.uid(),
  unique (property_id, number),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index invoices_booking on public.invoices (booking_id, issued_at desc);
alter table public.invoice_counters enable row level security;
alter table public.invoices enable row level security;
create policy invoices_select on public.invoices for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.invoice_counters, public.invoices from anon, authenticated;
grant select on public.invoices to authenticated;

create or replace function public._room_gst(p_mode text, p_fixed numeric, p_per_night int) returns numeric
language sql immutable set search_path = public, pg_temp as $$
  select case p_mode when 'none' then 0 when 'fixed' then p_fixed
    else case when p_per_night <= 100000 then 0 when p_per_night <= 750000 then 5 else 18 end end
$$;

-- p_buyer (optional): { "name": "...", "gstin": "..." } for company bills
create or replace function public.issue_invoice(p_booking uuid, p_buyer jsonb default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b public.bookings%rowtype; p public.properties%rowtype; g public.guests%rowtype;
  v_room text; v_bed text; v_lines jsonb := '[]'::jsonb; v_amt bigint := 0; v_taxable bigint := 0; v_tax bigint := 0;
  r_room numeric; r_x numeric; v_per int; ln record; v_fy text; v_no int; v_num text; v_doc jsonb; v_last public.invoices%rowtype;
  v_buyer jsonb := coalesce(p_buyer, '{}'::jsonb);
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if b.status in ('cancelled','no_show') and b.paid_paise = 0 then raise exception 'Nothing to bill on a cancelled booking.'; end if;
  if nullif(v_buyer->>'gstin', '') is not null and upper(v_buyer->>'gstin') !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then
    raise exception 'Check the company GSTIN (15 characters).';
  end if;
  select * into p from public.properties where id = b.property_id;
  select * into g from public.guests where id = b.guest_id;
  select r.name, bd.label into v_room, v_bed from public.beds bd join public.rooms r on r.id = bd.room_id where bd.id = b.bed_id;

  v_per  := b.rate_paise + b.extra_paise - (b.discount_paise / greatest(b.nights, 1));
  r_room := public._room_gst(p.gst_mode, p.gst_rate, v_per);
  r_x    := case when p.gst_mode = 'none' then 0 else p.extras_gst_rate end;

  -- lines: (description, sac, qty, rate, amount, gst %)
  for ln in
    select * from (values
      (1, format('Accommodation — %s · %s', v_room, v_bed), '996311', b.nights::numeric, b.rate_paise, b.nights * b.rate_paise, r_room),
      (2, 'Extra guest charge', '996311', b.nights::numeric, b.extra_paise, b.nights * b.extra_paise, r_room),
      (3, format('Regular-guest offer (%s%%)', trim(to_char(b.discount_pct, 'FM990.##'))), '996311', 1::numeric, -b.discount_paise, -b.discount_paise, r_room)
    ) v(o, d, sac, q, rt, amt, rate) where amt <> 0
    union all
    select 10 + row_number() over (order by c.created_at), c.name || coalesce(' — ' || c.note, ''),
           case c.category when 'food' then '996331' else '' end, c.qty, c.unit_price_paise, c.amount_paise, r_x
      from public.booking_charges c where c.booking_id = b.id
    order by 1
  loop
    declare v_t bigint := round(ln.amt * 100.0 / (100 + ln.rate)); begin
      v_lines := v_lines || jsonb_build_object('desc', ln.d, 'sac', ln.sac, 'qty', ln.q, 'rate_paise', ln.rt, 'amount_paise', ln.amt,
                                               'gst_rate', ln.rate, 'taxable_paise', v_t, 'tax_paise', ln.amt - v_t);
      v_amt := v_amt + ln.amt; v_taxable := v_taxable + v_t; v_tax := v_tax + (ln.amt - v_t);
    end;
  end loop;

  -- same bill as last time → reuse its number
  select * into v_last from public.invoices where booking_id = b.id order by issued_at desc limit 1;
  if found and v_last.total_paise = v_amt and v_last.doc->'lines' = v_lines
     and coalesce(v_last.doc->'buyer'->>'company', '') = coalesce(v_buyer->>'name', '')
     and coalesce(v_last.doc->'buyer'->>'gstin', '') = coalesce(upper(v_buyer->>'gstin'), '')
     and (v_last.doc->>'paid_paise')::int = b.paid_paise then
    return v_last.doc;
  end if;

  v_fy := (select case when extract(month from d) >= 4 then extract(year from d)::int else extract(year from d)::int - 1 end
             from (select public._local_date(b.property_id, now()) d) x)::text;
  v_fy := v_fy || '-' || right(((v_fy::int) + 1)::text, 2);
  insert into public.invoice_counters (property_id, fy, last_no) values (b.property_id, v_fy, 1)
  on conflict (property_id, fy) do update set last_no = public.invoice_counters.last_no + 1
  returning last_no into v_no;
  v_num := p.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 4, '0');

  v_doc := jsonb_build_object(
    'number', v_num, 'issued_at', now(), 'fy', v_fy,
    'title', case when p.gst_mode <> 'none' and p.gstin is not null then 'Tax invoice' else 'Bill / receipt' end,
    'gst', p.gst_mode <> 'none' and p.gstin is not null,
    'seller', jsonb_build_object('name', p.name, 'legal_name', coalesce(p.legal_name, p.name), 'gstin', p.gstin,
                                 'address', concat_ws(', ', p.address, p.city), 'phone', p.phone, 'email', p.email),
    'buyer', jsonb_build_object('name', g.full_name, 'phone', g.phone, 'email', g.email,
                                'company', nullif(btrim(v_buyer->>'name'), ''), 'gstin', nullif(upper(btrim(v_buyer->>'gstin')), '')),
    'stay', jsonb_build_object('code', b.code, 'room', v_room, 'bed', v_bed, 'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at,
                               'nights', b.nights, 'adults', b.visitors, 'children', b.children),
    'lines', v_lines,
    'amount_paise', v_amt, 'taxable_paise', v_taxable, 'cgst_paise', v_tax / 2, 'sgst_paise', v_tax - v_tax / 2,
    'paid_paise', b.paid_paise, 'balance_paise', v_amt - b.paid_paise,
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'kind', x.kind, 'method', x.method, 'amount_paise', x.amount_paise,
                   'received_at', x.received_at, 'reference', x.reference) order by x.received_at), '[]'::jsonb)
                 from public.payments x where x.booking_id = b.id));
  insert into public.invoices (property_id, booking_id, number, fy, total_paise, doc) values (b.property_id, b.id, v_num, v_fy, v_amt, v_doc);
  return v_doc;
end $$;

revoke execute on function public._offer_pct(uuid, uuid), public.set_booking_discount(uuid, numeric), public._room_gst(text, numeric, int),
  public.issue_invoice(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.set_booking_discount(uuid, numeric), public.issue_invoice(uuid, jsonb) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 019_prices_oct_2026.sql
-- =====================================================================
-- NammaStay · 019_prices_oct_2026.sql
-- New subscription prices (flat price per property, 15-day free trial):
--   Hostel / PG           ₹3,999 / month   ₹27,999 / year
--   Homestay (≤ 6 rooms)  ₹1,999 / month   ₹12,999 / year
--   Hotel small (≤ 20)    ₹3,999 / month   ₹27,999 / year
--   Hotel mid (21–50)     ₹6,999 / month   ₹45,999 / year
--   Hotel large (51+)     custom quote (unchanged)
-- Existing paid-until dates are not changed; new prices apply to the
-- next payment. Change prices later in the app: Subscribers → Billing settings.
-- Run AFTER 015_plans_by_type.sql.
-- =====================================================================
update public.plans set price_paise = 399900,  description = 'Billed every month'                 where id = 'monthly';
update public.plans set price_paise = 2799900, description = 'Save ₹19,989 a year'                where id = 'yearly';
update public.plans set price_paise = 199900,  description = 'Homestays up to 6 rooms'            where id = 'homestay_monthly';
update public.plans set price_paise = 1299900, description = 'Homestays · save ₹10,989 a year'    where id = 'homestay_yearly';
update public.plans set price_paise = 399900,  description = 'Hotels up to 20 rooms'              where id = 'hotel_s_monthly';
update public.plans set price_paise = 2799900, description = 'Up to 20 rooms · save ₹19,989 a year' where id = 'hotel_s_yearly';
update public.plans set price_paise = 699900,  description = 'Hotels with 21–50 rooms'            where id = 'hotel_m_monthly';
update public.plans set price_paise = 4599900, description = '21–50 rooms · save ₹37,989 a year'  where id = 'hotel_m_yearly';

-- check
select id, kind, name, price_paise / 100 as price_rupees, description from public.plans order by sort;


-- >>>>>>>>>>>>>>>>>>>> 020_ota_sync.sql
-- =====================================================================
-- NammaStay · 020_ota_sync.sql
-- OTA calendar sync (iCal) — Airbnb, Booking.com, Agoda, Vrbo, Google…
--   EXPORT: every bed/room has a secret calendar link (beds.ical_token).
--           OTAs import it, so nights booked or blocked in NammaStay are
--           closed there too. Served by the `ical` edge function.
--   IMPORT: each bed/room can have OTA calendar links (ota_feeds). The
--           `ota-sync` edge function fetches them (every 30 min + "Sync
--           now") and calls ota_apply(), which turns OTA reservations into
--           calendar blocks ("🔗 Airbnb · reserved") so staff can't
--           double-book them. Clashes with NammaStay bookings → alert.
-- iCal shares availability only — not prices, guest names or payments.
-- Run AFTER 019_prices_oct_2026.sql. Then deploy the two edge functions
-- and run setup/ota_schedule.sql (see docs/GO-LIVE.md §35).
-- =====================================================================

alter table public.beds add column if not exists ical_token uuid not null default gen_random_uuid();
create unique index if not exists beds_ical_token on public.beds (ical_token);

create table if not exists public.ota_feeds (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null,
  bed_id         uuid not null,
  channel        text not null check (channel in ('airbnb','booking','agoda','vrbo','google','other')),
  import_url     text not null check (import_url ~ '^https://' and char_length(import_url) <= 1000),
  label          text check (char_length(label) <= 60),
  last_synced_at timestamptz,
  last_status    text check (last_status in ('ok','error')),
  last_error     text check (char_length(last_error) <= 300),
  events_count   int not null default 0,
  created_at     timestamptz not null default now(),
  foreign key (bed_id, property_id) references public.beds(id, property_id) on delete cascade,
  unique (bed_id, import_url)
);
create index if not exists ota_feeds_prop on public.ota_feeds (property_id);

alter table public.bed_blocks
  add column if not exists feed_id uuid references public.ota_feeds(id) on delete cascade,
  add column if not exists external_uid text check (char_length(external_uid) <= 300);
create unique index if not exists bed_blocks_feed_uid on public.bed_blocks (feed_id, external_uid) where feed_id is not null;

alter table public.ota_feeds enable row level security;
create policy ota_feeds_select on public.ota_feeds for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])));
revoke all on public.ota_feeds from anon, authenticated;
grant select on public.ota_feeds to authenticated;

-- ---------------------------------------------------------------- staff (owner / manager with "rooms & prices")
create or replace function public.ota_overview(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'bed_id', bd.id, 'label', bd.label, 'room', r.name, 'is_active', bd.is_active, 'token', bd.ical_token,
      'feeds', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'channel', f.channel, 'label', f.label, 'import_url', f.import_url,
                  'last_synced_at', f.last_synced_at, 'last_status', f.last_status, 'last_error', f.last_error, 'events_count', f.events_count)
                  order by f.created_at), '[]'::jsonb) from public.ota_feeds f where f.bed_id = bd.id))
      order by r.sort, r.name, bd.sort, bd.label), '[]'::jsonb)
    from public.beds bd join public.rooms r on r.id = bd.room_id where bd.property_id = p_property);
end $$;

create or replace function public.ota_feed_save(p_property uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_url text := btrim(coalesce(p->>'import_url', ''));
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._require_perm(p_property, 'manage_rooms');
  if v_url !~ '^https://' then raise exception 'Paste the full calendar link — it starts with https://'; end if;
  if v_url ~* 'thenammastay|/functions/v1/ical' then raise exception 'That’s a NammaStay link — paste the link from the OTA instead.'; end if;
  if not exists (select 1 from public.beds where id = (p->>'bed_id')::uuid and property_id = p_property) then raise exception 'Choose a bed or room.'; end if;
  if nullif(p->>'id', '') is null then
    insert into public.ota_feeds (property_id, bed_id, channel, import_url, label)
    values (p_property, (p->>'bed_id')::uuid, coalesce(nullif(p->>'channel', ''), 'other'), v_url, nullif(left(btrim(coalesce(p->>'label', '')), 60), ''))
    returning id into v_id;
  else
    update public.ota_feeds set channel = coalesce(nullif(p->>'channel', ''), channel), import_url = v_url,
           label = nullif(left(btrim(coalesce(p->>'label', '')), 60), '')
     where id = (p->>'id')::uuid and property_id = p_property returning id into v_id;
    if v_id is null then raise exception 'Calendar link not found.'; end if;
  end if;
  return v_id;
exception when unique_violation then raise exception 'That calendar link is already added for this bed/room.';
end $$;

create or replace function public.ota_feed_delete(p_feed uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.ota_feeds where id = p_feed;
  if v_prop is null then raise exception 'Calendar link not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  perform public._require_perm(v_prop, 'manage_rooms');
  delete from public.ota_feeds where id = p_feed;                 -- its imported blocks go too
end $$;

-- New secret link for one bed/room (if the old one was shared by mistake)
create or replace function public.ota_new_token(p_bed uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid; v_tok uuid := gen_random_uuid();
begin
  select property_id into v_prop from public.beds where id = p_bed;
  if v_prop is null then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  update public.beds set ical_token = v_tok where id = p_bed;
  return v_tok;
end $$;

-- Feeds the `ota-sync` function may refresh for this person (checks their role)
create or replace function public.ota_feeds_for_sync(p_property uuid) returns setof uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query select id from public.ota_feeds where property_id = p_property;
end $$;

-- ---------------------------------------------------------------- server only (edge functions, service role)
-- Calendar export for one bed/room. p_exclude: skip blocks imported from this channel (avoids echoing an OTA's own bookings back).
create or replace function public.ota_export(p_token uuid, p_exclude text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare bd public.beds%rowtype; p public.properties%rowtype;
begin
  select * into bd from public.beds where ical_token = p_token;
  if not found then return null; end if;
  select * into p from public.properties where id = bd.property_id;
  return jsonb_build_object(
    'name', p.name || ' · ' || bd.label, 'tz', p.timezone,
    'events', (select coalesce(jsonb_agg(e), '[]'::jsonb) from (
       select jsonb_build_object('uid', 'ns-b-' || b.id, 'start', (b.check_in_at at time zone p.timezone)::date,
                                 'end', greatest((b.check_out_at at time zone p.timezone)::date, (b.check_in_at at time zone p.timezone)::date + 1),
                                 'summary', 'Reserved') e
         from public.bookings b
        where b.bed_id = bd.id and b.status in ('pending','confirmed','checked_in') and b.check_out_at > now() - interval '1 day'
       union all
       select jsonb_build_object('uid', 'ns-k-' || k.id, 'start', (k.starts_at at time zone p.timezone)::date,
                                 'end', greatest((k.ends_at at time zone p.timezone)::date, (k.starts_at at time zone p.timezone)::date + 1),
                                 'summary', 'Not available') e
         from public.bed_blocks k left join public.ota_feeds f on f.id = k.feed_id
        where k.bed_id = bd.id and k.ends_at > now() - interval '1 day'
          and (p_exclude is null or f.channel is distinct from p_exclude)) x));
end $$;

create or replace function public.ota_due_feeds(p_limit int default 300) returns setof public.ota_feeds
language sql stable security definer set search_path = public, pg_temp as $$
  select f.* from public.ota_feeds f join public.beds b on b.id = f.bed_id
   where b.is_active and public._access_state(f.property_id) not in ('expired','suspended')
   order by f.last_synced_at nulls first limit least(greatest(coalesce(p_limit, 300), 1), 1000)
$$;

-- p_events: [{ "uid": "...", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD" }]  (end = check-out day)
-- or p_error: why fetching/parsing failed.
create or replace function public.ota_apply(p_feed uuid, p_events jsonb, p_error text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  f public.ota_feeds%rowtype; p public.properties%rowtype; bd public.beds%rowtype; e jsonb;
  v_start timestamptz; v_end timestamptz; v_uids text[] := '{}'; v_added int := 0; v_updated int := 0; v_removed int := 0; v_clash int := 0;
  v_name text; v_ex public.bed_blocks%rowtype; v_has boolean;
begin
  select * into f from public.ota_feeds where id = p_feed for update;
  if not found then return jsonb_build_object('error', 'feed not found'); end if;
  select * into p from public.properties where id = f.property_id;
  select * into bd from public.beds where id = f.bed_id;
  v_name := case f.channel when 'airbnb' then 'Airbnb' when 'booking' then 'Booking.com' when 'agoda' then 'Agoda'
            when 'vrbo' then 'Vrbo' when 'google' then 'Google Calendar' else coalesce(f.label, 'OTA') end;

  if p_error is not null then
    update public.ota_feeds set last_synced_at = now(), last_status = 'error', last_error = left(p_error, 300) where id = f.id;
    return jsonb_build_object('error', p_error);
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) loop
    continue when nullif(e->>'uid', '') is null or nullif(e->>'start', '') is null or nullif(e->>'end', '') is null;
    continue when (e->>'end')::date <= public._local_date(p.id, now()) or (e->>'end')::date <= (e->>'start')::date;
    v_start := ((e->>'start')::date::timestamp + p.checkin_time) at time zone p.timezone;
    v_end   := ((e->>'end')::date::timestamp + p.checkout_time) at time zone p.timezone;
    if v_end <= v_start then v_end := ((e->>'end')::date::timestamp + interval '12 hours') at time zone p.timezone; end if;
    v_uids := v_uids || left(e->>'uid', 300);

    select * into v_ex from public.bed_blocks where feed_id = f.id and external_uid = left(e->>'uid', 300);
    v_has := found;
    if v_has and v_ex.starts_at = v_start and v_ex.ends_at = v_end then continue; end if;

    -- clash with a NammaStay booking on the same bed/room → don't block, alert the staff once
    if exists (select 1 from public.bookings b where b.bed_id = bd.id and b.status in ('pending','confirmed','checked_in')
                and b.stay && tstzrange(v_start, v_end, '[)')) then
      v_clash := v_clash + 1;
      if not exists (select 1 from public.notifications n where n.property_id = p.id and n.kind = 'ota_clash'
                       and n.body like '%' || left(e->>'uid', 60) || '%' and n.created_at > now() - interval '7 days') then
        insert into public.notifications (property_id, kind, title, body)
        values (p.id, 'ota_clash', format('Double booking? %s · %s', v_name, bd.label),
                format('%s has a booking %s → %s, but %s is already booked in NammaStay. Move one of them. [%s]',
                       v_name, to_char((e->>'start')::date, 'DD Mon'), to_char((e->>'end')::date, 'DD Mon'), bd.label, left(e->>'uid', 60)));
      end if;
      if v_has then delete from public.bed_blocks where id = v_ex.id; end if;
      continue;
    end if;

    begin
      if v_has then
        update public.bed_blocks set starts_at = v_start, ends_at = v_end where id = v_ex.id; v_updated := v_updated + 1;
      else
        insert into public.bed_blocks (property_id, bed_id, starts_at, ends_at, reason, feed_id, external_uid, created_by)
        values (p.id, bd.id, v_start, v_end, '🔗 ' || v_name || ' · reserved', f.id, left(e->>'uid', 300), null);
        v_added := v_added + 1;
      end if;
    exception when exclusion_violation then null;                 -- already blocked (maintenance or another OTA): nothing to do
    end;
  end loop;

  delete from public.bed_blocks k where k.feed_id = f.id and not (k.external_uid = any (v_uids));
  get diagnostics v_removed = row_count;
  update public.ota_feeds set last_synced_at = now(), last_status = 'ok', last_error = null,
         events_count = (select count(*) from public.bed_blocks where feed_id = f.id) where id = f.id;
  return jsonb_build_object('added', v_added, 'updated', v_updated, 'removed', v_removed, 'clashes', v_clash);
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public.ota_overview(uuid), public.ota_feed_save(uuid, jsonb), public.ota_feed_delete(uuid),
  public.ota_new_token(uuid), public.ota_feeds_for_sync(uuid), public.ota_export(uuid, text), public.ota_due_feeds(int),
  public.ota_apply(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.ota_overview(uuid), public.ota_feed_save(uuid, jsonb), public.ota_feed_delete(uuid),
  public.ota_new_token(uuid), public.ota_feeds_for_sync(uuid) to authenticated;
grant execute on function public.ota_export(uuid, text), public.ota_due_feeds(int), public.ota_apply(uuid, jsonb, text) to service_role;


-- >>>>>>>>>>>>>>>>>>>> 021_expenses_paylinks.sql
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


-- >>>>>>>>>>>>>>>>>>>> 022_admin_2fa.sql
-- =====================================================================
-- NammaStay · 022_admin_2fa.sql
-- The admin website (admin.thenammastay.com) uses 2-step login: password
-- + a 6-digit code from an authenticator app (Google Authenticator,
-- Microsoft Authenticator, Authy…). Supabase calls this MFA / TOTP.
-- Once an admin has set up their authenticator, every admin action
-- (Overview, Subscribers, Leads, approving payments, prices…) is refused
-- unless that sign-in was confirmed with the code (session level "aal2").
-- Before setup, the admin website forces setup on first sign-in.
-- Run AFTER 021_expenses_paylinks.sql.
-- =====================================================================

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
     and (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
          or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'))
$$;

-- For the admin sign-in page: is this login an admin, has it set up the authenticator, was the code entered?
create or replace function public.admin_mfa_info() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'admin', exists (select 1 from public.platform_admins where user_id = auth.uid()),
    'has_factor', exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'),
    'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'))
$$;
revoke execute on function public.admin_mfa_info() from public, anon;
grant execute on function public.admin_mfa_info() to authenticated;

-- Lost your phone? Run this (with the admin's email) to remove their authenticator,
-- then they set it up again at the next sign-in:
--   delete from auth.mfa_factors where user_id = (select id from auth.users where lower(email) = lower('admin@thenammastay.com'));


-- >>>>>>>>>>>>>>>>>>>> 023_platform_invoices_reminders.sql
-- =====================================================================
-- NammaStay · 023_platform_invoices_reminders.sql
--   1. GST invoices for NammaStay subscriptions (NammaStay → property).
--      Issued automatically when an admin approves a subscription payment.
--      Numbered per financial year (NS/2026-27/0001). Prices include GST.
--      Same state as NammaStay → CGST + SGST, other state → IGST.
--      Without NammaStay's GSTIN the document is a plain invoice/receipt.
--   2. Billing reminders: trial ending (3 days, 1 day), trial ended,
--      renewal due (7 days, 1 day), access ended. Each reminder is created
--      once, appears in the owner's notifications, is emailed by the
--      `billing-reminders` edge function (if email is set up) and shows in
--      the admin website with a one-tap WhatsApp message.
-- Rates/SAC: confirm with your CA. Run AFTER 022_admin_2fa.sql.
-- =====================================================================

-- ---------------------------------------------------------------- settings
alter table public.platform_settings
  add column if not exists legal_name     text check (char_length(legal_name) <= 120),
  add column if not exists gstin          text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'),
  add column if not exists address        text check (char_length(address) <= 300),
  add column if not exists state_code     text not null default '33' check (state_code ~ '^[0-9]{2}$'),
  add column if not exists sac            text not null default '998314' check (sac ~ '^[0-9]{4,8}$'),
  add column if not exists gst_rate       numeric(5,2) not null default 18 check (gst_rate between 0 and 28),
  add column if not exists invoice_prefix text not null default 'NS' check (invoice_prefix ~ '^[A-Z0-9-]{1,10}$');

-- Owner's billing details (what goes on their subscription invoice)
alter table public.properties
  add column if not exists bill_name    text check (char_length(bill_name) <= 120),
  add column if not exists bill_gstin   text check (bill_gstin is null or bill_gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'),
  add column if not exists bill_address text check (char_length(bill_address) <= 300),
  add column if not exists bill_state   text check (bill_state is null or bill_state ~ '^[0-9]{2}$');

create or replace function public.set_billing_details(p_property uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_gstin text := nullif(upper(btrim(coalesce(p->>'bill_gstin', ''))), '');
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then raise exception 'Check the GSTIN — 15 characters, e.g. 33ABCDE1234F1Z5.'; end if;
  update public.properties set
    bill_name = nullif(left(btrim(coalesce(p->>'bill_name', '')), 120), ''),
    bill_gstin = v_gstin,
    bill_address = nullif(left(btrim(coalesce(p->>'bill_address', '')), 300), ''),
    bill_state = coalesce(left(v_gstin, 2), nullif(p->>'bill_state', ''))
  where id = p_property;
end $$;

create or replace function public.admin_invoice_settings() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select jsonb_build_object('legal_name', legal_name, 'gstin', gstin, 'address', address, 'state_code', state_code,
            'sac', sac, 'gst_rate', gst_rate, 'invoice_prefix', invoice_prefix, 'payee_name', payee_name,
            'support_email', support_email, 'support_whatsapp', support_whatsapp)
          from public.platform_settings where id = 1);
end $$;

create or replace function public.admin_save_invoice_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_gstin text := nullif(upper(btrim(coalesce(p->>'gstin', ''))), '');
begin
  perform public._assert_platform_admin();
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then raise exception 'Check the GSTIN — 15 characters.'; end if;
  update public.platform_settings set
    legal_name = nullif(left(btrim(coalesce(p->>'legal_name', '')), 120), ''),
    gstin = v_gstin,
    address = nullif(left(btrim(coalesce(p->>'address', '')), 300), ''),
    state_code = coalesce(left(v_gstin, 2), nullif(p->>'state_code', ''), state_code),
    sac = coalesce(nullif(btrim(coalesce(p->>'sac', '')), ''), sac),
    gst_rate = coalesce(nullif(p->>'gst_rate', '')::numeric, gst_rate),
    invoice_prefix = coalesce(nullif(upper(btrim(coalesce(p->>'invoice_prefix', ''))), ''), invoice_prefix),
    updated_at = now()
  where id = 1;
end $$;

-- ---------------------------------------------------------------- invoices
create table if not exists public.platform_invoice_counters (fy text primary key, last_no int not null default 0);
create table if not exists public.platform_invoices (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  payment_id  uuid not null unique references public.subscription_payments(id) on delete cascade,
  number      text not null unique,
  fy          text not null,
  issued_at   timestamptz not null default now(),
  total_paise int  not null,
  doc         jsonb not null
);
create index if not exists platform_invoices_prop on public.platform_invoices (property_id, issued_at desc);
alter table public.platform_invoice_counters enable row level security;
alter table public.platform_invoices enable row level security;
revoke all on public.platform_invoice_counters, public.platform_invoices from anon, authenticated;

create or replace function public._issue_platform_invoice(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  sp public.subscription_payments%rowtype; ps public.platform_settings%rowtype; pr public.properties%rowtype; pl public.plans%rowtype;
  v_owner record; v_existing public.platform_invoices%rowtype; v_fy text; v_no int; v_num text; v_doc jsonb;
  v_gst boolean; v_inter boolean; v_rate numeric; v_taxable bigint; v_tax bigint; v_buyer_state text; v_day date;
begin
  select * into v_existing from public.platform_invoices where payment_id = p_payment;
  if found then return v_existing.doc; end if;
  select * into sp from public.subscription_payments where id = p_payment;
  if not found or sp.status <> 'approved' then return null; end if;
  select * into ps from public.platform_settings where id = 1;
  select * into pr from public.properties where id = sp.property_id;
  select * into pl from public.plans where id = sp.plan_id;
  select m.display_name, m.email into v_owner from public.property_members m where m.property_id = pr.id and m.role = 'owner' order by m.created_at limit 1;

  v_gst := ps.gstin is not null;
  v_rate := case when v_gst then ps.gst_rate else 0 end;
  v_taxable := round(sp.amount_paise * 100.0 / (100 + v_rate));
  v_tax := sp.amount_paise - v_taxable;
  v_buyer_state := coalesce(left(pr.bill_gstin, 2), pr.bill_state);
  v_inter := v_buyer_state is not null and v_buyer_state <> ps.state_code;

  v_day := (coalesce(sp.reviewed_at, now()) at time zone 'Asia/Kolkata')::date;
  v_fy := case when extract(month from v_day) >= 4 then extract(year from v_day)::int else extract(year from v_day)::int - 1 end::text;
  v_fy := v_fy || '-' || right(((v_fy::int) + 1)::text, 2);
  insert into public.platform_invoice_counters (fy, last_no) values (v_fy, 1)
  on conflict (fy) do update set last_no = public.platform_invoice_counters.last_no + 1 returning last_no into v_no;
  v_num := ps.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 4, '0');

  v_doc := jsonb_build_object(
    'number', v_num, 'issued_at', coalesce(sp.reviewed_at, now()), 'fy', v_fy, 'subscription', true,
    'title', case when v_gst then 'Tax invoice' else 'Invoice' end, 'gst', v_gst, 'inter_state', v_gst and v_inter,
    'seller', jsonb_build_object('name', 'NammaStay', 'legal_name', coalesce(ps.legal_name, ps.payee_name, 'NammaStay'), 'gstin', ps.gstin,
                                 'address', ps.address, 'phone', ps.support_whatsapp, 'email', ps.support_email),
    'buyer', jsonb_build_object('name', coalesce(pr.bill_name, pr.name), 'company', case when pr.bill_name is not null and pr.bill_name <> pr.name then pr.name end,
                                'gstin', pr.bill_gstin, 'address', coalesce(pr.bill_address, concat_ws(', ', pr.address, pr.city)),
                                'phone', pr.phone, 'email', v_owner.email),
    'period', jsonb_build_object('plan', pl.name, 'kind', pl.kind, 'from', sp.period_start, 'to', sp.period_end, 'property', pr.name),
    'lines', jsonb_build_array(jsonb_build_object(
       'desc', format('NammaStay subscription — %s plan (%s → %s) · %s', pl.name,
                      to_char(sp.period_start at time zone 'Asia/Kolkata', 'DD Mon YYYY'), to_char(sp.period_end at time zone 'Asia/Kolkata', 'DD Mon YYYY'), pr.name),
       'sac', ps.sac, 'qty', 1, 'rate_paise', sp.amount_paise, 'amount_paise', sp.amount_paise, 'gst_rate', v_rate,
       'taxable_paise', v_taxable, 'tax_paise', v_tax)),
    'amount_paise', sp.amount_paise, 'taxable_paise', v_taxable,
    'cgst_paise', case when v_gst and not v_inter then v_tax / 2 else 0 end,
    'sgst_paise', case when v_gst and not v_inter then v_tax - v_tax / 2 else 0 end,
    'igst_paise', case when v_gst and v_inter then v_tax else 0 end,
    'paid_paise', sp.amount_paise, 'balance_paise', 0,
    'payments', jsonb_build_array(jsonb_build_object('code', 'UPI', 'kind', 'payment', 'method', 'upi', 'amount_paise', sp.amount_paise,
                                                     'received_at', sp.submitted_at, 'reference', sp.utr)));
  insert into public.platform_invoices (property_id, payment_id, number, fy, issued_at, total_paise, doc)
  values (pr.id, sp.id, v_num, v_fy, coalesce(sp.reviewed_at, now()), sp.amount_paise, v_doc);
  insert into public.notifications (property_id, kind, title, body)
  values (pr.id, 'subscription', 'Invoice ' || v_num || ' is ready', 'Settings → Billing → Your invoices');
  return v_doc;
end $$;

create or replace function public._on_sub_payment_approved() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then perform public._issue_platform_invoice(new.id); end if;
  return new;
end $$;
drop trigger if exists sub_payment_invoice on public.subscription_payments;
create trigger sub_payment_invoice after update of status on public.subscription_payments
  for each row execute function public._on_sub_payment_approved();

-- Owner / manager: their invoices
create or replace function public.my_platform_invoices(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object('number', number, 'issued_at', issued_at, 'total_paise', total_paise, 'doc', doc)
            order by issued_at desc), '[]'::jsonb) from public.platform_invoices where property_id = p_property);
end $$;

-- Admin: one property, or the latest across all
create or replace function public.admin_platform_invoices(p_property uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('number', i.number, 'issued_at', i.issued_at, 'total_paise', i.total_paise,
            'payment_id', i.payment_id, 'property', p.name, 'property_id', p.id, 'doc', i.doc) order by i.issued_at desc), '[]'::jsonb)
          from (select * from public.platform_invoices where p_property is null or property_id = p_property order by issued_at desc limit 300) i
          join public.properties p on p.id = i.property_id);
end $$;

-- Admin: create invoices for payments approved before this update
create or replace function public.admin_backfill_invoices() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  perform public._assert_platform_admin();
  for r in select sp.id from public.subscription_payments sp left join public.platform_invoices i on i.payment_id = sp.id
            where sp.status = 'approved' and i.id is null order by sp.reviewed_at loop
    perform public._issue_platform_invoice(r.id); n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- reminders
create table if not exists public.billing_reminders (
  id               uuid primary key default gen_random_uuid(),
  property_id      uuid not null references public.properties(id) on delete cascade,
  kind             text not null check (kind in ('trial_3d','trial_1d','trial_ended','renew_7d','renew_1d','expired')),
  ends_at          timestamptz not null,
  created_at       timestamptz not null default now(),
  emailed_at       timestamptz,
  whatsapp_done_at timestamptz,
  unique (property_id, kind, ends_at)
);
create index if not exists billing_reminders_todo on public.billing_reminders (created_at desc);
alter table public.billing_reminders enable row level security;
revoke all on public.billing_reminders from anon, authenticated;

create or replace function public._reminder_text(p_kind text, p_ends timestamptz) returns jsonb
language sql immutable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'title', case p_kind when 'trial_3d' then 'Your free trial ends in 3 days' when 'trial_1d' then 'Your free trial ends tomorrow'
             when 'trial_ended' then 'Your free trial has ended' when 'renew_7d' then 'Your NammaStay plan renews in 7 days'
             when 'renew_1d' then 'Your NammaStay plan ends tomorrow' else 'Your NammaStay plan has ended' end,
    'body', case when p_kind in ('trial_ended','expired') then 'Choose a plan in Settings → Billing to keep using NammaStay.'
             else 'Ends ' || to_char(p_ends at time zone 'Asia/Kolkata', 'DD Mon YYYY') || ' — Settings → Billing to choose a plan.' end)
$$;

-- Creates today's reminders (once each) + in-app notifications. Safe to run many times a day.
create or replace function public.run_billing_reminders() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_kind text; v_days int; v_id uuid; n int := 0; v_txt jsonb;
begin
  if auth.uid() is not null then perform public._assert_platform_admin(); end if;      -- cron (no user) or an admin
  for r in
    select s.property_id, s.trial_ends_at, s.paid_until,
           (s.paid_until is not null and s.paid_until >= s.trial_ends_at) as paid,
           greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at)) as ends_at
      from public.subscriptions s
     where not s.is_complimentary and not coalesce(s.is_suspended, false)
  loop
    v_days := (r.ends_at at time zone 'Asia/Kolkata')::date - (now() at time zone 'Asia/Kolkata')::date;
    v_kind := case
      when not r.paid and v_days between 2 and 3 then 'trial_3d'
      when not r.paid and v_days between 0 and 1 and r.ends_at > now() then 'trial_1d'
      when not r.paid and r.ends_at <= now() and v_days >= -6 then 'trial_ended'
      when r.paid and v_days between 4 and 7 then 'renew_7d'
      when r.paid and v_days between 0 and 1 and r.ends_at > now() then 'renew_1d'
      when r.paid and r.ends_at <= now() and v_days >= -6 then 'expired'
    end;
    continue when v_kind is null;
    insert into public.billing_reminders (property_id, kind, ends_at) values (r.property_id, v_kind, r.ends_at)
    on conflict (property_id, kind, ends_at) do nothing returning id into v_id;
    if v_id is not null then
      v_txt := public._reminder_text(v_kind, r.ends_at);
      insert into public.notifications (property_id, kind, title, body) values (r.property_id, 'subscription', v_txt->>'title', v_txt->>'body');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Admin: reminders to follow up (WhatsApp) — newest first
create or replace function public.admin_reminders(p_all boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', b.id, 'kind', b.kind, 'ends_at', b.ends_at, 'created_at', b.created_at, 'emailed_at', b.emailed_at,
             'whatsapp_done_at', b.whatsapp_done_at, 'property_id', p.id, 'property', p.name, 'city', p.city, 'phone', p.phone,
             'owner', (select coalesce(m.display_name, m.email) from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
             'email', (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
             'text', public._reminder_text(b.kind, b.ends_at)) x
      from public.billing_reminders b join public.properties p on p.id = b.property_id
     where p_all or (b.whatsapp_done_at is null and b.created_at > now() - interval '10 days')
     order by b.created_at desc limit 200) q);
end $$;

create or replace function public.admin_mark_reminder(p_id uuid, p_done boolean default true) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  update public.billing_reminders set whatsapp_done_at = case when p_done then now() end where id = p_id;
end $$;

-- Server only (billing-reminders edge function): reminders still to email, and mark them sent
create or replace function public.reminders_to_email() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'kind', b.kind, 'ends_at', b.ends_at, 'property', p.name,
           'email', m.email, 'name', coalesce(m.display_name, 'there'), 'text', public._reminder_text(b.kind, b.ends_at))), '[]'::jsonb)
    from public.billing_reminders b join public.properties p on p.id = b.property_id
    join lateral (select email, display_name from public.property_members where property_id = p.id and role = 'owner' and email is not null order by created_at limit 1) m on true
   where b.emailed_at is null and b.created_at > now() - interval '3 days'
$$;
create or replace function public.mark_reminders_emailed(p_ids uuid[]) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.billing_reminders set emailed_at = now() where id = any (p_ids)
$$;

-- ---------------------------------------------------------------- owner billing info now includes billing details
create or replace function public.my_billing_details(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select jsonb_build_object('bill_name', bill_name, 'bill_gstin', bill_gstin, 'bill_address', bill_address, 'bill_state', bill_state, 'name', name)
            from public.properties where id = p_property);
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public.set_billing_details(uuid, jsonb), public.admin_invoice_settings(), public.admin_save_invoice_settings(jsonb),
  public._issue_platform_invoice(uuid), public._on_sub_payment_approved(), public.my_platform_invoices(uuid), public.admin_platform_invoices(uuid),
  public.admin_backfill_invoices(), public._reminder_text(text, timestamptz), public.run_billing_reminders(), public.admin_reminders(boolean),
  public.admin_mark_reminder(uuid, boolean), public.reminders_to_email(), public.mark_reminders_emailed(uuid[]), public.my_billing_details(uuid)
  from public, anon, authenticated;
grant execute on function public.set_billing_details(uuid, jsonb), public.admin_invoice_settings(), public.admin_save_invoice_settings(jsonb),
  public.my_platform_invoices(uuid), public.admin_platform_invoices(uuid), public.admin_backfill_invoices(), public.run_billing_reminders(),
  public.admin_reminders(boolean), public.admin_mark_reminder(uuid, boolean), public.my_billing_details(uuid) to authenticated;
grant execute on function public.run_billing_reminders(), public.reminders_to_email(), public.mark_reminders_emailed(uuid[]) to service_role;
