-- =====================================================================
-- LEGACY BUNDLE: contains migrations only through 028_onboarding.
-- For a current install, apply supabase/migrations/*.sql in numeric order instead.
-- Then run supabase/setup/004_seed.sql (your hostel + owner) and any optional schedules.
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
  upi_id        text check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,255}@[A-Za-z]{2,64}$'),
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
  upi_id      text check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,255}@[A-Za-z]{2,64}$'),
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
-- The admin website (thenammastay.com/admin-login.html) uses 2-step login: password
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


-- >>>>>>>>>>>>>>>>>>>> 024_form_c.sql
-- =====================================================================
-- NammaStay · 024_form_c.sql — Form C (FRRO arrival / departure report)
-- Every foreign guest must be reported on Form C at indianfrro.gov.in
-- within 24 hours of arrival (and a departure report after check-out).
-- NammaStay keeps the passport & visa details, shows each foreign guest's
-- deadline, prepares the details in the portal's order to copy, and records
-- the FRRO number once you submit. Submission itself happens on the FRRO
-- portal (it has a captcha; there is no official API).
-- Run AFTER 023_platform_invoices_reminders.sql.
-- =====================================================================

-- Passport, visa and travel details for foreign guests (kept apart from the main guest record)
create table if not exists public.guest_foreign (
  guest_id          uuid primary key,
  property_id       uuid not null,
  gender            text check (gender in ('male','female','other')),
  passport_no       text check (char_length(passport_no) <= 30),
  passport_place    text check (char_length(passport_place) <= 80),
  passport_issued   date,
  passport_expiry   date,
  visa_no           text check (char_length(visa_no) <= 40),
  visa_type         text check (char_length(visa_type) <= 40),
  visa_subtype      text check (char_length(visa_subtype) <= 60),
  visa_place        text check (char_length(visa_place) <= 80),
  visa_issued       date,
  visa_expiry       date,
  arrived_india_on  date,
  arrived_from      text check (char_length(arrived_from) <= 80),   -- port / city of arrival in India
  next_destination  text check (char_length(next_destination) <= 120),
  purpose           text check (char_length(purpose) <= 60),
  home_address      text check (char_length(home_address) <= 300),
  contact_india     text check (char_length(contact_india) <= 40),
  updated_at        timestamptz not null default now(),
  foreign key (guest_id, property_id) references public.guests(id, property_id) on delete cascade
);

-- Submissions (one arrival + one departure report per stay)
create table if not exists public.form_c (
  booking_id      uuid primary key,
  property_id     uuid not null,
  arrival_ref     text check (char_length(arrival_ref) <= 60),
  arrival_at      timestamptz,
  arrival_by      uuid,
  departure_ref   text check (char_length(departure_ref) <= 60),
  departure_at    timestamptz,
  departure_by    uuid,
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);

alter table public.guest_foreign enable row level security;
alter table public.form_c enable row level security;
drop policy if exists guest_foreign_select on public.guest_foreign;
create policy guest_foreign_select on public.guest_foreign for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])));
drop policy if exists form_c_select on public.form_c;
create policy form_c_select on public.form_c for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[])));
revoke all on public.guest_foreign, public.form_c from anon, authenticated;
grant select on public.guest_foreign, public.form_c to authenticated;

create or replace function public._is_foreign(p_nationality text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select coalesce(nullif(btrim(p_nationality), ''), 'India') !~* '^(india|indian)$'
$$;

-- Foreign guests' stays: pending arrival reports first. p_days: how far back to look.
create or replace function public.formc_list(p_property uuid, p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return (select coalesce(jsonb_agg(x order by (x->>'sort')::int, x->>'deadline'), '[]'::jsonb) from (
    select jsonb_build_object(
      'booking_id', b.id, 'code', b.code, 'status', b.status, 'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at,
      'arrived_at', coalesce(b.arrived_at, b.check_in_at), 'deadline', coalesce(b.arrived_at, b.check_in_at) + interval '24 hours',
      'departed_at', b.departed_at, 'room', r.name, 'bed', bd.label,
      'guest', jsonb_build_object('id', g.id, 'full_name', g.full_name, 'nationality', g.nationality, 'dob', g.dob, 'phone', g.phone, 'email', g.email,
                                  'id_type', g.id_type, 'id_number', g.id_number, 'id_doc_path', g.id_doc_path, 'id_doc_back_path', g.id_doc_back_path),
      'foreign', to_jsonb(f) - 'property_id' - 'guest_id' - 'updated_at',
      'arrival_ref', c.arrival_ref, 'arrival_at', c.arrival_at, 'departure_ref', c.departure_ref, 'departure_at', c.departure_at,
      'sort', case when c.arrival_at is null and b.status = 'checked_in' then 0
                   when c.arrival_at is not null and c.departure_at is null and b.status = 'checked_out' then 1
                   when c.arrival_at is null and b.status in ('pending','confirmed') then 2 else 3 end) x
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
    left join public.guest_foreign f on f.guest_id = g.id
    left join public.form_c c on c.booking_id = b.id
   where b.property_id = p_property and public._is_foreign(g.nationality)
     and b.status in ('pending','confirmed','checked_in','checked_out')
     and b.check_out_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)))
     and b.check_in_at < now() + interval '2 days') q);
end $$;

-- Save passport / visa details (staff)
create or replace function public.formc_save_details(p_guest uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid; d text;
begin
  select property_id into v_prop from public.guests where id = p_guest;
  if v_prop is null then raise exception 'Guest not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  foreach d in array array['passport_issued','passport_expiry','visa_issued','visa_expiry','arrived_india_on'] loop
    if nullif(p->>d, '') is not null and (p->>d) !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Check the date format.'; end if;
  end loop;
  insert into public.guest_foreign as f (guest_id, property_id, gender, passport_no, passport_place, passport_issued, passport_expiry, visa_no, visa_type,
     visa_subtype, visa_place, visa_issued, visa_expiry, arrived_india_on, arrived_from, next_destination, purpose, home_address, contact_india, updated_at)
  values (p_guest, v_prop, nullif(p->>'gender', ''), nullif(upper(btrim(coalesce(p->>'passport_no', ''))), ''), nullif(btrim(coalesce(p->>'passport_place', '')), ''),
     nullif(p->>'passport_issued', '')::date, nullif(p->>'passport_expiry', '')::date, nullif(upper(btrim(coalesce(p->>'visa_no', ''))), ''),
     nullif(btrim(coalesce(p->>'visa_type', '')), ''), nullif(btrim(coalesce(p->>'visa_subtype', '')), ''), nullif(btrim(coalesce(p->>'visa_place', '')), ''),
     nullif(p->>'visa_issued', '')::date, nullif(p->>'visa_expiry', '')::date, nullif(p->>'arrived_india_on', '')::date,
     nullif(btrim(coalesce(p->>'arrived_from', '')), ''), nullif(btrim(coalesce(p->>'next_destination', '')), ''), nullif(btrim(coalesce(p->>'purpose', '')), ''),
     nullif(btrim(coalesce(p->>'home_address', '')), ''), nullif(btrim(coalesce(p->>'contact_india', '')), ''), now())
  on conflict (guest_id) do update set gender = excluded.gender, passport_no = excluded.passport_no, passport_place = excluded.passport_place,
     passport_issued = excluded.passport_issued, passport_expiry = excluded.passport_expiry, visa_no = excluded.visa_no, visa_type = excluded.visa_type,
     visa_subtype = excluded.visa_subtype, visa_place = excluded.visa_place, visa_issued = excluded.visa_issued, visa_expiry = excluded.visa_expiry,
     arrived_india_on = excluded.arrived_india_on, arrived_from = excluded.arrived_from, next_destination = excluded.next_destination,
     purpose = excluded.purpose, home_address = excluded.home_address, contact_india = excluded.contact_india, updated_at = now();
  -- keep the passport number on the guest record too (ID type passport)
  if nullif(btrim(coalesce(p->>'passport_no', '')), '') is not null then
    update public.guests set id_type = 'passport', id_number = upper(btrim(p->>'passport_no')) where id = p_guest and (id_type is null or id_type = 'passport');
  end if;
end $$;

-- Record a submission. p_kind: 'arrival' | 'departure'. Empty p_ref clears it (undo).
create or replace function public.formc_mark(p_booking uuid, p_kind text, p_ref text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings%rowtype; v_ref text := nullif(btrim(coalesce(p_ref, '')), '');
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if p_kind not in ('arrival','departure') then raise exception 'Unknown report.'; end if;
  insert into public.form_c (booking_id, property_id) values (b.id, b.property_id) on conflict (booking_id) do nothing;
  if p_kind = 'arrival' then
    update public.form_c set arrival_ref = v_ref, arrival_at = case when v_ref is null then null else now() end,
           arrival_by = case when v_ref is null then null else auth.uid() end where booking_id = b.id;
  else
    update public.form_c set departure_ref = v_ref, departure_at = case when v_ref is null then null else now() end,
           departure_by = case when v_ref is null then null else auth.uid() end where booking_id = b.id;
  end if;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'form_c', jsonb_build_object('kind', p_kind, 'ref', v_ref), auth.uid());
end $$;

-- How many arrival reports are due (for the dashboard)
create or replace function public.formc_due_count(p_property uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from public.bookings b join public.guests g on g.id = b.guest_id left join public.form_c c on c.booking_id = b.id
   where b.property_id = p_property and b.status = 'checked_in' and public._is_foreign(g.nationality) and c.arrival_at is null
     and p_property in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[]))
$$;

revoke execute on function public._is_foreign(text), public.formc_list(uuid, int), public.formc_save_details(uuid, jsonb),
  public.formc_mark(uuid, text, text), public.formc_due_count(uuid) from public, anon, authenticated;
grant execute on function public.formc_list(uuid, int), public.formc_save_details(uuid, jsonb), public.formc_mark(uuid, text, text),
  public.formc_due_count(uuid) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 025_admin_growth.sql
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


-- >>>>>>>>>>>>>>>>>>>> 026_pricing_housekeeping.sql
-- =====================================================================
-- NammaStay · 026_pricing_housekeeping.sql
--   1. Seasonal & weekend pricing — price rules per property:
--        weekend (e.g. Fri + Sat nights +20%), season / dates
--        (e.g. 20 Dec – 5 Jan +30%, or a fixed ₹1,200), optional rooms,
--        optional minimum stay. Applied automatically when a booking is
--        made or its dates / bed change; the stay's nightly rate becomes
--        the average of its nights, so every total, invoice and discount
--        stays consistent. Rates shown while booking include the rules.
--   2. Housekeeping board — each bed/room is Clean / Dirty / Cleaning /
--        Inspect; check-out marks it Dirty automatically.
-- Run AFTER 025_admin_growth.sql.
-- =====================================================================

-- ---------------------------------------------------------------- 1. price rules
create table if not exists public.rate_rules (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 60),
  kind        text not null check (kind in ('weekend','season')),
  weekdays    smallint[] check (weekdays is null or weekdays <@ array[0,1,2,3,4,5,6]::smallint[]),   -- nights: 0 = Sunday … 6 = Saturday
  date_from   date,
  date_to     date,                                               -- last night included
  adjust      text not null check (adjust in ('percent','amount','fixed')),
  value       int  not null,                                      -- percent (-90…300) · ₹ in paise (+/-) · fixed price in paise
  room_ids    uuid[],                                             -- null = all rooms
  min_nights  smallint check (min_nights is null or min_nights between 2 and 30),
  priority    smallint not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  check (kind <> 'weekend' or (weekdays is not null and cardinality(weekdays) > 0)),
  check (kind <> 'season' or (date_from is not null and date_to is not null and date_to >= date_from)),
  check (adjust <> 'percent' or value between -90 and 300),
  check (adjust <> 'fixed' or value > 0)
);
create index if not exists rate_rules_prop on public.rate_rules (property_id) where is_active;
alter table public.rate_rules enable row level security;
drop policy if exists rate_rules_select on public.rate_rules;
create policy rate_rules_select on public.rate_rules for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.rate_rules from anon, authenticated;
grant select on public.rate_rules to authenticated;

-- The price of one night (property local date) for a bed/room with base rate p_base
create or replace function public._night_rate(p_property uuid, p_room uuid, p_base int, p_day date) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(0, coalesce((
    select case r.adjust when 'percent' then round(p_base * (100 + r.value) / 100.0)::int when 'amount' then p_base + r.value else r.value end
      from public.rate_rules r
     where r.property_id = p_property and r.is_active and (r.room_ids is null or p_room = any (r.room_ids))
       and ((r.kind = 'weekend' and extract(dow from p_day)::smallint = any (r.weekdays))
         or (r.kind = 'season' and p_day between r.date_from and r.date_to
             and (r.weekdays is null or extract(dow from p_day)::smallint = any (r.weekdays))))
     order by (r.kind = 'season') desc, r.priority desc, r.created_at desc limit 1), p_base))
$$;

-- Average nightly rate for a stay (rounded to the paise) and the longest minimum-stay rule it touches
create or replace function public._stay_rate(p_bed uuid, p_in timestamptz, p_out timestamptz, p_base int default null)
returns table (rate_paise int, min_nights int, rule_names text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare bd public.beds%rowtype; tz text; d0 date; d1 date; n int; total bigint := 0; d date; base int;
begin
  select * into bd from public.beds where id = p_bed;
  select timezone into tz from public.properties where id = bd.property_id;
  base := coalesce(p_base, bd.rate_paise);
  d0 := (p_in at time zone tz)::date; d1 := (p_out at time zone tz)::date;
  if d1 <= d0 then d1 := d0 + 1; end if;
  n := d1 - d0;
  for d in select generate_series(d0, d1 - 1, interval '1 day')::date loop
    total := total + public._night_rate(bd.property_id, bd.room_id, base, d);
  end loop;
  return query select round(total::numeric / n)::int,
    coalesce((select max(r.min_nights) from public.rate_rules r
               where r.property_id = bd.property_id and r.is_active and r.min_nights is not null
                 and (r.room_ids is null or bd.room_id = any (r.room_ids))
                 and ((r.kind = 'season' and r.date_from <= d1 - 1 and r.date_to >= d0)
                   or (r.kind = 'weekend' and exists (select 1 from generate_series(d0, d1 - 1, interval '1 day') g
                                                        where extract(dow from g)::smallint = any (r.weekdays))))), 0)::int,
    (select string_agg(distinct r.name, ', ') from public.rate_rules r
      where r.property_id = bd.property_id and r.is_active and (r.room_ids is null or bd.room_id = any (r.room_ids))
        and exists (select 1 from generate_series(d0, d1 - 1, interval '1 day') g
                     where (r.kind = 'weekend' and extract(dow from g)::smallint = any (r.weekdays))
                        or (r.kind = 'season' and g::date between r.date_from and r.date_to)));
end $$;

-- Apply the rules to bookings (new bookings; date or bed changes)
create or replace function public._apply_rate_rules() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare s record; base int;
begin
  if new.status not in ('pending','confirmed','checked_in') then return new; end if;
  if not exists (select 1 from public.rate_rules where property_id = new.property_id and is_active) then return new; end if;
  if tg_op = 'UPDATE' then
    if (new.check_in_at, new.check_out_at, new.bed_id) is not distinct from (old.check_in_at, old.check_out_at, old.bed_id) then return new; end if;
  end if;
  select rate_paise into base from public.beds where id = new.bed_id;
  select * into s from public._stay_rate(new.bed_id, new.check_in_at, new.check_out_at, base);
  if tg_op = 'INSERT' and s.min_nights > 0 and new.nights < s.min_nights then
    raise exception 'Minimum stay is % nights for these dates (%).', s.min_nights, s.rule_names;
  end if;
  if s.rate_paise is distinct from new.rate_paise then
    new.rate_paise := s.rate_paise;
    new.discount_paise := round(new.nights * (new.rate_paise + coalesce(new.extra_paise, 0)) * coalesce(new.discount_pct, 0) / 100.0);
    new.total_paise := new.nights * (new.rate_paise + coalesce(new.extra_paise, 0)) - new.discount_paise + coalesce(new.charges_paise, 0);
    if tg_op = 'UPDATE' and new.total_paise < new.paid_paise then
      raise exception 'With the price rules for these dates the stay would cost less than what was already paid. Refund the difference first.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bookings_rate_rules on public.bookings;
create trigger bookings_rate_rules before insert or update of check_in_at, check_out_at, bed_id on public.bookings
  for each row execute function public._apply_rate_rules();

-- Rooms shown while booking: price for these dates (rules included)
create or replace function public.available_beds(p_property uuid, p_in timestamptz, p_out timestamptz)
returns table (id uuid, label text, room_id uuid, room_name text, rate_paise int,
               max_guests smallint, base_guests smallint, extra_guest_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query
  select bd.id, bd.label, r.id, r.name, (select s.rate_paise from public._stay_rate(bd.id, p_in, p_out, bd.rate_paise) s),
         bd.max_guests, bd.base_guests, bd.extra_guest_paise
    from public.beds bd join public.rooms r on r.id = bd.room_id
   where bd.property_id = p_property and bd.is_active
     and not exists (select 1 from public.bookings b where b.bed_id = bd.id
                      and b.status in ('pending','confirmed','checked_in')
                      and b.stay && tstzrange(p_in, p_out, '[)'))
     and not exists (select 1 from public.bed_blocks k where k.bed_id = bd.id
                      and k.period && tstzrange(p_in, p_out, '[)'))
   order by r.sort, r.name, bd.sort, bd.label;
end $$;

-- p: { id?, name, kind, weekdays[], date_from, date_to, adjust, value (percent number or rupees), room_ids[], min_nights, priority, is_active }
create or replace function public.rate_rule_save(p_property uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_adj text := coalesce(p->>'adjust', 'percent'); v_val numeric := nullif(p->>'value', '')::numeric; v_kind text := coalesce(p->>'kind', 'weekend');
  v_days smallint[] := case when jsonb_typeof(p->'weekdays') = 'array' and jsonb_array_length(p->'weekdays') > 0 then array(select (x)::smallint from jsonb_array_elements_text(p->'weekdays') x) end;
  v_rooms uuid[] := case when jsonb_typeof(p->'room_ids') = 'array' and jsonb_array_length(p->'room_ids') > 0 then array(select (x)::uuid from jsonb_array_elements_text(p->'room_ids') x) end;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._require_perm(p_property, 'manage_rooms');
  if v_val is null then raise exception 'Enter the price change.'; end if;
  if v_kind = 'weekend' and v_days is null then raise exception 'Pick at least one night of the week.'; end if;
  if v_kind = 'season' and (nullif(p->>'date_from', '') is null or nullif(p->>'date_to', '') is null) then raise exception 'Pick the first and last night.'; end if;
  if v_rooms is not null and exists (select 1 from unnest(v_rooms) x where x not in (select id from public.rooms where property_id = p_property)) then raise exception 'Unknown room.'; end if;
  v_val := case v_adj when 'percent' then round(v_val) else round(v_val * 100) end;      -- ₹ → paise
  if nullif(p->>'id', '') is null then
    insert into public.rate_rules (property_id, name, kind, weekdays, date_from, date_to, adjust, value, room_ids, min_nights, priority, is_active)
    values (p_property, btrim(p->>'name'), v_kind, v_days, nullif(p->>'date_from', '')::date, nullif(p->>'date_to', '')::date, v_adj, v_val::int, v_rooms,
            nullif(p->>'min_nights', '')::smallint, coalesce(nullif(p->>'priority', '')::smallint, 0), coalesce((p->>'is_active')::boolean, true))
    returning id into v_id;
  else
    update public.rate_rules set name = btrim(p->>'name'), kind = v_kind, weekdays = v_days, date_from = nullif(p->>'date_from', '')::date,
           date_to = nullif(p->>'date_to', '')::date, adjust = v_adj, value = v_val::int, room_ids = v_rooms, min_nights = nullif(p->>'min_nights', '')::smallint,
           priority = coalesce(nullif(p->>'priority', '')::smallint, 0), is_active = coalesce((p->>'is_active')::boolean, true)
     where id = (p->>'id')::uuid and property_id = p_property returning id into v_id;
    if v_id is null then raise exception 'Price rule not found.'; end if;
  end if;
  return v_id;
exception when check_violation then raise exception 'Check the price rule — percent between -90 and 300, a fixed price above ₹0, the last night after the first.';
end $$;

create or replace function public.rate_rule_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.rate_rules where id = p_id;
  if v_prop is null then raise exception 'Price rule not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  perform public._require_perm(v_prop, 'manage_rooms');
  delete from public.rate_rules where id = p_id;
end $$;

-- Preview: what one bed/room costs per night for the next p_days nights
create or replace function public.rate_preview(p_bed uuid, p_from date, p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare bd public.beds%rowtype;
begin
  select * into bd from public.beds where id = p_bed;
  if not found then raise exception 'Bed not found.'; end if;
  perform public._assert_role(bd.property_id, array['owner','manager','front_desk']::public.member_role[]);
  return (select jsonb_agg(jsonb_build_object('day', d::date, 'rate_paise', public._night_rate(bd.property_id, bd.room_id, bd.rate_paise, d::date)) order by d)
            from generate_series(p_from, p_from + least(greatest(coalesce(p_days, 14), 1), 62) - 1, interval '1 day') d);
end $$;

-- ---------------------------------------------------------------- 2. housekeeping
alter table public.beds
  add column if not exists hk_status text not null default 'clean' check (hk_status in ('clean','dirty','cleaning','inspect')),
  add column if not exists hk_note text check (char_length(hk_note) <= 200),
  add column if not exists hk_updated_at timestamptz,
  add column if not exists hk_by uuid;

create or replace function public._hk_on_checkout() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'checked_out' and old.status is distinct from 'checked_out' then
    update public.beds set hk_status = 'dirty', hk_note = null, hk_updated_at = now(), hk_by = auth.uid() where id = new.bed_id;
  end if;
  return new;
end $$;
drop trigger if exists bookings_hk_checkout on public.bookings;
create trigger bookings_hk_checkout after update of status on public.bookings for each row execute function public._hk_on_checkout();

create or replace function public.hk_board(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare tz text; today date;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  select timezone into tz from public.properties where id = p_property;
  today := (now() at time zone tz)::date;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', bd.id, 'label', bd.label, 'room', r.name, 'room_id', r.id, 'status', bd.hk_status, 'note', bd.hk_note, 'updated_at', bd.hk_updated_at,
      'updated_by', (select coalesce(m.display_name, m.email) from public.property_members m where m.property_id = p_property and m.user_id = bd.hk_by),
      'in_house', (select jsonb_build_object('guest', g.full_name, 'out', b.check_out_at, 'leaving_today', (b.check_out_at at time zone tz)::date = today)
                     from public.bookings b join public.guests g on g.id = b.guest_id
                    where b.bed_id = bd.id and b.status = 'checked_in' order by b.check_in_at desc limit 1),
      'arriving', (select jsonb_build_object('guest', g.full_name, 'at', b.check_in_at)
                     from public.bookings b join public.guests g on g.id = b.guest_id
                    where b.bed_id = bd.id and b.status in ('pending','confirmed') and (b.check_in_at at time zone tz)::date = today
                    order by b.check_in_at limit 1),
      'blocked', exists (select 1 from public.bed_blocks k where k.bed_id = bd.id and k.period @> now()))
    order by r.sort, r.name, bd.sort, bd.label), '[]'::jsonb)
    from public.beds bd join public.rooms r on r.id = bd.room_id where bd.property_id = p_property and bd.is_active);
end $$;

create or replace function public.hk_set(p_bed uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.beds where id = p_bed;
  if v_prop is null then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  if p_status not in ('clean','dirty','cleaning','inspect') then raise exception 'Unknown status.'; end if;
  update public.beds set hk_status = p_status, hk_note = nullif(left(btrim(coalesce(p_note, '')), 200), ''), hk_updated_at = now(), hk_by = auth.uid() where id = p_bed;
end $$;

create or replace function public.hk_counts(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('dirty', count(*) filter (where hk_status = 'dirty'), 'cleaning', count(*) filter (where hk_status = 'cleaning'),
                            'inspect', count(*) filter (where hk_status = 'inspect'))
    from public.beds where property_id = p_property and is_active
     and p_property in (select public.my_property_ids())
$$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public._night_rate(uuid, uuid, int, date), public._stay_rate(uuid, timestamptz, timestamptz, int), public._apply_rate_rules(),
  public.rate_rule_save(uuid, jsonb), public.rate_rule_delete(uuid), public.rate_preview(uuid, date, int), public._hk_on_checkout(),
  public.hk_board(uuid), public.hk_set(uuid, text, text), public.hk_counts(uuid) from public, anon, authenticated;
grant execute on function public.rate_rule_save(uuid, jsonb), public.rate_rule_delete(uuid), public.rate_preview(uuid, date, int),
  public.hk_board(uuid), public.hk_set(uuid, text, text), public.hk_counts(uuid) to authenticated;
revoke execute on function public.available_beds(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.available_beds(uuid, timestamptz, timestamptz) to authenticated;


-- >>>>>>>>>>>>>>>>>>>> 027_channex.sql
-- =====================================================================
-- NammaStay · 027_channex.sql — two-way channel manager (Channex)
--   NammaStay → OTAs : availability (free beds/rooms per night), prices
--                      (incl. seasonal & weekend rules) and minimum stays
--   OTAs → NammaStay : bookings (new / modified / cancelled) with guest
--                      name, phone, email, amount and OTA reference
-- Through Channex (white-label channel manager API): Booking.com, Agoda,
-- Expedia, Airbnb, MakeMyTrip/Goibibo, Hostelworld, Yatra, Trip.com…
-- Each NammaStay room + price group (e.g. "6-Bed Dorm · ₹700" = 3 beds)
-- becomes one Channex room type (dorm for hostels) with one rate plan.
-- The `channex` edge function does the talking (secrets CHANNEX_API_KEY,
-- CHANNEX_URL = https://staging.channex.io while testing).
-- Run AFTER 026_pricing_housekeeping.sql.
-- =====================================================================

create table if not exists public.channex_links (
  property_id     uuid primary key references public.properties(id) on delete cascade,
  cx_property_id  text,
  enabled         boolean not null default true,
  dirty_at        timestamptz not null default now(),
  last_push_at    timestamptz,
  last_pull_at    timestamptz,
  last_error      text check (char_length(last_error) <= 500),
  created_at      timestamptz not null default now()
);
create table if not exists public.channex_room_map (
  property_id      uuid not null references public.properties(id) on delete cascade,
  group_key        text not null,                  -- room_id:rate_paise
  room_id          uuid not null,
  rate_paise       int  not null,
  title            text not null,
  bed_ids          uuid[] not null,
  cx_room_type_id  text,
  cx_rate_plan_id  text,
  primary key (property_id, group_key)
);
create table if not exists public.channex_bookings (
  cx_booking_id   text primary key,
  property_id     uuid not null references public.properties(id) on delete cascade,
  unique_id       text,
  ota_name        text,
  ota_code        text,
  status          text,
  revision_id     text,
  booking_ids     uuid[] not null default '{}',
  amount          numeric(12,2),
  currency        text,
  arrival         date,
  departure       date,
  guest_name      text,
  problem         text check (char_length(problem) <= 300),
  raw             jsonb,
  received_at     timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists channex_bookings_prop on public.channex_bookings (property_id, received_at desc);

alter table public.channex_links enable row level security;
alter table public.channex_room_map enable row level security;
alter table public.channex_bookings enable row level security;
revoke all on public.channex_links, public.channex_room_map, public.channex_bookings from anon, authenticated;

-- ---------------------------------------------------------------- price rules must not touch OTA prices
create or replace function public._apply_rate_rules() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare s record; base int;
begin
  if coalesce(current_setting('nammastay.skip_rate_rules', true), '') = '1' then return new; end if;   -- OTA bookings keep the OTA price
  if new.status not in ('pending','confirmed','checked_in') then return new; end if;
  if not exists (select 1 from public.rate_rules where property_id = new.property_id and is_active) then return new; end if;
  if tg_op = 'UPDATE' then
    if (new.check_in_at, new.check_out_at, new.bed_id) is not distinct from (old.check_in_at, old.check_out_at, old.bed_id) then return new; end if;
    if old.source = 'ota' then return new; end if;
  end if;
  select rate_paise into base from public.beds where id = new.bed_id;
  select * into s from public._stay_rate(new.bed_id, new.check_in_at, new.check_out_at, base);
  if tg_op = 'INSERT' and s.min_nights > 0 and new.nights < s.min_nights then
    raise exception 'Minimum stay is % nights for these dates (%).', s.min_nights, s.rule_names;
  end if;
  if s.rate_paise is distinct from new.rate_paise then
    new.rate_paise := s.rate_paise;
    new.discount_paise := round(new.nights * (new.rate_paise + coalesce(new.extra_paise, 0)) * coalesce(new.discount_pct, 0) / 100.0);
    new.total_paise := new.nights * (new.rate_paise + coalesce(new.extra_paise, 0)) - new.discount_paise + coalesce(new.charges_paise, 0);
    if tg_op = 'UPDATE' and new.total_paise < new.paid_paise then
      raise exception 'With the price rules for these dates the stay would cost less than what was already paid. Refund the difference first.';
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- "something changed — push to Channex"
create or replace function public._cx_touch() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.channex_links set dirty_at = now()
   where property_id = coalesce(new.property_id, old.property_id) and enabled;
  return coalesce(new, old);
end $$;
do $$ declare t text; begin
  foreach t in array array['bookings','bed_blocks','rate_rules','beds'] loop
    execute format('drop trigger if exists cx_touch on public.%I', t);
    execute format('create trigger cx_touch after insert or update or delete on public.%I for each row execute function public._cx_touch()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- groups (room + price) → Channex room types
create or replace function public.cx_groups(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(g order by g->>'sort', g->>'title'), '[]'::jsonb) from (
    select jsonb_build_object(
      'group_key', r.id || ':' || bd.rate_paise, 'room_id', r.id, 'rate_paise', bd.rate_paise,
      'title', r.name || case when (select count(distinct b2.rate_paise) from public.beds b2 where b2.room_id = r.id and b2.is_active) > 1
                              then ' · ₹' || to_char(bd.rate_paise / 100.0, 'FM99,99,990') else '' end,
      'bed_ids', jsonb_agg(bd.id order by bd.sort, bd.label), 'count', count(*),
      'room_kind', case when p.kind = 'hostel' then 'dorm' else 'room' end,
      'capacity', (select count(*) from public.beds b3 where b3.room_id = r.id and b3.is_active),
      'occ_adults', greatest(1, max(coalesce(bd.max_guests, 1))), 'default_occupancy', greatest(1, max(coalesce(bd.base_guests, 1))),
      'sort', lpad(r.sort::text, 5, '0')) g
    from public.beds bd join public.rooms r on r.id = bd.room_id join public.properties p on p.id = bd.property_id
   where bd.property_id = p_property and bd.is_active
   group by r.id, r.name, r.sort, bd.rate_paise, p.kind) x
$$;

-- Availability, price and minimum stay per mapped group and night (for pushing to Channex)
create or replace function public.cx_ari(p_property uuid, p_days int default 365) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p public.properties%rowtype; d0 date;
begin
  select * into p from public.properties where id = p_property;
  d0 := (now() at time zone p.timezone)::date;
  return (select coalesce(jsonb_agg(jsonb_build_object('room_type_id', m.cx_room_type_id, 'rate_plan_id', m.cx_rate_plan_id, 'date', d::date,
      'availability', (select count(*) from unnest(m.bed_ids) bid
                        where exists (select 1 from public.beds b where b.id = bid and b.is_active)
                          and not exists (select 1 from public.bookings k where k.bed_id = bid and k.status in ('pending','confirmed','checked_in')
                                           and k.stay && tstzrange(((d::date)::timestamp + p.checkin_time) at time zone p.timezone,
                                                                   ((d::date + 1)::timestamp + p.checkout_time) at time zone p.timezone, '[)'))
                          and not exists (select 1 from public.bed_blocks z where z.bed_id = bid
                                           and z.period && tstzrange(((d::date)::timestamp + p.checkin_time) at time zone p.timezone,
                                                                     ((d::date + 1)::timestamp + p.checkout_time) at time zone p.timezone, '[)'))),
      'rate', public._night_rate(p_property, m.room_id, m.rate_paise, d::date),
      'min_stay', greatest(1, coalesce((select max(r.min_nights) from public.rate_rules r
                    where r.property_id = p_property and r.is_active and r.min_nights is not null and (r.room_ids is null or m.room_id = any (r.room_ids))
                      and ((r.kind = 'season' and d::date between r.date_from and r.date_to)
                        or (r.kind = 'weekend' and extract(dow from d)::smallint = any (r.weekdays)))), 1)))
      order by m.group_key, d), '[]'::jsonb)
    from public.channex_room_map m cross join generate_series(d0, d0 + least(greatest(coalesce(p_days, 365), 1), 500) - 1, interval '1 day') d
   where m.property_id = p_property and m.cx_room_type_id is not null and m.cx_rate_plan_id is not null);
end $$;

-- ---------------------------------------------------------------- OTA booking → NammaStay
-- p_rev: a Channex booking revision (attributes). Idempotent per revision.
create or replace function public.cx_import(p_property uuid, p_rev jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.properties%rowtype; v_cx text := coalesce(p_rev->>'booking_id', p_rev->>'id'); v_status text := p_rev->>'status';
  v_row public.channex_bookings%rowtype; v_ids uuid[] := '{}'; v_problem text; rm jsonb; m public.channex_room_map%rowtype;
  v_in timestamptz; v_out timestamptz; v_n int; v_bed uuid; v_guest uuid; v_total int; v_rate int; v_bk uuid; v_name text; v_phone text; v_mail text;
  v_ota text := coalesce(nullif(p_rev->>'secondary_ota', ''), p_rev->>'ota_name', 'OTA'); v_code text := p_rev->>'ota_reservation_code'; k record; v_note text;
begin
  select * into p from public.properties where id = p_property;
  select * into v_row from public.channex_bookings where cx_booking_id = v_cx for update;
  if found and v_row.revision_id = coalesce(p_rev->>'revision_id', p_rev->>'id') then return jsonb_build_object('duplicate', true); end if;

  -- cancel / replace earlier NammaStay bookings of this OTA booking
  if found and v_status in ('cancelled','modified') then
    for k in select * from public.bookings where id = any (v_row.booking_ids) loop
      if k.status in ('pending','confirmed') then
        update public.bookings set status = 'cancelled', cancelled_at = now(), note = left(concat_ws(E'\n', note, v_ota || ' ' || v_status), 2000) where id = k.id;
      elsif k.status = 'checked_in' then
        v_problem := format('%s %s booking %s, but the guest is already checked in — please adjust by hand.', v_ota, v_status, v_code);
        v_ids := v_ids || k.id;
      end if;
    end loop;
  end if;

  if v_status in ('new','modified') and v_problem is null then
    v_name := nullif(btrim(concat_ws(' ', p_rev->'customer'->>'name', p_rev->'customer'->>'surname')), '');
    if v_name is null or char_length(v_name) < 2 then v_name := v_ota || ' guest ' || coalesce(v_code, ''); end if;
    v_phone := regexp_replace(coalesce(p_rev->'customer'->>'phone', ''), '[^0-9+]', '', 'g');
    if v_phone !~ '^\+?[0-9]{8,15}$' then v_phone := null; end if;
    v_mail := nullif(btrim(coalesce(p_rev->'customer'->>'mail', '')), '');
    if v_mail is not null and v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_mail := null; end if;
    select id into v_guest from public.guests where property_id = p_property
       and ((v_mail is not null and lower(email) = lower(v_mail)) or (v_phone is not null and phone = v_phone)) order by created_at limit 1;
    if v_guest is null then
      insert into public.guests (property_id, full_name, phone, email, nationality)
      values (p_property, left(v_name, 120), v_phone, v_mail, nullif(p_rev->'customer'->>'country', '')) returning id into v_guest;
    end if;
    perform set_config('nammastay.skip_rate_rules', '1', true);
    for rm in select * from jsonb_array_elements(coalesce(p_rev->'rooms', '[]'::jsonb)) loop
      continue when coalesce((rm->>'is_cancelled')::boolean, false);
      select * into m from public.channex_room_map where property_id = p_property and cx_room_type_id = rm->>'room_type_id';
      if not found then v_problem := format('%s booking %s: room not mapped in NammaStay.', v_ota, v_code); continue; end if;
      v_in := ((rm->>'checkin_date')::date::timestamp + p.checkin_time) at time zone p.timezone;
      v_out := ((rm->>'checkout_date')::date::timestamp + p.checkout_time) at time zone p.timezone;
      v_n := greatest(1, (rm->>'checkout_date')::date - (rm->>'checkin_date')::date);
      select bid into v_bed from unnest(m.bed_ids) with ordinality u(bid, ord)
       where exists (select 1 from public.beds b where b.id = bid and b.is_active)
         and not exists (select 1 from public.bookings x where x.bed_id = bid and x.status in ('pending','confirmed','checked_in') and x.stay && tstzrange(v_in, v_out, '[)'))
         and not exists (select 1 from public.bed_blocks z where z.bed_id = bid and z.period && tstzrange(v_in, v_out, '[)'))
       order by ord limit 1;
      if v_bed is null then
        v_problem := format('%s booking %s (%s → %s): no free %s in %s — possible overbooking, please move a guest.',
                            v_ota, v_code, rm->>'checkin_date', rm->>'checkout_date', case when p.kind = 'hostel' then 'bed' else 'room' end, m.title);
        continue;
      end if;
      v_total := round(coalesce(nullif(rm->>'amount', '')::numeric, nullif(p_rev->>'amount', '')::numeric, 0) * 100);
      v_rate := round(v_total::numeric / v_n);
      v_note := left(concat_ws(E'\n', format('%s · %s', v_ota, v_code),
                  case when p_rev->>'payment_collect' = 'ota' then 'Paid to ' || v_ota || ' (collect nothing at the desk unless told otherwise)' end,
                  case when coalesce(p_rev->>'currency', 'INR') <> 'INR' then 'Amount in ' || (p_rev->>'currency') end,
                  nullif(p_rev->>'notes', '')), 2000);
      begin
        insert into public.bookings (property_id, guest_id, bed_id, visitors, check_in_at, check_out_at, nights, rate_paise, total_paise, status, source, note, created_by)
        values (p_property, v_guest, v_bed, least(greatest(coalesce((rm->'occupancy'->>'adults')::int, 1), 1), 20), v_in, v_out, v_n, v_rate, v_rate * v_n,
                'confirmed', 'ota', v_note, null)
        returning id into v_bk;
        v_ids := v_ids || v_bk;
      exception when exclusion_violation then
        v_problem := format('%s booking %s: the %s was just taken — please place it by hand.', v_ota, v_code, case when p.kind = 'hostel' then 'bed' else 'room' end);
      end;
    end loop;
    perform set_config('nammastay.skip_rate_rules', '', true);
  end if;

  insert into public.channex_bookings as c (cx_booking_id, property_id, unique_id, ota_name, ota_code, status, revision_id, booking_ids, amount, currency,
       arrival, departure, guest_name, problem, raw, updated_at)
  values (v_cx, p_property, p_rev->>'unique_id', v_ota, v_code, v_status, coalesce(p_rev->>'revision_id', p_rev->>'id'), v_ids,
          nullif(p_rev->>'amount', '')::numeric, p_rev->>'currency', nullif(p_rev->>'arrival_date', '')::date, nullif(p_rev->>'departure_date', '')::date,
          v_name, v_problem, p_rev - 'guarantee', now())
  on conflict (cx_booking_id) do update set status = excluded.status, revision_id = excluded.revision_id, booking_ids = excluded.booking_ids,
     amount = excluded.amount, arrival = excluded.arrival, departure = excluded.departure, guest_name = coalesce(excluded.guest_name, c.guest_name),
     problem = excluded.problem, raw = excluded.raw, updated_at = now();

  insert into public.notifications (property_id, kind, title, body, booking_id)
  values (p_property, case when v_problem is not null then 'ota_clash' else 'booking' end,
          case when v_problem is not null then '⚠ ' || v_ota || ' booking needs attention'
               when v_status = 'cancelled' then v_ota || ' booking cancelled' when v_status = 'modified' then v_ota || ' booking changed'
               else 'New ' || v_ota || ' booking' end,
          coalesce(v_problem, format('%s · %s → %s · %s', coalesce(v_name, v_row.guest_name, ''), p_rev->>'arrival_date', p_rev->>'departure_date', v_code)),
          v_ids[1]);
  return jsonb_build_object('booking_ids', v_ids, 'problem', v_problem);
end $$;

-- ---------------------------------------------------------------- server helpers (edge function, service role)
create or replace function public.cx_setup_data(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('property', jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'email', p.email, 'phone', p.phone,
           'address', p.address, 'city', p.city, 'timezone', p.timezone),
         'link', (select to_jsonb(l) from public.channex_links l where l.property_id = p.id),
         'maps', (select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from public.channex_room_map m where m.property_id = p.id),
         'groups', public.cx_groups(p.id))
    from public.properties p where p.id = p_property
$$;

create or replace function public.cx_save_setup(p_property uuid, p_cx_property text, p_maps jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g jsonb;
begin
  insert into public.channex_links (property_id, cx_property_id, enabled, dirty_at) values (p_property, p_cx_property, true, now())
  on conflict (property_id) do update set cx_property_id = excluded.cx_property_id, enabled = true, dirty_at = now(), last_error = null;
  for g in select * from jsonb_array_elements(coalesce(p_maps, '[]'::jsonb)) loop
    insert into public.channex_room_map (property_id, group_key, room_id, rate_paise, title, bed_ids, cx_room_type_id, cx_rate_plan_id)
    values (p_property, g->>'group_key', (g->>'room_id')::uuid, (g->>'rate_paise')::int, g->>'title',
            array(select (x)::uuid from jsonb_array_elements_text(g->'bed_ids') x), g->>'cx_room_type_id', g->>'cx_rate_plan_id')
    on conflict (property_id, group_key) do update set title = excluded.title, bed_ids = excluded.bed_ids,
       cx_room_type_id = coalesce(excluded.cx_room_type_id, public.channex_room_map.cx_room_type_id),
       cx_rate_plan_id = coalesce(excluded.cx_rate_plan_id, public.channex_room_map.cx_rate_plan_id);
  end loop;
end $$;

create or replace function public.cx_mark(p_property uuid, p_kind text, p_error text default null) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.channex_links set
    last_push_at = case when p_kind = 'push' and p_error is null then now() else last_push_at end,
    last_pull_at = case when p_kind = 'pull' and p_error is null then now() else last_pull_at end,
    last_error = left(p_error, 500)
  where property_id = p_property
$$;

create or replace function public.cx_links_due() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('property_id', l.property_id, 'cx_property_id', l.cx_property_id,
           'push', l.last_push_at is null or l.dirty_at > l.last_push_at or l.last_push_at < now() - interval '1 day')), '[]'::jsonb)
    from public.channex_links l
   where l.enabled and l.cx_property_id is not null and public._access_state(l.property_id) not in ('expired','suspended')
$$;

create or replace function public.cx_property_for(p_cx_property text) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select property_id from public.channex_links where cx_property_id = p_cx_property and enabled limit 1
$$;

-- ---------------------------------------------------------------- staff (owner / manager)
create or replace function public.cx_status(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return jsonb_build_object(
    'link', (select to_jsonb(l) from public.channex_links l where l.property_id = p_property),
    'maps', (select coalesce(jsonb_agg(jsonb_build_object('group_key', m.group_key, 'title', m.title, 'rate_paise', m.rate_paise, 'beds', cardinality(m.bed_ids),
               'cx_room_type_id', m.cx_room_type_id, 'cx_rate_plan_id', m.cx_rate_plan_id) order by m.title), '[]'::jsonb)
             from public.channex_room_map m where m.property_id = p_property),
    'groups', public.cx_groups(p_property),
    'bookings', (select coalesce(jsonb_agg(jsonb_build_object('cx_booking_id', c.cx_booking_id, 'ota', c.ota_name, 'code', c.ota_code, 'status', c.status,
               'guest', c.guest_name, 'arrival', c.arrival, 'departure', c.departure, 'amount', c.amount, 'currency', c.currency, 'problem', c.problem,
               'booking_ids', c.booking_ids, 'received_at', c.received_at) order by c.received_at desc), '[]'::jsonb)
             from (select * from public.channex_bookings where property_id = p_property order by received_at desc limit 30) c));
end $$;

create or replace function public.cx_set_enabled(p_property uuid, p_enabled boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  update public.channex_links set enabled = p_enabled, dirty_at = now() where property_id = p_property;
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public._cx_touch(), public.cx_groups(uuid), public.cx_ari(uuid, int), public.cx_import(uuid, jsonb), public.cx_setup_data(uuid),
  public.cx_save_setup(uuid, text, jsonb), public.cx_mark(uuid, text, text), public.cx_links_due(), public.cx_property_for(text),
  public.cx_status(uuid), public.cx_set_enabled(uuid, boolean) from public, anon, authenticated;
grant execute on function public.cx_status(uuid), public.cx_set_enabled(uuid, boolean) to authenticated;
grant execute on function public.cx_groups(uuid), public.cx_ari(uuid, int), public.cx_import(uuid, jsonb), public.cx_setup_data(uuid),
  public.cx_save_setup(uuid, text, jsonb), public.cx_mark(uuid, text, text), public.cx_links_due(), public.cx_property_for(text) to service_role;


-- >>>>>>>>>>>>>>>>>>>> 028_onboarding.sql
-- =====================================================================
-- NammaStay · 028_onboarding.sql — first-time setup wizard
-- New owners are guided through: property details → rooms & beds →
-- UPI payments → staff → first booking. The dashboard shows a setup
-- checklist until it's finished (or hidden).
-- Run AFTER 027_channex.sql.
-- =====================================================================
alter table public.properties add column if not exists setup_done_at timestamptz;
-- properties that already have bookings are clearly set up — don't show them the wizard
update public.properties p set setup_done_at = now()
 where setup_done_at is null and exists (select 1 from public.bookings b where b.property_id = p.id);

create or replace function public.setup_progress(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p public.properties%rowtype;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  select * into p from public.properties where id = p_property;
  return jsonb_build_object(
    'done_at', p.setup_done_at,
    'details', p.phone is not null and p.address is not null and p.city is not null,
    'rooms', exists (select 1 from public.beds where property_id = p_property and is_active),
    'upi', p.upi_id is not null,
    'staff', (select count(*) from public.property_members where property_id = p_property) > 1,
    'booking', exists (select 1 from public.bookings where property_id = p_property));
end $$;

create or replace function public.setup_finish(p_property uuid, p_done boolean default true) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  update public.properties set setup_done_at = case when p_done then coalesce(setup_done_at, now()) end where id = p_property;
end $$;

revoke execute on function public.setup_progress(uuid), public.setup_finish(uuid, boolean) from public, anon, authenticated;
grant execute on function public.setup_progress(uuid), public.setup_finish(uuid, boolean) to authenticated;

-- =====================================================================
-- 029_public_api.sql — NammaStay public API (per-property API keys)
--
-- Owners create API keys in Settings → API keys. Other software (your own website's booking
-- engine, a partner, a script) calls the `api` Edge Function with the key:
--   GET  /api/v1/property            property details
--   GET  /api/v1/rooms               room types (room + price group), units, base price
--   GET  /api/v1/availability        free units, nightly price, minimum stay per night
--   GET  /api/v1/bookings            bookings in a date range            (scope: bookings)
--   GET  /api/v1/bookings/{id|code}  one booking                         (scope: bookings)
--   POST /api/v1/bookings            create a booking                    (scope: bookings)
--   POST /api/v1/bookings/{id}/cancel                                    (scope: bookings)
--
-- Keys are stored only as a SHA-256 hash; the full key is shown once when created.
-- Every server function below is callable only by the Edge Function (service role).
-- Safe to run more than once.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables
create table if not exists public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 2 and 60),
  prefix       text not null,                                   -- "ns_live_1a2b3c" — shown in the list
  key_hash     text not null unique,                            -- sha256(full key), hex
  scopes       text[] not null default '{read}' check (scopes <@ array['read','bookings']::text[] and 'read' = any (scopes)),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
create index if not exists api_keys_property on public.api_keys (property_id, created_at desc);

create table if not exists public.api_requests (                -- rate limit window (rows older than a day are removed)
  key_id uuid not null references public.api_keys(id) on delete cascade,
  at     timestamptz not null default now()
);
create index if not exists api_requests_key_at on public.api_requests (key_id, at desc);

create table if not exists public.api_idempotency (             -- "Idempotency-Key" header on POST /bookings
  key_id     uuid not null references public.api_keys(id) on delete cascade,
  idem_key   text not null check (char_length(idem_key) between 1 and 100),
  response   jsonb not null,
  created_at timestamptz not null default now(),
  primary key (key_id, idem_key)
);

alter table public.api_keys        enable row level security;
alter table public.api_requests    enable row level security;
alter table public.api_idempotency enable row level security;
revoke all on public.api_keys, public.api_requests, public.api_idempotency from anon, authenticated;

-- ---------------------------------------------------------------- owner screens (Settings → API keys)
create or replace function public.api_key_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  return coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'prefix', k.prefix, 'scopes', k.scopes,
                     'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
                     'calls_24h', (select count(*) from public.api_requests r where r.key_id = k.id and r.at > now() - interval '24 hours'))
                     order by k.revoked_at nulls first, k.created_at desc)
                     from public.api_keys k where k.property_id = p_property), '[]'::jsonb);
end $$;

-- Returns the full key ONCE. Scopes: 'read' (always) and optionally 'bookings'.
create or replace function public.api_key_create(p_property uuid, p_name text, p_bookings boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_id uuid; v_prefix text;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if char_length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Give the key a name, e.g. "Website booking form".'; end if;
  if (select count(*) from public.api_keys where property_id = p_property and revoked_at is null) >= 10 then
    raise exception 'You already have 10 active API keys. Revoke one you no longer use first.';
  end if;
  if public._access_state(p_property) = 'expired' then
    raise exception 'This property''s NammaStay subscription has ended. Renew in Settings → Billing first.';
  end if;
  v_key := 'ns_live_' || encode(extensions.gen_random_bytes(24), 'hex');
  v_prefix := left(v_key, 14);
  insert into public.api_keys (property_id, name, prefix, key_hash, scopes)
  values (p_property, left(btrim(p_name), 60), v_prefix, encode(extensions.digest(v_key, 'sha256'), 'hex'),
          case when p_bookings then array['read','bookings'] else array['read'] end)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'key', v_key, 'prefix', v_prefix);
end $$;

create or replace function public.api_key_revoke(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.api_keys where id = p_id;
  if v_prop is null then raise exception 'API key not found.'; end if;
  perform public._assert_role(v_prop, array['owner']::public.member_role[]);
  update public.api_keys set revoked_at = coalesce(revoked_at, now()) where id = p_id;
end $$;

revoke execute on function public.api_key_list(uuid), public.api_key_create(uuid, text, boolean), public.api_key_revoke(uuid) from public, anon;
grant  execute on function public.api_key_list(uuid), public.api_key_create(uuid, text, boolean), public.api_key_revoke(uuid) to authenticated;

-- ---------------------------------------------------------------- server: authenticate a call
-- Returns {key_id, property_id, scopes} or {error, status}. 120 calls a minute per key.
create or replace function public.api_auth(p_key text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare k public.api_keys%rowtype; v_state text;
begin
  if p_key is null or p_key !~ '^ns_live_[0-9a-f]{48}$' then
    return jsonb_build_object('status', 401, 'code', 'invalid_key', 'message', 'Missing or malformed API key. Send it as the X-Api-Key header.');
  end if;
  select * into k from public.api_keys where key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex');
  if not found or k.revoked_at is not null then
    return jsonb_build_object('status', 401, 'code', 'invalid_key', 'message', 'This API key is not valid or has been revoked.');
  end if;
  v_state := public._access_state(k.property_id);
  if v_state = 'expired' then
    return jsonb_build_object('status', 402, 'code', 'subscription_expired', 'message', 'This property''s NammaStay subscription has ended.');
  end if;
  if (select count(*) from public.api_requests where key_id = k.id and at > now() - interval '1 minute') >= 120 then
    return jsonb_build_object('status', 429, 'code', 'rate_limited', 'message', 'Too many requests — max 120 a minute per key. Try again shortly.');
  end if;
  insert into public.api_requests (key_id) values (k.id);
  if k.last_used_at is null or k.last_used_at < now() - interval '1 minute' then
    update public.api_keys set last_used_at = now() where id = k.id;
  end if;
  if random() < 0.01 then delete from public.api_requests where at < now() - interval '1 day'; end if;
  return jsonb_build_object('key_id', k.id, 'key_name', k.name, 'property_id', k.property_id, 'scopes', to_jsonb(k.scopes));
end $$;

-- ---------------------------------------------------------------- server: data
create or replace function public._api_rupees(p int) returns numeric language sql immutable as $$ select round(coalesce(p, 0) / 100.0, 2) $$;

create or replace function public.api_property(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'address', p.address, 'city', p.city,
           'phone', p.phone, 'email', p.email, 'timezone', p.timezone, 'currency', 'INR',
           'check_in_time', to_char(p.checkin_time, 'HH24:MI'), 'check_out_time', to_char(p.checkout_time, 'HH24:MI'),
           'unit', case when p.kind = 'hostel' then 'bed' else 'room' end)
    from public.properties p where p.id = p_property
$$;

-- Room types = a room + one price (a 6-bed dorm with ₹700 lower and ₹600 upper beds = 2 room types)
create or replace function public.api_rooms(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'room_type_id', g->>'group_key', 'room_id', g->>'room_id', 'name', g->>'title',
           'description', (select r.description from public.rooms r where r.id = (g->>'room_id')::uuid),
           'unit', case when g->>'room_kind' = 'dorm' then 'bed' else 'room' end,
           'units', (g->>'count')::int, 'max_guests_per_unit', (g->>'occ_adults')::int,
           'base_price', public._api_rupees((g->>'rate_paise')::int)) order by g->>'sort', g->>'title'), '[]'::jsonb)
    from jsonb_array_elements(public.cx_groups(p_property)) g
$$;

-- p_from / p_to: dates (check-in day .. check-out day, max 92 nights)
create or replace function public.api_availability(p_property uuid, p_from date, p_to date, p_room_type text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p public.properties%rowtype;
begin
  select * into p from public.properties where id = p_property;
  if p_from is null or p_to is null or p_to <= p_from then raise exception 'from and to must be dates, with to after from (e.g. from=2026-11-01&to=2026-11-04).'; end if;
  if p_to - p_from > 92 then raise exception 'Ask for at most 92 nights at a time.'; end if;
  if p_from < (now() at time zone p.timezone)::date - 1 then raise exception 'from cannot be in the past.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'room_type_id', g->>'group_key', 'name', g->>'title', 'units', (g->>'count')::int,
      'nights', (select jsonb_agg(jsonb_build_object(
          'date', d::date,
          'available', (select count(*) from jsonb_array_elements_text(g->'bed_ids') bid
                         where not exists (select 1 from public.bookings k where k.bed_id = bid::uuid and k.status in ('pending','confirmed','checked_in')
                                             and k.stay && tstzrange(((d::date)::timestamp + p.checkin_time) at time zone p.timezone,
                                                                     ((d::date + 1)::timestamp + p.checkout_time) at time zone p.timezone, '[)'))
                           and not exists (select 1 from public.bed_blocks z where z.bed_id = bid::uuid
                                             and z.period && tstzrange(((d::date)::timestamp + p.checkin_time) at time zone p.timezone,
                                                                       ((d::date + 1)::timestamp + p.checkout_time) at time zone p.timezone, '[)'))),
          'price', public._api_rupees(public._night_rate(p_property, (g->>'room_id')::uuid, (g->>'rate_paise')::int, d::date)),
          'min_stay', greatest(1, coalesce((select max(r.min_nights) from public.rate_rules r
                        where r.property_id = p_property and r.is_active and r.min_nights is not null
                          and (r.room_ids is null or (g->>'room_id')::uuid = any (r.room_ids))
                          and ((r.kind = 'season' and d::date between r.date_from and r.date_to)
                            or (r.kind = 'weekend' and extract(dow from d)::smallint = any (r.weekdays)))), 1)))
          order by d) from generate_series(p_from, p_to - 1, interval '1 day') d),
      -- bookable for the whole stay = free every night
      'available_for_stay', (select count(*) from jsonb_array_elements_text(g->'bed_ids') bid
                              where not exists (select 1 from public.bookings k where k.bed_id = bid::uuid and k.status in ('pending','confirmed','checked_in')
                                                  and k.stay && tstzrange((p_from::timestamp + p.checkin_time) at time zone p.timezone,
                                                                          (p_to::timestamp + p.checkout_time) at time zone p.timezone, '[)'))
                                and not exists (select 1 from public.bed_blocks z where z.bed_id = bid::uuid
                                                  and z.period && tstzrange((p_from::timestamp + p.checkin_time) at time zone p.timezone,
                                                                            (p_to::timestamp + p.checkout_time) at time zone p.timezone, '[)'))),
      'total_price_per_unit', public._api_rupees((select sum(public._night_rate(p_property, (g->>'room_id')::uuid, (g->>'rate_paise')::int, d::date))
                                                   from generate_series(p_from, p_to - 1, interval '1 day') d)::int))
      order by g->>'sort', g->>'title'), '[]'::jsonb)
    from jsonb_array_elements(public.cx_groups(p_property)) g
   where p_room_type is null or g->>'group_key' = p_room_type);
end $$;

create or replace function public._api_booking_json(b public.bookings) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', b.id, 'code', b.code, 'status', b.status, 'source', b.source,
           'room_type_id', bd.room_id || ':' || bd.rate_paise, 'room', r.name, 'unit', bd.label,
           'check_in', (b.check_in_at at time zone p.timezone)::date, 'check_out', (b.check_out_at at time zone p.timezone)::date,
           'nights', b.nights, 'guests', b.visitors,
           'guest', jsonb_build_object('name', g.full_name, 'phone', g.phone, 'email', g.email, 'nationality', g.nationality),
           'price_per_night', public._api_rupees(b.rate_paise), 'total', public._api_rupees(b.total_paise),
           'paid', public._api_rupees(b.paid_paise), 'balance', public._api_rupees(b.balance_paise),
           'note', b.note, 'created_at', b.created_at, 'cancelled_at', b.cancelled_at,
           'self_check_in_token', b.self_checkin_token)
    from public.beds bd, public.rooms r, public.guests g, public.properties p
   where bd.id = b.bed_id and r.id = bd.room_id and g.id = b.guest_id and p.id = b.property_id
$$;

create or replace function public.api_bookings(p_property uuid, p_from date, p_to date, p_status text default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare tz text;
begin
  select timezone into tz from public.properties where id = p_property;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'from and to must be dates, with to on or after from.'; end if;
  if p_to - p_from > 366 then raise exception 'Ask for at most one year at a time.'; end if;
  if p_status is not null and p_status not in ('pending','confirmed','checked_in','checked_out','cancelled','no_show') then
    raise exception 'status must be one of pending, confirmed, checked_in, checked_out, cancelled, no_show.';
  end if;
  return coalesce((select jsonb_agg(public._api_booking_json(b) order by b.check_in_at, b.code)
    from (select * from public.bookings b
           where b.property_id = p_property and (p_status is null or b.status::text = p_status)
             and b.stay && tstzrange(p_from::timestamp at time zone tz, (p_to + 1)::timestamp at time zone tz, '[)')
           order by b.check_in_at, b.code limit least(greatest(coalesce(p_limit, 100), 1), 500)) b), '[]'::jsonb);
end $$;

create or replace function public.api_booking_get(p_property uuid, p_ref text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select public._api_booking_json(b) from public.bookings b
   where b.property_id = p_property
     and (b.code = upper(p_ref) or (p_ref ~* '^[0-9a-f-]{36}$' and b.id = p_ref::uuid))
$$;

-- p: { room_type_id, check_in, check_out, guests?, units?, guest: {name, phone?, email?, nationality?}, note?, status? ('confirmed'|'pending') }
create or replace function public.api_booking_create(p_property uuid, p_key_id uuid, p jsonb, p_idem text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pr public.properties%rowtype; v_key_name text; v_saved jsonb;
  v_rt text := p->>'room_type_id'; v_room uuid; v_rate int; v_in date; v_out date; v_n int; v_units int; v_guests int;
  v_name text; v_phone text; v_mail text; v_guest uuid; v_status public.booking_status; v_note text;
  v_bed uuid; v_bk uuid; v_ids uuid[] := '{}'; v_tries int; v_out_json jsonb;
begin
  if p_idem is not null then
    select response into v_saved from public.api_idempotency where key_id = p_key_id and idem_key = p_idem;
    if found then return v_saved; end if;
  end if;
  select * into pr from public.properties where id = p_property;
  select name into v_key_name from public.api_keys where id = p_key_id;

  if v_rt is null or v_rt !~ '^[0-9a-f-]{36}:[0-9]+$' then raise exception 'room_type_id is required (from GET /rooms).'; end if;
  v_room := split_part(v_rt, ':', 1)::uuid; v_rate := split_part(v_rt, ':', 2)::int;
  if not exists (select 1 from public.beds where property_id = p_property and room_id = v_room and rate_paise = v_rate and is_active) then
    raise exception 'Unknown room_type_id — get the current list from GET /rooms.';
  end if;
  begin v_in := (p->>'check_in')::date; v_out := (p->>'check_out')::date;
  exception when others then raise exception 'check_in and check_out must be dates like 2026-11-01.'; end;
  if v_in is null or v_out is null or v_out <= v_in then raise exception 'check_out must be after check_in.'; end if;
  if v_in < (now() at time zone pr.timezone)::date then raise exception 'check_in cannot be in the past.'; end if;
  v_n := v_out - v_in;
  if v_n > 90 then raise exception 'A booking through the API can be at most 90 nights.'; end if;
  v_units := coalesce(nullif(p->>'units', '')::int, 1);
  if v_units not between 1 and 10 then raise exception 'units must be between 1 and 10.'; end if;
  v_guests := coalesce(nullif(p->>'guests', '')::int, 1);
  if v_guests not between 1 and 20 then raise exception 'guests must be between 1 and 20.'; end if;
  v_status := coalesce(nullif(p->>'status', ''), 'confirmed')::public.booking_status;
  if v_status not in ('confirmed','pending') then raise exception 'status can be confirmed or pending.'; end if;

  v_name := btrim(coalesce(p->'guest'->>'name', ''));
  if char_length(v_name) < 2 then raise exception 'guest.name is required.'; end if;
  v_phone := nullif(regexp_replace(coalesce(p->'guest'->>'phone', ''), '[^0-9+]', '', 'g'), '');
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'guest.phone looks wrong — use digits, e.g. +919876543210.'; end if;
  v_mail := nullif(btrim(coalesce(p->'guest'->>'email', '')), '');
  if v_mail is not null and v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'guest.email looks wrong.'; end if;

  select id into v_guest from public.guests where property_id = p_property
     and ((v_mail is not null and lower(email) = lower(v_mail)) or (v_phone is not null and phone = v_phone)) order by created_at limit 1;
  if v_guest is null then
    insert into public.guests (property_id, full_name, phone, email, nationality)
    values (p_property, left(v_name, 120), v_phone, v_mail, nullif(left(p->'guest'->>'nationality', 60), '')) returning id into v_guest;
  end if;
  v_note := left(concat_ws(E'\n', 'Booked via API · ' || v_key_name, nullif(btrim(coalesce(p->>'note', '')), '')), 2000);

  for i in 1 .. v_units loop
    v_tries := 0;
    loop
      select bd.id into v_bed from public.beds bd
       where bd.property_id = p_property and bd.room_id = v_room and bd.rate_paise = v_rate and bd.is_active
         and bd.id <> all (v_ids)
         and not exists (select 1 from public.bookings x where x.bed_id = bd.id and x.status in ('pending','confirmed','checked_in')
                           and x.stay && tstzrange((v_in::timestamp + pr.checkin_time) at time zone pr.timezone, (v_out::timestamp + pr.checkout_time) at time zone pr.timezone, '[)'))
         and not exists (select 1 from public.bed_blocks z where z.bed_id = bd.id
                           and z.period && tstzrange((v_in::timestamp + pr.checkin_time) at time zone pr.timezone, (v_out::timestamp + pr.checkout_time) at time zone pr.timezone, '[)'))
       order by bd.sort, bd.label limit 1;
      if v_bed is null then
        raise exception 'Not available: only % free % for these dates.', i - 1, case when pr.kind = 'hostel' then 'beds' else 'rooms' end
          using errcode = 'P0409';
      end if;
      begin
        insert into public.bookings (property_id, guest_id, bed_id, visitors, check_in_at, check_out_at, nights, rate_paise, total_paise, status, source, note, created_by)
        values (p_property, v_guest, v_bed, v_guests,
                (v_in::timestamp + pr.checkin_time) at time zone pr.timezone, (v_out::timestamp + pr.checkout_time) at time zone pr.timezone,
                v_n, v_rate, v_rate * v_n, v_status, 'direct', v_note, null)
        returning id into v_bk;
        v_ids := v_ids || v_bk;
        exit;
      exception when exclusion_violation then
        v_tries := v_tries + 1;                                   -- taken a moment ago: try the next free one
        if v_tries > 5 then raise exception 'Not available any more for these dates.' using errcode = 'P0409'; end if;
      end;
    end loop;
  end loop;

  insert into public.notifications (property_id, kind, title, body, booking_id)
  values (p_property, 'booking', 'New booking via API',
          format('%s · %s → %s · %s', v_name, to_char(v_in, 'DD Mon'), to_char(v_out, 'DD Mon'), v_key_name), v_ids[1]);

  select jsonb_build_object('bookings', jsonb_agg(public._api_booking_json(b) order by b.code),
                            'total', public._api_rupees(sum(b.total_paise)::int))
    into v_out_json from public.bookings b where b.id = any (v_ids);
  if p_idem is not null then
    insert into public.api_idempotency (key_id, idem_key, response) values (p_key_id, p_idem, v_out_json) on conflict do nothing;
  end if;
  return v_out_json;
end $$;

create or replace function public.api_booking_cancel(p_property uuid, p_ref text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings%rowtype;
begin
  select * into b from public.bookings where property_id = p_property
     and (code = upper(p_ref) or (p_ref ~* '^[0-9a-f-]{36}$' and id = p_ref::uuid)) for update;
  if not found then raise exception 'Booking not found.' using errcode = 'P0404'; end if;
  if b.status = 'cancelled' then return public._api_booking_json(b); end if;
  if b.status not in ('pending','confirmed') then
    raise exception 'Only pending or confirmed bookings can be cancelled (this one is %).', b.status using errcode = 'P0409';
  end if;
  update public.bookings set status = 'cancelled', cancelled_at = now(),
         note = left(concat_ws(E'\n', note, 'Cancelled via API' || coalesce(': ' || nullif(btrim(p_reason), ''), '')), 2000)
   where id = b.id returning * into b;
  insert into public.notifications (property_id, kind, title, body, booking_id)
  values (p_property, 'booking', 'Booking cancelled via API', b.code, b.id);
  return public._api_booking_json(b);
end $$;

-- only the Edge Function (service role) may call the server functions
do $$ declare f text; begin
  foreach f in array array['api_auth(text)', 'api_property(uuid)', 'api_rooms(uuid)', 'api_availability(uuid, date, date, text)',
                           '_api_booking_json(public.bookings)', 'api_bookings(uuid, date, date, text, int)', 'api_booking_get(uuid, text)',
                           'api_booking_create(uuid, uuid, jsonb, text)', 'api_booking_cancel(uuid, text, text)', '_api_rupees(int)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;


-- =====================================================================
-- NammaStay · 030_booking_guests.sql — more than one guest in a booking
--
-- A hotel room (or homestay room) often has 2+ people. The main guest stays
-- on the booking as before; everyone else is saved here with their own
-- name, phone, age, gender, nationality, ID type / number and ID photos.
--
-- ADD-ON ONLY — nothing existing is changed in behaviour:
--   • new table  public.booking_guests  (+ booking_guest_doc_trash)
--   • new functions booking_guests_list / booking_guest_save / booking_guest_delete
--   • id_docs_due_for_purge + mark_id_doc_purged are re-created with the SAME
--     result for main guests, plus these extra guests' ID photos, so the
--     nightly ID-photo clean-up (purge-id-docs) also covers them.
--     The edge function itself is unchanged.
-- Safe to run more than once. Run after 001–029.
-- =====================================================================

create table if not exists public.booking_guests (
  id               uuid primary key default gen_random_uuid(),
  property_id      uuid not null,
  booking_id       uuid not null,
  full_name        text not null check (char_length(btrim(full_name)) between 2 and 120),
  phone            text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  gender           text check (gender is null or gender in ('male','female','other')),
  age              smallint check (age is null or age between 0 and 120),
  relation         text check (char_length(relation) <= 40),          -- spouse, friend, child, colleague…
  nationality      text check (char_length(nationality) <= 60),
  id_type          public.id_doc_type,
  id_number        text check (char_length(id_number) <= 40),        -- Aadhaar stored masked: XXXX XXXX 1234
  id_doc_path      text,                                              -- private "guest-ids" bucket
  id_doc_back_path text,
  sort             smallint not null default 0,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index if not exists booking_guests_booking on public.booking_guests (booking_id, sort, created_at);
create index if not exists booking_guests_property on public.booking_guests (property_id);

-- ID photos of extra guests whose row/booking was deleted: cleaned up by the nightly job
create table if not exists public.booking_guest_doc_trash (
  id         uuid primary key default gen_random_uuid(),
  path       text not null,
  created_at timestamptz not null default now()
);

alter table public.booking_guests enable row level security;
alter table public.booking_guest_doc_trash enable row level security;
drop policy if exists booking_guests_select on public.booking_guests;
create policy booking_guests_select on public.booking_guests for select to authenticated
  using (property_id in (select public.my_property_ids()));
revoke all on public.booking_guests, public.booking_guest_doc_trash from anon, authenticated;
grant select on public.booking_guests to authenticated;            -- writes only through the functions below

-- When an extra guest (or the whole booking) is deleted, queue their ID photos for removal
create or replace function public._booking_guest_trash() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.booking_guest_doc_trash (path)
  select p from unnest(array_remove(array[old.id_doc_path, old.id_doc_back_path], null)) p;
  return old;
end $$;
drop trigger if exists booking_guests_trash on public.booking_guests;
create trigger booking_guests_trash after delete on public.booking_guests
  for each row execute function public._booking_guest_trash();

-- ---------------------------------------------------------------- list
create or replace function public.booking_guests_list(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.bookings where id = p_booking;
  if v_prop is null then raise exception 'Booking not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', g.id, 'full_name', g.full_name, 'phone', g.phone, 'gender', g.gender, 'age', g.age,
             'relation', g.relation, 'nationality', g.nationality, 'id_type', g.id_type, 'id_number', g.id_number,
             'id_doc_path', g.id_doc_path, 'id_doc_back_path', g.id_doc_back_path, 'created_at', g.created_at)
           order by g.sort, g.created_at)
      from public.booking_guests g where g.booking_id = p_booking), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- add / edit
-- p: { id?, full_name, phone?, gender?, age?, relation?, nationality?, id_type?, id_number?, id_doc_path?, id_doc_back_path? }
-- Returns the saved guest plus old_id_doc_path / old_id_doc_back_path when a photo was replaced
-- (the app deletes the old file).
create or replace function public.booking_guest_save(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prop uuid; v_id uuid := nullif(p->>'id', '')::uuid; v_row public.booking_guests; v_old public.booking_guests;
  v_type public.id_doc_type := nullif(p->>'id_type', '')::public.id_doc_type;
  v_phone text := nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9+]', '', 'g'), '');
begin
  select property_id into v_prop from public.bookings where id = p_booking;
  if v_prop is null then raise exception 'Booking not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  if char_length(btrim(coalesce(p->>'full_name', ''))) < 2 then raise exception 'Enter the guest''s full name.'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the phone number.'; end if;

  if v_id is null then
    if (select count(*) from public.booking_guests where booking_id = p_booking) >= 19 then
      raise exception 'A booking can have up to 20 guests.';
    end if;
    insert into public.booking_guests (property_id, booking_id, full_name, phone, gender, age, relation, nationality,
                                       id_type, id_number, id_doc_path, id_doc_back_path, sort)
    values (v_prop, p_booking, btrim(p->>'full_name'), v_phone, nullif(p->>'gender', ''), nullif(p->>'age', '')::smallint,
            nullif(btrim(coalesce(p->>'relation', '')), ''), nullif(btrim(coalesce(p->>'nationality', '')), ''),
            v_type, public._mask_id(v_type::text, nullif(p->>'id_number', '')),
            nullif(p->>'id_doc_path', ''), nullif(p->>'id_doc_back_path', ''),
            coalesce((select max(sort) + 1 from public.booking_guests where booking_id = p_booking), 0))
    returning * into v_row;
    return to_jsonb(v_row);
  end if;

  select * into v_old from public.booking_guests where id = v_id and booking_id = p_booking for update;
  if v_old.id is null then raise exception 'Guest not found.' using errcode = 'P0404'; end if;
  update public.booking_guests set
    full_name   = btrim(p->>'full_name'),
    phone       = v_phone,
    gender      = nullif(p->>'gender', ''),
    age         = nullif(p->>'age', '')::smallint,
    relation    = nullif(btrim(coalesce(p->>'relation', '')), ''),
    nationality = nullif(btrim(coalesce(p->>'nationality', '')), ''),
    id_type     = v_type,
    id_number   = case when p ? 'id_number' and coalesce(p->>'id_number', '') <> coalesce(v_old.id_number, '')
                       then public._mask_id(v_type::text, nullif(p->>'id_number', '')) else v_old.id_number end,
    id_doc_path      = coalesce(nullif(p->>'id_doc_path', ''), v_old.id_doc_path),
    id_doc_back_path = coalesce(nullif(p->>'id_doc_back_path', ''), v_old.id_doc_back_path),
    updated_at  = now()
  where id = v_id
  returning * into v_row;
  return to_jsonb(v_row) || jsonb_build_object(
    'old_id_doc_path', case when v_row.id_doc_path is distinct from v_old.id_doc_path then v_old.id_doc_path end,
    'old_id_doc_back_path', case when v_row.id_doc_back_path is distinct from v_old.id_doc_back_path then v_old.id_doc_back_path end);
end $$;

-- ---------------------------------------------------------------- remove
create or replace function public.booking_guest_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.booking_guests where id = p_id;
  if v_prop is null then return; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  delete from public.booking_guests where id = p_id;          -- trigger queues the ID photos for clean-up
end $$;

revoke execute on function public.booking_guests_list(uuid), public.booking_guest_save(uuid, jsonb),
  public.booking_guest_delete(uuid), public._booking_guest_trash() from public, anon;
grant execute on function public.booking_guests_list(uuid), public.booking_guest_save(uuid, jsonb),
  public.booking_guest_delete(uuid) to authenticated;

-- ---------------------------------------------------------------- nightly ID-photo clean-up
-- Same as 010 for main guests, plus extra guests (same retention rule, by their booking's
-- check-out) and photos queued in the trash table (removed straight away).
create or replace function public.id_docs_due_for_purge(p_limit int default 200)
returns table (guest_id uuid, path text)
language sql stable security definer set search_path = public, pg_temp as $$
  (select x.id, x.path from (
    select g.id, unnest(array_remove(array[g.id_doc_path, g.id_doc_back_path], null)) as path, g.property_id
      from public.guests g
     where (g.id_doc_path is not null or g.id_doc_back_path is not null)) x
  join public.properties p on p.id = x.property_id
  where not exists (select 1 from public.bookings b where b.guest_id = x.id
                     and b.check_out_at > now() - make_interval(days => p.id_doc_retention_days))
  limit p_limit)
  union all
  (select y.id, y.path from (
    select bg.id, unnest(array_remove(array[bg.id_doc_path, bg.id_doc_back_path], null)) as path, bg.property_id, bg.booking_id
      from public.booking_guests bg
     where (bg.id_doc_path is not null or bg.id_doc_back_path is not null)) y
  join public.properties p on p.id = y.property_id
  join public.bookings b on b.id = y.booking_id
  where b.check_out_at <= now() - make_interval(days => p.id_doc_retention_days)
  limit p_limit)
  union all
  (select t.id, t.path from public.booking_guest_doc_trash t limit p_limit)
$$;

create or replace function public.mark_id_doc_purged(p_guest uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.guests set id_doc_path = null, id_doc_back_path = null where id = p_guest;
  update public.booking_guests set id_doc_path = null, id_doc_back_path = null where id = p_guest;
  delete from public.booking_guest_doc_trash where id = p_guest;
$$;
revoke execute on function public.id_docs_due_for_purge(int), public.mark_id_doc_purged(uuid) from public, anon, authenticated;
grant execute on function public.id_docs_due_for_purge(int), public.mark_id_doc_purged(uuid) to service_role;


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


-- =====================================================================
-- NammaStay · 032_pg_app.sql — the whole app adapted for PG / co-living accounts
--
-- For properties marked PG / co-living (031 pg_properties):
--   • pg_dashboard   PG dashboard (tenants, occupancy, vacant beds, rent due,
--                    rent days this week, leaving soon, recent payments)
--   • pg_payments    all rent receipts in a date range (Rent payments page)
--   • pg_report      month-by-month: billed, collected, deposits, occupancy,
--                    move-ins / move-outs (Rent reports page)
--   • pg_income      rent & charges received, for Expenses & profit
--   • Type locked    a PG account can't change its type (Settings) and can't
--                    turn PG off — only a NammaStay platform admin can.
--
-- ADD-ON ONLY: new functions + one trigger on properties that acts only when
-- the property is PG and its kind is being changed. pg_set_mode (from 031)
-- is re-created: turning PG ON is unchanged, turning it OFF is admin-only.
-- Needs 031. Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------- type lock
create or replace function public._pg_lock_kind() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind is distinct from old.kind
     and exists (select 1 from public.pg_properties where property_id = old.id)
     and not public.is_platform_admin() then
    raise exception 'This is a PG / co-living account — the property type can''t be changed. Contact NammaStay support if you need to.'
      using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists pg_lock_kind on public.properties;
create trigger pg_lock_kind before update of kind on public.properties
  for each row execute function public._pg_lock_kind();

create or replace function public.pg_set_mode(p_property uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_on then
    perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
    if (select kind from public.properties where id = p_property) <> 'hostel' then
      raise exception 'PG / co-living works with beds — set the type to PG / Co-living (not hotel or homestay).';
    end if;
    insert into public.pg_properties (property_id) values (p_property) on conflict do nothing;
  else
    if exists (select 1 from public.pg_properties where property_id = p_property) and not public.is_platform_admin() then
      raise exception 'This is a PG / co-living account — it can''t be switched to another type. Contact NammaStay support if you need to.'
        using errcode = '42501';
    end if;
    delete from public.pg_properties where property_id = p_property;
  end if;
  return p_on;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function public._pg_assert(p_property uuid, p_roles public.member_role[]) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, p_roles);
  if not exists (select 1 from public.pg_properties where property_id = p_property) then
    raise exception 'This is only for PG / co-living properties.';
  end if;
end $$;

-- Money that counts as income: payments for rent / food / charges + dues taken from the deposit.
-- Deposits received are NOT income (they're held); deposit refunds are not expenses.
create or replace function public._pg_income_rows(p_property uuid)
returns table (received_on date, amount_paise int)
language sql stable security definer set search_path = public, pg_temp as $$
  select (p.received_at at time zone public._tz(p_property))::date, p.amount_paise
    from public.rent_payments p left join public.rent_dues d on d.id = p.due_id
   where p.property_id = p_property and p.kind in ('payment','deposit_adjust') and coalesce(d.kind, '') <> 'deposit'
$$;

-- ---------------------------------------------------------------- dashboard
create or replace function public.pg_dashboard(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date; v_month date; v_beds int; v_occ int;
begin
  perform public._pg_assert(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._pg_sync(p_property);
  v_today := public._pg_today(p_property);
  v_month := date_trunc('month', v_today)::date;
  select count(*) into v_beds from public.beds b where b.property_id = p_property and b.is_active;
  select count(distinct t.bed_id) into v_occ from public.tenancies t
   where t.property_id = p_property and t.status <> 'moved_out' and t.start_date <= v_today;
  return jsonb_build_object(
    'today', v_today,
    'property', (select jsonb_build_object('name', name, 'upi_id', upi_id) from public.properties where id = p_property),
    'beds_total', v_beds, 'beds_occupied', v_occ,
    'tenants', (select count(*) from public.tenancies where property_id = p_property and status <> 'moved_out'),
    'on_notice', (select count(*) from public.tenancies where property_id = p_property and status = 'notice'),
    'rent_roll_paise', coalesce((select sum(rent_paise + food_paise) from public.tenancies where property_id = p_property and status <> 'moved_out'), 0),
    'collected_month_paise', coalesce((select sum(amount_paise) from public._pg_income_rows(p_property) where received_on >= v_month), 0),
    'due_now_paise', coalesce((select sum(d.amount_paise - d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                where d.property_id = p_property and d.due_on <= v_today and t.status <> 'moved_out'), 0),
    'overdue_paise', coalesce((select sum(d.amount_paise - d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                where d.property_id = p_property and d.due_on < v_today - 5 and t.status <> 'moved_out'), 0),
    'deposits_held_paise', coalesce((select sum(d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                      where d.property_id = p_property and d.kind = 'deposit' and t.status <> 'moved_out'), 0),
    -- who owes money now (largest first)
    'dues', coalesce((select jsonb_agg(x order by (x->>'due_paise')::int desc) from (
        select jsonb_build_object('id', t.id, 'name', g.full_name, 'phone', g.phone, 'bed', r.name || ' · ' || bd.label,
                 'due_paise', sum(d.amount_paise - d.paid_paise), 'oldest', min(d.due_on), 'late', min(d.due_on) < v_today - 5) as x
          from public.tenancies t join public.rent_dues d on d.tenancy_id = t.id
          join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
         where t.property_id = p_property and t.status <> 'moved_out' and d.due_on <= v_today and d.amount_paise > d.paid_paise
         group by t.id, g.full_name, g.phone, r.name, bd.label
         order by sum(d.amount_paise - d.paid_paise) desc limit 8) s), '[]'::jsonb),
    -- rent day in the next 7 days
    'rent_days', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', g.full_name, 'bed', r.name || ' · ' || bd.label,
                 'day', nd.d, 'amount_paise', t.rent_paise + t.food_paise) order by nd.d)
        from public.tenancies t join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
        cross join lateral (
          select min(dd)::date as d from generate_series(v_today + 1, v_today + 7, interval '1 day') dd
           where (t.cycle = 'calendar' and extract(day from dd) = 1)
              or (t.cycle = 'movein' and (extract(day from dd) = extract(day from t.start_date)
                   or (extract(day from t.start_date) > extract(day from (date_trunc('month', dd) + interval '1 month - 1 day'))
                       and dd::date = (date_trunc('month', dd) + interval '1 month - 1 day')::date)))) nd
       where t.property_id = p_property and t.status <> 'moved_out' and nd.d is not null and t.start_date < nd.d
         and coalesce(t.move_out_on, 'infinity'::date) > nd.d), '[]'::jsonb),
    -- leaving soon
    'leaving', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', g.full_name, 'bed', r.name || ' · ' || bd.label, 'day', t.move_out_on) order by t.move_out_on)
        from public.tenancies t join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
       where t.property_id = p_property and t.status = 'notice'), '[]'::jsonb),
    -- moving in soon (future move-in date)
    'arriving', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', g.full_name, 'bed', r.name || ' · ' || bd.label, 'day', t.start_date) order by t.start_date)
        from public.tenancies t join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
       where t.property_id = p_property and t.status <> 'moved_out' and t.start_date > v_today), '[]'::jsonb),
    -- vacant beds (no tenant now)
    'vacant', coalesce((select jsonb_agg(jsonb_build_object('id', bd.id, 'bed', r.name || ' · ' || bd.label, 'rent_paise', bd.rate_paise) order by r.sort, bd.sort)
        from public.beds bd join public.rooms r on r.id = bd.room_id
       where bd.property_id = p_property and bd.is_active
         and not exists (select 1 from public.tenancies t where t.bed_id = bd.id and t.status <> 'moved_out' and t.start_date <= v_today)), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('code', p.code, 'name', g.full_name, 'amount_paise', p.amount_paise, 'method', p.method, 'kind', p.kind,
                 'for', d.label, 'at', p.received_at) as x
          from public.rent_payments p join public.tenancies t on t.id = p.tenancy_id join public.guests g on g.id = t.guest_id
          left join public.rent_dues d on d.id = p.due_id
         where p.property_id = p_property and p.kind in ('payment','refund')
         order by p.received_at desc limit 8) s), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- all receipts in a period
create or replace function public.pg_payments(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tz text;
begin
  perform public._pg_assert(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if not public._allowed(p_property, 'view_payments') then
    raise exception 'Your role can’t see payments. Ask the owner.';
  end if;
  v_tz := public._tz(p_property);
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'kind', p.kind, 'amount_paise', p.amount_paise,
               'method', p.method, 'reference', p.reference, 'note', p.note, 'received_at', p.received_at,
               'for', d.label, 'due_kind', d.kind, 'tenancy_id', t.id, 'name', g.full_name, 'phone', g.phone,
               'bed', r.name || ' · ' || bd.label) order by p.received_at desc, p.code desc)
        from public.rent_payments p join public.tenancies t on t.id = p.tenancy_id join public.guests g on g.id = t.guest_id
        join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
        left join public.rent_dues d on d.id = p.due_id
       where p.property_id = p_property and (p.received_at at time zone v_tz)::date between p_from and p_to), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'rent_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit'), 0),
        'deposits_in_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and d.kind = 'deposit'), 0),
        'from_deposit_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'deposit_adjust'), 0),
        'refunds_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'refund'), 0),
        'upi_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit' and p.method = 'upi'), 0),
        'cash_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit' and p.method = 'cash'), 0),
        'other_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit' and p.method not in ('upi','cash')), 0))
        from public.rent_payments p left join public.rent_dues d on d.id = p.due_id
       where p.property_id = p_property and (p.received_at at time zone v_tz)::date between p_from and p_to));
end $$;

-- ---------------------------------------------------------------- month by month
create or replace function public.pg_report(p_property uuid, p_months int default 12) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date; v_beds int;
begin
  perform public._pg_assert(p_property, array['owner','manager','accountant']::public.member_role[]);
  if not public._allowed(p_property, 'view_reports') then
    raise exception 'Your role can’t see reports. Ask the owner.';
  end if;
  perform public._pg_sync(p_property);
  v_today := public._pg_today(p_property);
  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  return jsonb_build_object('beds_total', v_beds, 'months', (select jsonb_agg(m order by m->>'month') from (
    select jsonb_build_object(
      'month', to_char(ms, 'YYYY-MM'),
      'billed_paise', coalesce((select sum(d.amount_paise - d.credit_paise) from public.rent_dues d
                                 where d.property_id = p_property and d.kind <> 'deposit' and date_trunc('month', d.due_on) = ms), 0),
      'collected_paise', coalesce((select sum(amount_paise) from public._pg_income_rows(p_property) where date_trunc('month', received_on) = ms), 0),
      'deposits_in_paise', coalesce((select sum(p.amount_paise) from public.rent_payments p join public.rent_dues d on d.id = p.due_id
                                      where p.property_id = p_property and p.kind = 'payment' and d.kind = 'deposit'
                                        and date_trunc('month', (p.received_at at time zone public._tz(p_property))) = ms), 0),
      'refunds_paise', coalesce((select sum(p.amount_paise) from public.rent_payments p
                                  where p.property_id = p_property and p.kind = 'refund'
                                    and date_trunc('month', (p.received_at at time zone public._tz(p_property))) = ms), 0),
      'move_ins', (select count(*) from public.tenancies where property_id = p_property and date_trunc('month', start_date) = ms),
      'move_outs', (select count(*) from public.tenancies where property_id = p_property and status = 'moved_out' and date_trunc('month', move_out_on) = ms),
      -- occupancy on the 15th (or today for the current month)
      'occupied', (select count(distinct t.bed_id) from public.tenancies t where t.property_id = p_property
                     and t.start_date <= least((ms + interval '14 days')::date, v_today)
                     and coalesce(t.move_out_on, 'infinity'::date) > least((ms + interval '14 days')::date, v_today))) as m
    from generate_series(date_trunc('month', v_today) - make_interval(months => greatest(1, least(p_months, 36)) - 1),
                         date_trunc('month', v_today), interval '1 month') ms) s));
end $$;

-- ---------------------------------------------------------------- income for Expenses & profit
create or replace function public.pg_income(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  if not exists (select 1 from public.pg_properties where property_id = p_property) then
    return jsonb_build_object('total_paise', 0, 'months', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'total_paise', coalesce((select sum(amount_paise) from public._pg_income_rows(p_property) where received_on between p_from and p_to), 0),
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', mo, 'income_paise', amt) order by mo) from (
        select to_char(received_on, 'YYYY-MM') mo, sum(amount_paise) amt from public._pg_income_rows(p_property)
         where received_on >= (date_trunc('month', public._pg_today(p_property)) - interval '11 months')::date group by 1) s), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- tenant registration link
-- The online check-in page (opened by the tenant with their link token) asks whether this is a PG tenant,
-- so it can say "Tenant registration" instead of showing nights. Returns nothing else.
create or replace function public.pg_selfcheckin_info(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select jsonb_build_object('tenant', true, 'start_date', t.start_date, 'moved_in', t.start_date <= public._pg_today(t.property_id))
      from public.bookings b join public.tenancies t on t.booking_ids @> array[b.id]
     where b.self_checkin_token = p_token limit 1), jsonb_build_object('tenant', false))
$$;
revoke execute on function public.pg_selfcheckin_info(uuid) from public;
grant execute on function public.pg_selfcheckin_info(uuid) to anon, authenticated;

revoke execute on function public._pg_lock_kind(), public._pg_assert(uuid, public.member_role[]), public._pg_income_rows(uuid) from public, anon, authenticated;
revoke execute on function public.pg_dashboard(uuid), public.pg_payments(uuid, date, date), public.pg_report(uuid, int), public.pg_income(uuid, date, date),
  public.pg_set_mode(uuid, boolean) from public, anon;
grant execute on function public.pg_dashboard(uuid), public.pg_payments(uuid, date, date), public.pg_report(uuid, int), public.pg_income(uuid, date, date),
  public.pg_set_mode(uuid, boolean) to authenticated;


-- =====================================================================
-- NammaStay · 033_homestay.sql — homestay add-ons: meal plans + house guide
--
-- Meal plans   Breakfast / Breakfast + Dinner / All meals, priced per adult and per
--              child per night. Choosing a plan on a booking adds ONE normal extra
--              ("Meals: …") to the bill through the existing add_charge(), so bills,
--              invoices, payments and reports work exactly as before. A kitchen list
--              counts the breakfasts / lunches / dinners for a day.
-- House guide  Welcome note, house rules, Wi-Fi, how to reach, host phone, check-in /
--              check-out and food notes. Staff send it on WhatsApp; the guest also sees
--              it on their online check-in page (by their booking link only).
--
-- ADD-ON ONLY — nothing existing is changed:
--   • new tables  meal_plans, booking_meals, property_guide
--   • new functions meal_plans_list, meal_plan_save, meal_plan_delete, booking_meal_get,
--     booking_meal_set, kitchen_list, guide_get, guide_save, guide_for_token
--   • no existing table, function, trigger or policy is touched
-- Safe to run more than once. Run after 001–029 (030–032 not needed).
-- =====================================================================

-- ---------------------------------------------------------------- tables
create table if not exists public.meal_plans (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 60),
  breakfast     boolean not null default false,
  lunch         boolean not null default false,
  dinner        boolean not null default false,
  adult_paise   int not null default 0 check (adult_paise between 0 and 10000000),   -- per adult per night
  child_paise   int not null default 0 check (child_paise between 0 and 10000000),   -- per child per night
  is_active     boolean not null default true,
  sort          smallint not null default 0,
  created_at    timestamptz not null default now(),
  check (breakfast or lunch or dinner)
);
create index if not exists meal_plans_property on public.meal_plans (property_id, sort);

create table if not exists public.booking_meals (
  booking_id    uuid primary key,
  property_id   uuid not null,
  plan_id       uuid references public.meal_plans(id) on delete set null,
  plan_name     text not null,
  breakfast     boolean not null default false,
  lunch         boolean not null default false,
  dinner        boolean not null default false,
  adults        smallint not null default 1,
  children      smallint not null default 0,
  nights        smallint not null default 1,
  amount_paise  int not null default 0,
  charge_id     uuid,                                  -- the "Meals: …" line on the bill (booking_charges)
  note          text check (char_length(note) <= 200),
  updated_at    timestamptz not null default now(),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index if not exists booking_meals_property on public.booking_meals (property_id);

create table if not exists public.property_guide (
  property_id   uuid primary key references public.properties(id) on delete cascade,
  welcome       text check (char_length(welcome) <= 1000),
  house_rules   text check (char_length(house_rules) <= 2000),
  wifi_name     text check (char_length(wifi_name) <= 80),
  wifi_password text check (char_length(wifi_password) <= 80),
  directions    text check (char_length(directions) <= 1500),
  maps_url      text check (maps_url is null or (maps_url ~* '^https?://' and char_length(maps_url) <= 500)),
  host_name     text check (char_length(host_name) <= 80),
  host_phone    text check (host_phone is null or host_phone ~ '^\+?[0-9]{8,15}$'),
  checkin_info  text check (char_length(checkin_info) <= 1000),
  checkout_info text check (char_length(checkout_info) <= 1000),
  food_info     text check (char_length(food_info) <= 1000),
  updated_at    timestamptz not null default now()
);

alter table public.meal_plans enable row level security;
alter table public.booking_meals enable row level security;
alter table public.property_guide enable row level security;
drop policy if exists meal_plans_select on public.meal_plans;
create policy meal_plans_select on public.meal_plans for select to authenticated using (property_id in (select public.my_property_ids()));
drop policy if exists booking_meals_select on public.booking_meals;
create policy booking_meals_select on public.booking_meals for select to authenticated using (property_id in (select public.my_property_ids()));
drop policy if exists property_guide_select on public.property_guide;
create policy property_guide_select on public.property_guide for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.meal_plans, public.booking_meals, public.property_guide from anon, authenticated;
grant select on public.meal_plans, public.booking_meals, public.property_guide to authenticated;   -- writes only through the functions below

-- ---------------------------------------------------------------- meal plans (Settings)
create or replace function public.meal_plans_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'breakfast', breakfast, 'lunch', lunch, 'dinner', dinner,
      'adult_paise', adult_paise, 'child_paise', child_paise, 'is_active', is_active) order by sort, created_at)
    from public.meal_plans where property_id = p_property), '[]'::jsonb);
end $$;

create or replace function public.meal_plan_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', ''));
  v_b boolean := coalesce((p->>'breakfast')::boolean, false); v_l boolean := coalesce((p->>'lunch')::boolean, false);
  v_d boolean := coalesce((p->>'dinner')::boolean, false);
  v_a int := coalesce(nullif(p->>'adult_paise', '')::int, 0); v_c int := coalesce(nullif(p->>'child_paise', '')::int, 0);
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if char_length(v_name) < 1 then raise exception 'Give the meal plan a name, e.g. “Breakfast included”.'; end if;
  if not (v_b or v_l or v_d) then raise exception 'Tick at least one meal (breakfast, lunch or dinner).'; end if;
  if v_a < 0 or v_c < 0 or v_a > 10000000 or v_c > 10000000 then raise exception 'Enter a price between ₹0 and ₹1,00,000.'; end if;
  if v_id is null then
    if (select count(*) from public.meal_plans where property_id = p_property) >= 12 then raise exception 'Up to 12 meal plans.'; end if;
    insert into public.meal_plans (property_id, name, breakfast, lunch, dinner, adult_paise, child_paise, is_active, sort)
    values (p_property, left(v_name, 60), v_b, v_l, v_d, v_a, v_c, coalesce((p->>'is_active')::boolean, true),
            coalesce((select max(sort) + 1 from public.meal_plans where property_id = p_property), 0))
    returning id into v_id;
  else
    update public.meal_plans set name = left(v_name, 60), breakfast = v_b, lunch = v_l, dinner = v_d, adult_paise = v_a, child_paise = v_c,
           is_active = coalesce((p->>'is_active')::boolean, is_active)
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Meal plan not found.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.meal_plan_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.meal_plans where id = p_id;
  if v_prop is null then raise exception 'Meal plan not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.meal_plans where id = p_id;          -- bookings keep their plan name and bill line
end $$;

-- ---------------------------------------------------------------- a booking's meal plan
create or replace function public.booking_meal_get(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_prop uuid; m public.booking_meals%rowtype; b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select * into m from public.booking_meals where booking_id = p_booking;
  if not found then return jsonb_build_object('plan', null); end if;
  return jsonb_build_object('plan', jsonb_build_object('plan_id', m.plan_id, 'name', m.plan_name, 'breakfast', m.breakfast, 'lunch', m.lunch,
    'dinner', m.dinner, 'adults', m.adults, 'children', m.children, 'nights', m.nights, 'amount_paise', m.amount_paise,
    'charged', exists (select 1 from public.booking_charges c where c.id = m.charge_id),
    'stale', (m.nights <> b.nights or m.adults <> b.visitors or m.children <> coalesce(b.children, 0))));
end $$;

-- p_plan null = room only (removes the plan and its bill line)
create or replace function public.booking_meal_set(p_booking uuid, p_plan uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings%rowtype; mp public.meal_plans%rowtype; old public.booking_meals%rowtype;
  v_night int; v_amt int; v_charge jsonb; v_meals text;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  select * into old from public.booking_meals where booking_id = p_booking for update;
  if found and old.charge_id is not null and exists (select 1 from public.booking_charges where id = old.charge_id) then
    perform public.remove_charge(old.charge_id);                       -- the old "Meals: …" line comes off the bill
  end if;
  delete from public.booking_meals where booking_id = p_booking;
  if p_plan is null then return jsonb_build_object('plan', null); end if;

  select * into mp from public.meal_plans where id = p_plan and property_id = b.property_id;
  if not found then raise exception 'That meal plan isn’t in your list any more.'; end if;
  v_night := mp.adult_paise * greatest(b.visitors, 1) + mp.child_paise * coalesce(b.children, 0);
  v_amt := v_night * b.nights;
  v_meals := array_to_string(array_remove(array[case when mp.breakfast then 'breakfast' end, case when mp.lunch then 'lunch' end,
                                                case when mp.dinner then 'dinner' end], null), ' + ');
  if v_night > 0 then
    v_charge := public.add_charge(p_booking, jsonb_build_object('name', left('Meals: ' || mp.name, 80), 'category', 'food',
      'qty', b.nights, 'unit_price_paise', v_night,
      'note', left(greatest(b.visitors, 1) || ' adult' || case when b.visitors > 1 then 's' else '' end
              || case when coalesce(b.children, 0) > 0 then ' + ' || b.children || ' child' || case when b.children > 1 then 'ren' else '' end else '' end
              || ', every night (' || v_meals || ')', 200),
      'charged_on', public._local_date(b.property_id, b.check_in_at)));
  end if;
  insert into public.booking_meals (booking_id, property_id, plan_id, plan_name, breakfast, lunch, dinner, adults, children, nights, amount_paise, charge_id)
  values (b.id, b.property_id, mp.id, mp.name, mp.breakfast, mp.lunch, mp.dinner, greatest(b.visitors, 1), coalesce(b.children, 0), b.nights,
          coalesce(v_amt, 0), nullif(v_charge->>'id', '')::uuid);
  return jsonb_build_object('plan', mp.name, 'amount_paise', coalesce(v_amt, 0));
end $$;

-- ---------------------------------------------------------------- kitchen list for a day
-- Breakfast on day D = guests who slept the night before (check-in < D ≤ check-out day).
-- Lunch and dinner on day D = guests sleeping the night of D (check-in ≤ D < check-out day).
create or replace function public.kitchen_list(p_property uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  return (with x as (
      select b.id, b.code, g.full_name, r.name as room, bd.label as unit, m.plan_name, m.breakfast, m.lunch, m.dinner,
             greatest(b.visitors, 1) as adults, coalesce(b.children, 0) as children,
             (b.check_in_at at time zone v_tz)::date as d_in, (b.check_out_at at time zone v_tz)::date as d_out, b.status
        from public.booking_meals m
        join public.bookings b on b.id = m.booking_id
        join public.guests g on g.id = b.guest_id
        join public.beds bd on bd.id = b.bed_id
        join public.rooms r on r.id = bd.room_id
       where m.property_id = p_property and b.status in ('pending','confirmed','checked_in','checked_out')
         and (b.check_in_at at time zone v_tz)::date <= p_day and (b.check_out_at at time zone v_tz)::date >= p_day),
    y as (select *, (breakfast and d_in < p_day) as has_b, (lunch and d_out > p_day) as has_l, (dinner and d_out > p_day) as has_d from x)
    select jsonb_build_object('day', p_day,
      'totals', jsonb_build_object(
        'breakfast', coalesce(sum(case when has_b then adults + children end), 0),
        'lunch', coalesce(sum(case when has_l then adults + children end), 0),
        'dinner', coalesce(sum(case when has_d then adults + children end), 0)),
      'rows', coalesce(jsonb_agg(jsonb_build_object('booking_id', id, 'code', code, 'guest', full_name, 'room', room, 'unit', unit,
          'plan', plan_name, 'adults', adults, 'children', children, 'breakfast', has_b, 'lunch', has_l, 'dinner', has_d)
          order by room, unit) filter (where has_b or has_l or has_d), '[]'::jsonb))
    from y);
end $$;

-- ---------------------------------------------------------------- house guide
create or replace function public.guide_get(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return coalesce((select to_jsonb(g) - 'property_id' from public.property_guide g where property_id = p_property), '{}'::jsonb);
end $$;

create or replace function public.guide_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t text[] := array['welcome','house_rules','wifi_name','wifi_password','directions','maps_url','host_name','host_phone','checkin_info','checkout_info','food_info'];
  v jsonb := '{}'::jsonb; k text; v_phone text;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  foreach k in array t loop v := v || jsonb_build_object(k, nullif(btrim(coalesce(p->>k, '')), '')); end loop;
  v_phone := nullif(regexp_replace(coalesce(v->>'host_phone', ''), '[\s\-()]', '', 'g'), '');
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the host phone number.'; end if;
  if v->>'maps_url' is not null and v->>'maps_url' !~* '^https?://' then raise exception 'The map link should start with https://'; end if;
  insert into public.property_guide as g (property_id, welcome, house_rules, wifi_name, wifi_password, directions, maps_url, host_name, host_phone,
                                          checkin_info, checkout_info, food_info, updated_at)
  values (p_property, v->>'welcome', v->>'house_rules', v->>'wifi_name', v->>'wifi_password', v->>'directions', v->>'maps_url', v->>'host_name',
          v_phone, v->>'checkin_info', v->>'checkout_info', v->>'food_info', now())
  on conflict (property_id) do update set welcome = excluded.welcome, house_rules = excluded.house_rules, wifi_name = excluded.wifi_name,
     wifi_password = excluded.wifi_password, directions = excluded.directions, maps_url = excluded.maps_url, host_name = excluded.host_name,
     host_phone = excluded.host_phone, checkin_info = excluded.checkin_info, checkout_info = excluded.checkout_info,
     food_info = excluded.food_info, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- The guest's own online check-in link → the house guide of that property (nothing else).
-- Only for live bookings; the Wi-Fi password is shown only from the check-in day on.
create or replace function public.guide_for_token(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select (to_jsonb(g) - 'property_id' - 'updated_at' - case when b.check_in_at > now() + interval '1 day' then 'wifi_password' else '' end)
           || jsonb_build_object('property', p.name)
      from public.bookings b
      join public.property_guide g on g.property_id = b.property_id
      join public.properties p on p.id = b.property_id
     where b.self_checkin_token = p_token and b.status in ('pending','confirmed','checked_in') and b.check_out_at > now()
     limit 1), '{}'::jsonb)
$$;

revoke execute on function public.meal_plans_list(uuid), public.meal_plan_save(uuid, jsonb), public.meal_plan_delete(uuid),
  public.booking_meal_get(uuid), public.booking_meal_set(uuid, uuid), public.kitchen_list(uuid, date),
  public.guide_get(uuid), public.guide_save(uuid, jsonb), public.guide_for_token(uuid) from public, anon;
grant execute on function public.meal_plans_list(uuid), public.meal_plan_save(uuid, jsonb), public.meal_plan_delete(uuid),
  public.booking_meal_get(uuid), public.booking_meal_set(uuid, uuid), public.kitchen_list(uuid, date),
  public.guide_get(uuid), public.guide_save(uuid, jsonb), public.guide_for_token(uuid) to authenticated;
grant execute on function public.guide_for_token(uuid) to anon;


-- =====================================================================
-- NammaStay · 034_resort.sql — resorts: activities & spa, day-out visitors,
-- stay packages, group & event bookings, extra beds
--
-- A resort is set up like a hotel (rooms / cottages / villas) with a resort switch
-- (table resort_properties), the same way PG / co-living works. Meal plans
-- (CP / MAP / AP) and the guest guide come from 033_homestay.sql and are reused.
--
--   • Activities & spa   time slots with capacity, per-person price; booked for an
--                        in-house guest (added to their bill as a normal extra) or a
--                        day visitor; "included" when the guest's stay package has it
--   • Day-out visitors   day packages without a room (e.g. pool + lunch), own receipts RP-…
--   • Stay packages      e.g. "2N/3D Honeymoon": fixed price per room incl. meal plan and
--                        activities → ONE "Package: …" extra on top of the room charge
--   • Group & event      many bookings under one group (wedding, corporate…), one group
--                        bill, one payment split across the rooms
--   • Extra beds         price per bed per night (Settings) → "Extra bed" extra on the bill
--
-- Money on room bookings always goes through the existing add_charge() / remove_charge()
-- and the payments table, so bills, invoices, reports and payments work as before.
--
-- ADD-ON ONLY — new tables and functions; nothing existing is changed.
-- Needs 033_homestay.sql (meal plans). Safe to run more than once.
-- =====================================================================

create sequence if not exists public.day_visit_seq start 1001;
create sequence if not exists public.resort_receipt_seq start 1001;

-- ---------------------------------------------------------------- tables
create table if not exists public.resort_properties (
  property_id uuid primary key references public.properties(id) on delete cascade,
  enabled_at  timestamptz not null default now(),
  enabled_by  uuid default auth.uid()
);

create table if not exists public.resort_settings (
  property_id     uuid primary key references public.properties(id) on delete cascade,
  extra_bed_paise int not null default 0 check (extra_bed_paise between 0 and 10000000),   -- per bed per night
  extra_bed_max   smallint not null default 1 check (extra_bed_max between 0 and 6),        -- per room
  updated_at      timestamptz not null default now()
);

create table if not exists public.activities (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 60),
  category     text not null default 'leisure' check (category in ('spa','adventure','leisure','kids','food','other')),
  duration_min smallint not null default 60 check (duration_min between 5 and 1440),
  price_paise  int not null default 0 check (price_paise between 0 and 10000000),          -- per adult
  child_paise  int not null default 0 check (child_paise between 0 and 10000000),          -- per child
  capacity     smallint not null default 0 check (capacity between 0 and 500),             -- people per slot, 0 = no limit
  slots        text[] not null default '{}',                                               -- 'HH:MM' start times
  is_active    boolean not null default true,
  sort         smallint not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists activities_property on public.activities (property_id, sort);

create table if not exists public.dayout_packages (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 60),
  includes     text check (char_length(includes) <= 300),
  lunch        boolean not null default false,
  adult_paise  int not null default 0 check (adult_paise between 0 and 10000000),
  child_paise  int not null default 0 check (child_paise between 0 and 10000000),
  capacity     smallint not null default 0 check (capacity between 0 and 2000),             -- people per day, 0 = no limit
  is_active    boolean not null default true,
  sort         smallint not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists dayout_packages_property on public.dayout_packages (property_id, sort);

create table if not exists public.day_visits (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  code          text not null,
  visit_date    date not null,
  guest_name    text not null check (char_length(btrim(guest_name)) between 2 and 120),
  phone         text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  adults        smallint not null default 1 check (adults between 1 and 500),
  children      smallint not null default 0 check (children between 0 and 500),
  package_id    uuid references public.dayout_packages(id) on delete set null,
  package_name  text not null,
  lunch         boolean not null default false,
  package_paise int not null default 0 check (package_paise >= 0),
  extras_paise  int not null default 0 check (extras_paise >= 0),                          -- activities booked for this visit
  paid_paise    int not null default 0 check (paid_paise >= 0),
  status        text not null default 'booked' check (status in ('booked','arrived','left','cancelled','no_show')),
  note          text check (char_length(note) <= 500),
  arrived_at    timestamptz,
  left_at       timestamptz,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (property_id, code),
  unique (id, property_id)
);
create index if not exists day_visits_day on public.day_visits (property_id, visit_date);

create table if not exists public.resort_payments (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null,
  day_visit_id uuid not null,
  code         text not null,
  kind         text not null default 'payment' check (kind in ('payment','refund')),
  method       text not null check (method in ('upi','cash','card','bank')),
  amount_paise int not null check (amount_paise > 0),
  reference    text check (char_length(reference) <= 60),
  note         text check (char_length(note) <= 200),
  received_at  timestamptz not null default now(),
  received_by  uuid default auth.uid(),
  foreign key (day_visit_id, property_id) references public.day_visits(id, property_id) on delete cascade
);
create unique index if not exists resort_payments_upi_ref on public.resort_payments (property_id, reference)
  where method = 'upi' and kind = 'payment' and reference is not null;
create index if not exists resort_payments_list on public.resort_payments (property_id, received_at desc);

create table if not exists public.stay_packages (
  id                uuid primary key default gen_random_uuid(),
  property_id       uuid not null references public.properties(id) on delete cascade,
  name              text not null check (char_length(btrim(name)) between 1 and 60),
  nights            smallint not null default 1 check (nights between 1 and 30),
  price_paise       int not null check (price_paise between 0 and 100000000),             -- per room, for base_guests adults
  base_guests       smallint not null default 2 check (base_guests between 1 and 20),
  extra_adult_paise int not null default 0 check (extra_adult_paise between 0 and 10000000),   -- per extra adult, whole package
  child_paise       int not null default 0 check (child_paise between 0 and 10000000),         -- per child, whole package
  meal_plan_id      uuid references public.meal_plans(id) on delete set null,
  activity_ids      uuid[] not null default '{}',
  includes          text check (char_length(includes) <= 500),
  is_active         boolean not null default true,
  sort              smallint not null default 0,
  created_at        timestamptz not null default now()
);
create index if not exists stay_packages_property on public.stay_packages (property_id, sort);

create table if not exists public.booking_packages (
  booking_id    uuid primary key,
  property_id   uuid not null,
  package_id    uuid references public.stay_packages(id) on delete set null,
  package_name  text not null,
  price_paise   int not null,
  room_paise    int not null,
  charge_id     uuid,
  activity_ids  uuid[] not null default '{}',
  applied_at    timestamptz not null default now(),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);

create table if not exists public.booking_groups (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 2 and 80),
  kind          text not null default 'other' check (kind in ('wedding','corporate','family','school','tour','other')),
  contact_name  text check (char_length(contact_name) <= 120),
  contact_phone text check (contact_phone is null or contact_phone ~ '^\+?[0-9]{8,15}$'),
  event_date    date,
  note          text check (char_length(note) <= 1000),
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (id, property_id)
);
create index if not exists booking_groups_property on public.booking_groups (property_id, created_at desc);

create table if not exists public.booking_group_members (
  booking_id  uuid primary key,
  group_id    uuid not null,
  property_id uuid not null,
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade,
  foreign key (group_id, property_id) references public.booking_groups(id, property_id) on delete cascade
);
create index if not exists booking_group_members_group on public.booking_group_members (group_id);

create table if not exists public.booking_extra_beds (
  booking_id   uuid primary key,
  property_id  uuid not null,
  beds         smallint not null check (beds between 1 and 6),
  price_paise  int not null,
  nights       smallint not null,
  charge_id    uuid,
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);

create table if not exists public.activity_bookings (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null,
  activity_id   uuid references public.activities(id) on delete set null,
  activity_name text not null,
  day           date not null,
  slot          text not null check (slot ~ '^[0-2][0-9]:[0-5][0-9]$'),
  booking_id    uuid,
  day_visit_id  uuid,
  guest_name    text not null,
  persons       smallint not null default 1 check (persons between 0 and 500),
  children      smallint not null default 0 check (children between 0 and 500),
  amount_paise  int not null default 0 check (amount_paise >= 0),
  included      boolean not null default false,
  status        text not null default 'booked' check (status in ('booked','done','cancelled','no_show')),
  charge_id     uuid,
  note          text check (char_length(note) <= 200),
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  check (booking_id is not null or day_visit_id is not null),
  check (persons + children >= 1),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade,
  foreign key (day_visit_id, property_id) references public.day_visits(id, property_id) on delete cascade
);
create index if not exists activity_bookings_day on public.activity_bookings (property_id, day, slot);
create index if not exists activity_bookings_booking on public.activity_bookings (booking_id);

do $$ declare t text; begin
  foreach t in array array['resort_properties','resort_settings','activities','dayout_packages','day_visits','resort_payments','stay_packages',
                           'booking_packages','booking_groups','booking_group_members','booking_extra_beds','activity_bookings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (property_id in (select public.my_property_ids()))', t || '_select', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);          -- writes only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function public._rs_view(p_property uuid) returns void
language sql stable security definer set search_path = public, pg_temp as $$
  select public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[])
$$;
create or replace function public._rs_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone public._tz(p_property))::date
$$;
create or replace function public._rs_rupees(p int) returns text language sql immutable as $$
  select '₹' || to_char(p / 100.0, 'FM99,99,99,990')
$$;
create or replace function public._rs_is_resort(p_property uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.resort_properties where property_id = p_property) then
    raise exception 'This is for resorts. Set the property type to Resort in Settings.';
  end if;
end $$;
-- stay charge of a booking (room part, after any discount), without extras
create or replace function public._rs_room_paise(b public.bookings) returns int language sql immutable as $$
  select greatest(0, b.total_paise - coalesce(b.charges_paise, 0))
$$;

-- ---------------------------------------------------------------- resort switch
create or replace function public.resort_mode(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.resort_properties where property_id = p_property)
     and exists (select 1 from public.property_members where property_id = p_property and user_id = auth.uid())
$$;

create or replace function public.resort_set_mode(p_property uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if p_on then
    if (select kind from public.properties where id = p_property) = 'hostel' then
      raise exception 'A resort sells rooms / cottages — set the type to Resort (not hostel).';
    end if;
    insert into public.resort_properties (property_id) values (p_property) on conflict do nothing;
  else
    delete from public.resort_properties where property_id = p_property;
  end if;
  return p_on;
end $$;

create or replace function public.resort_settings_get(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_build_object('extra_bed_paise', extra_bed_paise, 'extra_bed_max', extra_bed_max)
                     from public.resort_settings where property_id = p_property), jsonb_build_object('extra_bed_paise', 0, 'extra_bed_max', 1));
end $$;

create or replace function public.resort_settings_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_price int := coalesce(nullif(p->>'extra_bed_paise', '')::int, 0); v_max int := coalesce(nullif(p->>'extra_bed_max', '')::int, 1);
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if v_price < 0 or v_price > 10000000 then raise exception 'Enter an extra-bed price between ₹0 and ₹1,00,000.'; end if;
  if v_max < 0 or v_max > 6 then raise exception 'Up to 6 extra beds per room.'; end if;
  insert into public.resort_settings (property_id, extra_bed_paise, extra_bed_max) values (p_property, v_price, v_max)
  on conflict (property_id) do update set extra_bed_paise = excluded.extra_bed_paise, extra_bed_max = excluded.extra_bed_max, updated_at = now();
  return jsonb_build_object('extra_bed_paise', v_price, 'extra_bed_max', v_max);
end $$;

-- ---------------------------------------------------------------- activities (list / edit)
create or replace function public.activities_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'category', category, 'duration_min', duration_min,
      'price_paise', price_paise, 'child_paise', child_paise, 'capacity', capacity, 'slots', to_jsonb(slots), 'is_active', is_active)
      order by sort, created_at) from public.activities where property_id = p_property), '[]'::jsonb);
end $$;

create or replace function public.activity_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', '')); v_slots text[]; s text;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._rs_is_resort(p_property);
  if char_length(v_name) < 1 then raise exception 'Give the activity a name, e.g. “Ayurvedic massage”.'; end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_slots
    from jsonb_array_elements_text(coalesce(p->'slots', '[]'::jsonb)) x where btrim(x) <> '';
  foreach s in array v_slots loop
    if s !~ '^[0-2][0-9]:[0-5][0-9]$' or left(s, 2)::int > 23 then raise exception 'Times look like 07:00 or 16:30 (“%” isn’t).', s; end if;
  end loop;
  if cardinality(v_slots) = 0 then raise exception 'Add at least one start time, e.g. 07:00.'; end if;
  if cardinality(v_slots) > 24 then raise exception 'Up to 24 start times a day.'; end if;
  if v_id is null then
    if (select count(*) from public.activities where property_id = p_property) >= 60 then raise exception 'Up to 60 activities.'; end if;
    insert into public.activities (property_id, name, category, duration_min, price_paise, child_paise, capacity, slots, is_active, sort)
    values (p_property, left(v_name, 60), coalesce(nullif(p->>'category', ''), 'leisure'), coalesce(nullif(p->>'duration_min', '')::int, 60),
            coalesce(nullif(p->>'price_paise', '')::int, 0), coalesce(nullif(p->>'child_paise', '')::int, 0),
            coalesce(nullif(p->>'capacity', '')::int, 0), v_slots, coalesce((p->>'is_active')::boolean, true),
            coalesce((select max(sort) + 1 from public.activities where property_id = p_property), 0))
    returning id into v_id;
  else
    update public.activities set name = left(v_name, 60), category = coalesce(nullif(p->>'category', ''), category),
           duration_min = coalesce(nullif(p->>'duration_min', '')::int, duration_min), price_paise = coalesce(nullif(p->>'price_paise', '')::int, 0),
           child_paise = coalesce(nullif(p->>'child_paise', '')::int, 0), capacity = coalesce(nullif(p->>'capacity', '')::int, 0),
           slots = v_slots, is_active = coalesce((p->>'is_active')::boolean, is_active)
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Activity not found.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.activity_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.activities where id = p_id;
  if v_prop is null then raise exception 'Activity not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  if exists (select 1 from public.activity_bookings where activity_id = p_id and status = 'booked' and day >= public._rs_today(v_prop)) then
    raise exception 'This activity has upcoming bookings. Hide it instead (untick “Offered”), or cancel those bookings first.';
  end if;
  delete from public.activities where id = p_id;                     -- past bookings keep the activity's name
end $$;

-- ---------------------------------------------------------------- activities: day schedule / book / status
create or replace function public.activity_schedule(p_property uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._rs_view(p_property);
  return jsonb_build_object('day', p_day,
    'activities', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'category', a.category, 'duration_min', a.duration_min,
        'price_paise', a.price_paise, 'child_paise', a.child_paise, 'capacity', a.capacity, 'is_active', a.is_active,
        'slots', (select coalesce(jsonb_agg(jsonb_build_object('slot', s,
            'taken', coalesce((select sum(ab.persons + ab.children) from public.activity_bookings ab
                                where ab.activity_id = a.id and ab.day = p_day and ab.slot = s and ab.status in ('booked','done')), 0),
            'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', ab.id, 'guest', ab.guest_name, 'persons', ab.persons, 'children', ab.children,
                'amount_paise', ab.amount_paise, 'included', ab.included, 'status', ab.status, 'note', ab.note,
                'booking_id', ab.booking_id, 'day_visit_id', ab.day_visit_id,
                'where', coalesce((select r.name || ' · ' || bd.label from public.bookings bk join public.beds bd on bd.id = bk.bed_id
                                     join public.rooms r on r.id = bd.room_id where bk.id = ab.booking_id),
                                  (select 'Day visit ' || dv.code from public.day_visits dv where dv.id = ab.day_visit_id)))
                order by ab.created_at) from public.activity_bookings ab where ab.activity_id = a.id and ab.day = p_day and ab.slot = s), '[]'::jsonb))
            order by s), '[]'::jsonb) from unnest(a.slots) s))
        order by a.sort, a.created_at)
      from public.activities a where a.property_id = p_property and (a.is_active or exists (
        select 1 from public.activity_bookings x where x.activity_id = a.id and x.day = p_day))), '[]'::jsonb),
    'totals', jsonb_build_object(
      'bookings', (select count(*) from public.activity_bookings where property_id = p_property and day = p_day and status in ('booked','done')),
      'people', coalesce((select sum(persons + children) from public.activity_bookings where property_id = p_property and day = p_day and status in ('booked','done')), 0),
      'amount_paise', coalesce((select sum(amount_paise) from public.activity_bookings where property_id = p_property and day = p_day and status in ('booked','done')), 0)));
end $$;

-- who can book: in-house / upcoming room bookings and day visitors on that day
create or replace function public.activity_guests(p_property uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text := public._tz(p_property);
begin
  perform public._rs_view(p_property);
  return jsonb_build_object(
    'stays', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'code', b.code, 'guest', g.full_name, 'room', r.name, 'unit', bd.label,
        'adults', greatest(b.visitors, 1), 'children', coalesce(b.children, 0),
        'package', (select bp.package_name from public.booking_packages bp where bp.booking_id = b.id),
        'included', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select unnest(bp.activity_ids) x from public.booking_packages bp where bp.booking_id = b.id) q
                      where not exists (select 1 from public.activity_bookings ab where ab.booking_id = b.id and ab.activity_id = q.x and ab.included and ab.status <> 'cancelled')))
        order by r.name, bd.label)
      from public.bookings b join public.guests g on g.id = b.guest_id join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
      where b.property_id = p_property and b.status in ('pending','confirmed','checked_in')
        and (b.check_in_at at time zone v_tz)::date <= p_day and (b.check_out_at at time zone v_tz)::date >= p_day), '[]'::jsonb),
    'visits', coalesce((select jsonb_agg(jsonb_build_object('day_visit_id', dv.id, 'code', dv.code, 'guest', dv.guest_name, 'adults', dv.adults, 'children', dv.children)
        order by dv.code) from public.day_visits dv where dv.property_id = p_property and dv.visit_date = p_day and dv.status in ('booked','arrived')), '[]'::jsonb));
end $$;

create or replace function public.activity_book(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.activities; b public.bookings; dv public.day_visits;
  v_day date := nullif(p->>'day', '')::date; v_slot text := nullif(p->>'slot', '');
  v_ad int := coalesce(nullif(p->>'persons', '')::int, 1); v_ch int := coalesce(nullif(p->>'children', '')::int, 0);
  v_taken int; v_amt int; v_incl boolean := false; v_name text; v_tz text := public._tz(p_property); v_charge jsonb; v_id uuid;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  select * into a from public.activities where id = nullif(p->>'activity_id', '')::uuid and property_id = p_property;
  if a.id is null then raise exception 'Choose an activity.'; end if;
  if v_day is null then raise exception 'Choose the day.'; end if;
  if v_slot is null or not (v_slot = any (a.slots)) then raise exception 'Choose one of the start times for %.', a.name; end if;
  if v_ad < 0 or v_ch < 0 or v_ad + v_ch < 1 then raise exception 'Enter how many people.'; end if;
  if v_day < public._rs_today(p_property) - 1 then raise exception 'That day has passed.'; end if;
  select coalesce(sum(persons + children), 0) into v_taken from public.activity_bookings
   where activity_id = a.id and day = v_day and slot = v_slot and status in ('booked','done');
  if a.capacity > 0 and v_taken + v_ad + v_ch > a.capacity then
    raise exception '% at % has % place(s) left.', a.name, v_slot, greatest(a.capacity - v_taken, 0);
  end if;
  v_amt := a.price_paise * v_ad + a.child_paise * v_ch;

  if nullif(p->>'booking_id', '') is not null then
    select * into b from public.bookings where id = (p->>'booking_id')::uuid and property_id = p_property;
    if b.id is null then raise exception 'Booking not found.'; end if;
    if b.status not in ('pending','confirmed','checked_in') then raise exception 'That booking isn’t active.'; end if;
    if v_day < (b.check_in_at at time zone v_tz)::date or v_day > (b.check_out_at at time zone v_tz)::date then
      raise exception 'The guest isn’t staying on that day.';
    end if;
    select g.full_name into v_name from public.guests g where g.id = b.guest_id;
    -- included in their stay package (once per activity)?
    if exists (select 1 from public.booking_packages bp where bp.booking_id = b.id and a.id = any (bp.activity_ids))
       and not exists (select 1 from public.activity_bookings x where x.booking_id = b.id and x.activity_id = a.id and x.included and x.status <> 'cancelled')
       and coalesce((p->>'charge')::boolean, false) = false then
      v_incl := true; v_amt := 0;
    end if;
    insert into public.activity_bookings (property_id, activity_id, activity_name, day, slot, booking_id, guest_name, persons, children, amount_paise, included, note)
    values (p_property, a.id, a.name, v_day, v_slot, b.id, v_name, v_ad, v_ch, v_amt, v_incl, nullif(left(btrim(coalesce(p->>'note', '')), 200), ''))
    returning id into v_id;
    if v_amt > 0 then
      v_charge := public.add_charge(b.id, jsonb_build_object('name', left('Activity: ' || a.name, 80), 'category', case when a.category = 'food' then 'food' else 'tour' end,
        'qty', 1, 'unit_price_paise', v_amt, 'charged_on', v_day,
        'note', left(to_char(v_day, 'DD Mon') || ' ' || v_slot || ' · ' || v_ad || ' adult' || case when v_ad <> 1 then 's' else '' end
                     || case when v_ch > 0 then ' + ' || v_ch || ' child' || case when v_ch > 1 then 'ren' else '' end else '' end, 200)));
      update public.activity_bookings set charge_id = (v_charge->>'id')::uuid where id = v_id;
    end if;
  elsif nullif(p->>'day_visit_id', '') is not null then
    select * into dv from public.day_visits where id = (p->>'day_visit_id')::uuid and property_id = p_property for update;
    if dv.id is null then raise exception 'Day visit not found.'; end if;
    if dv.status in ('cancelled','no_show','left') then raise exception 'That day visit isn’t active.'; end if;
    if v_day <> dv.visit_date then raise exception 'The day visit is on %.', to_char(dv.visit_date, 'DD Mon'); end if;
    insert into public.activity_bookings (property_id, activity_id, activity_name, day, slot, day_visit_id, guest_name, persons, children, amount_paise, note)
    values (p_property, a.id, a.name, v_day, v_slot, dv.id, dv.guest_name, v_ad, v_ch, v_amt, nullif(left(btrim(coalesce(p->>'note', '')), 200), ''))
    returning id into v_id;
    update public.day_visits set extras_paise = extras_paise + v_amt where id = dv.id;
  else
    raise exception 'Choose the guest (a room booking or a day visitor).';
  end if;
  return jsonb_build_object('id', v_id, 'amount_paise', v_amt, 'included', v_incl);
end $$;

create or replace function public.activity_booking_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare ab public.activity_bookings; dv public.day_visits;
begin
  select * into ab from public.activity_bookings where id = p_id for update;
  if ab.id is null then raise exception 'Activity booking not found.'; end if;
  perform public._assert_role(ab.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if p_status not in ('booked','done','cancelled','no_show') then raise exception 'Unknown status.'; end if;
  if ab.status = 'cancelled' then raise exception 'This activity booking was cancelled.'; end if;
  if p_status = 'cancelled' then
    if ab.charge_id is not null and exists (select 1 from public.booking_charges where id = ab.charge_id) then
      perform public.remove_charge(ab.charge_id);                    -- refused if the guest already paid for it
    end if;
    if ab.day_visit_id is not null and ab.amount_paise > 0 then
      select * into dv from public.day_visits where id = ab.day_visit_id for update;
      if dv.package_paise + dv.extras_paise - ab.amount_paise < dv.paid_paise then
        raise exception 'The visitor has already paid for this. Give a refund first.';
      end if;
      update public.day_visits set extras_paise = greatest(0, extras_paise - ab.amount_paise) where id = dv.id;
    end if;
  end if;
  update public.activity_bookings set status = p_status where id = p_id;
  return jsonb_build_object('id', p_id, 'status', p_status);
end $$;

-- ---------------------------------------------------------------- day-out packages + visits
create or replace function public.dayout_packages_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'includes', includes, 'lunch', lunch, 'adult_paise', adult_paise,
      'child_paise', child_paise, 'capacity', capacity, 'is_active', is_active) order by sort, created_at)
    from public.dayout_packages where property_id = p_property), '[]'::jsonb);
end $$;

create or replace function public.dayout_package_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', ''));
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._rs_is_resort(p_property);
  if char_length(v_name) < 1 then raise exception 'Give the day package a name, e.g. “Pool + lunch”.'; end if;
  if v_id is null then
    if (select count(*) from public.dayout_packages where property_id = p_property) >= 20 then raise exception 'Up to 20 day packages.'; end if;
    insert into public.dayout_packages (property_id, name, includes, lunch, adult_paise, child_paise, capacity, is_active, sort)
    values (p_property, left(v_name, 60), nullif(left(btrim(coalesce(p->>'includes', '')), 300), ''), coalesce((p->>'lunch')::boolean, false),
            coalesce(nullif(p->>'adult_paise', '')::int, 0), coalesce(nullif(p->>'child_paise', '')::int, 0), coalesce(nullif(p->>'capacity', '')::int, 0),
            coalesce((p->>'is_active')::boolean, true), coalesce((select max(sort) + 1 from public.dayout_packages where property_id = p_property), 0))
    returning id into v_id;
  else
    update public.dayout_packages set name = left(v_name, 60), includes = nullif(left(btrim(coalesce(p->>'includes', '')), 300), ''),
           lunch = coalesce((p->>'lunch')::boolean, lunch), adult_paise = coalesce(nullif(p->>'adult_paise', '')::int, 0),
           child_paise = coalesce(nullif(p->>'child_paise', '')::int, 0), capacity = coalesce(nullif(p->>'capacity', '')::int, 0),
           is_active = coalesce((p->>'is_active')::boolean, is_active)
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Day package not found.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.dayout_package_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.dayout_packages where id = p_id;
  if v_prop is null then raise exception 'Day package not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.dayout_packages where id = p_id;                 -- visits keep the package name and price
end $$;

create or replace function public._dv_row(dv public.day_visits) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', dv.id, 'code', dv.code, 'visit_date', dv.visit_date, 'guest', dv.guest_name, 'phone', dv.phone,
    'adults', dv.adults, 'children', dv.children, 'package_id', dv.package_id, 'package', dv.package_name, 'lunch', dv.lunch,
    'package_paise', dv.package_paise, 'extras_paise', dv.extras_paise, 'total_paise', dv.package_paise + dv.extras_paise,
    'paid_paise', dv.paid_paise, 'balance_paise', dv.package_paise + dv.extras_paise - dv.paid_paise, 'status', dv.status, 'note', dv.note,
    'arrived_at', dv.arrived_at, 'left_at', dv.left_at,
    'activities', coalesce((select jsonb_agg(jsonb_build_object('id', ab.id, 'name', ab.activity_name, 'slot', ab.slot, 'persons', ab.persons + ab.children,
        'amount_paise', ab.amount_paise, 'status', ab.status) order by ab.slot) from public.activity_bookings ab where ab.day_visit_id = dv.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', rp.id, 'code', rp.code, 'kind', rp.kind, 'method', rp.method, 'amount_paise', rp.amount_paise,
        'reference', rp.reference, 'received_at', rp.received_at) order by rp.received_at) from public.resort_payments rp where rp.day_visit_id = dv.id), '[]'::jsonb))
$$;

create or replace function public.day_visits_list(p_property uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._rs_view(p_property);
  return jsonb_build_object('day', p_day,
    'visits', coalesce((select jsonb_agg(public._dv_row(dv) order by dv.status = 'cancelled', dv.code) from public.day_visits dv
                         where dv.property_id = p_property and dv.visit_date = p_day), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'visits', count(*) filter (where status not in ('cancelled','no_show')),
        'people', coalesce(sum(adults + children) filter (where status not in ('cancelled','no_show')), 0),
        'arrived', coalesce(sum(adults + children) filter (where status in ('arrived','left')), 0),
        'lunches', coalesce(sum(adults + children) filter (where lunch and status not in ('cancelled','no_show')), 0),
        'billed_paise', coalesce(sum(package_paise + extras_paise) filter (where status not in ('cancelled','no_show')), 0),
        'collected_paise', coalesce((select sum(case when rp.kind = 'refund' then -rp.amount_paise else rp.amount_paise end) from public.resort_payments rp
                                      join public.day_visits d2 on d2.id = rp.day_visit_id where d2.property_id = p_property and d2.visit_date = p_day), 0))
      from public.day_visits where property_id = p_property and visit_date = p_day));
end $$;

create or replace function public._rs_pay(dv public.day_visits, p jsonb, p_kind text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_amt int := coalesce(nullif(p->>'amount_paise', '')::int, 0); v_method text := coalesce(nullif(p->>'method', ''), 'cash');
  v_ref text := nullif(upper(regexp_replace(coalesce(p->>'reference', ''), '\s', '', 'g')), ''); v_code text; v_bal int;
begin
  if v_amt <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if v_method not in ('upi','cash','card','bank') then raise exception 'Choose a payment method.'; end if;
  v_bal := dv.package_paise + dv.extras_paise - dv.paid_paise;
  if p_kind = 'payment' then
    perform public._require_perm(dv.property_id, 'record_payments');
    if v_amt > v_bal then raise exception 'Only % is due.', public._rs_rupees(greatest(v_bal, 0)); end if;
    if v_method = 'upi' and (v_ref is null or v_ref !~ '^[0-9A-Z]{6,35}$') then raise exception 'Enter the UPI transaction ID (UTR).'; end if;
  else
    perform public._require_perm(dv.property_id, 'refunds');
    if v_amt > dv.paid_paise then raise exception 'Refund is more than the amount paid.'; end if;
  end if;
  v_code := 'RP-' || nextval('public.resort_receipt_seq');
  begin
    insert into public.resort_payments (property_id, day_visit_id, code, kind, method, amount_paise, reference, note)
    values (dv.property_id, dv.id, v_code, p_kind, v_method, v_amt, v_ref, nullif(left(btrim(coalesce(p->>'note', '')), 200), ''));
  exception when unique_violation then raise exception 'UPI transaction % was already recorded.', v_ref; end;
  update public.day_visits set paid_paise = paid_paise + case when p_kind = 'refund' then -v_amt else v_amt end where id = dv.id;
  return jsonb_build_object('code', v_code, 'amount_paise', v_amt);
end $$;

create or replace function public.day_visit_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; pk public.dayout_packages; dv public.day_visits;
  v_day date := coalesce(nullif(p->>'visit_date', '')::date, public._rs_today(p_property));
  v_ad int := coalesce(nullif(p->>'adults', '')::int, 1); v_ch int := coalesce(nullif(p->>'children', '')::int, 0);
  v_name text := btrim(coalesce(p->>'guest', '')); v_phone text := nullif(regexp_replace(coalesce(p->>'phone', ''), '[\s\-()]', '', 'g'), '');
  v_taken int; v_pay jsonb := p->'payment';
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  perform public._rs_is_resort(p_property);
  if char_length(v_name) < 2 then raise exception 'Enter the visitor’s name.'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the phone number.'; end if;
  if v_ad < 1 then raise exception 'At least 1 adult.'; end if;
  if v_ch < 0 then raise exception 'Check the number of children.'; end if;
  if v_id is not null then                                               -- edit name / phone / note only
    update public.day_visits set guest_name = left(v_name, 120), phone = v_phone, note = nullif(left(btrim(coalesce(p->>'note', '')), 500), '')
     where id = v_id and property_id = p_property returning * into dv;
    if dv.id is null then raise exception 'Day visit not found.'; end if;
    return public._dv_row(dv);
  end if;
  select * into pk from public.dayout_packages where id = nullif(p->>'package_id', '')::uuid and property_id = p_property;
  if pk.id is null then raise exception 'Choose a day package.'; end if;
  if v_day < public._rs_today(p_property) then raise exception 'The visit day can’t be in the past.'; end if;
  if pk.capacity > 0 then
    select coalesce(sum(adults + children), 0) into v_taken from public.day_visits
     where property_id = p_property and package_id = pk.id and visit_date = v_day and status not in ('cancelled','no_show');
    if v_taken + v_ad + v_ch > pk.capacity then raise exception '% has % place(s) left on %.', pk.name, greatest(pk.capacity - v_taken, 0), to_char(v_day, 'DD Mon'); end if;
  end if;
  insert into public.day_visits (property_id, code, visit_date, guest_name, phone, adults, children, package_id, package_name, lunch, package_paise, note)
  values (p_property, 'DV-' || nextval('public.day_visit_seq'), v_day, left(v_name, 120), v_phone, v_ad, v_ch, pk.id, pk.name, pk.lunch,
          pk.adult_paise * v_ad + pk.child_paise * v_ch, nullif(left(btrim(coalesce(p->>'note', '')), 500), ''))
  returning * into dv;
  if v_pay is not null and coalesce(nullif(v_pay->>'amount_paise', '')::int, 0) > 0 then
    perform public._rs_pay(dv, v_pay, 'payment');
    select * into dv from public.day_visits where id = dv.id;
  end if;
  if coalesce((p->>'arrived')::boolean, false) then
    update public.day_visits set status = 'arrived', arrived_at = now() where id = dv.id returning * into dv;
  end if;
  return public._dv_row(dv);
end $$;

create or replace function public.day_visit_pay(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare dv public.day_visits;
begin
  select * into dv from public.day_visits where id = p_id for update;
  if dv.id is null then raise exception 'Day visit not found.'; end if;
  perform public._assert_role(dv.property_id, case when coalesce(p->>'kind', 'payment') = 'refund'
    then array['owner','manager']::public.member_role[] else array['owner','manager','front_desk','accountant']::public.member_role[] end);
  if coalesce(p->>'kind', 'payment') = 'payment' and dv.status in ('cancelled','no_show') then raise exception 'This day visit was cancelled.'; end if;
  return public._rs_pay(dv, p, case when p->>'kind' = 'refund' then 'refund' else 'payment' end);
end $$;

create or replace function public.day_visit_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare dv public.day_visits;
begin
  select * into dv from public.day_visits where id = p_id for update;
  if dv.id is null then raise exception 'Day visit not found.'; end if;
  perform public._assert_role(dv.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if p_status not in ('booked','arrived','left','cancelled','no_show') then raise exception 'Unknown status.'; end if;
  if p_status in ('cancelled','no_show') and dv.paid_paise > 0 then
    raise exception 'The visitor has paid % — give a refund first, then cancel.', public._rs_rupees(dv.paid_paise);
  end if;
  update public.day_visits set status = p_status,
         arrived_at = case when p_status = 'arrived' then coalesce(arrived_at, now()) else arrived_at end,
         left_at = case when p_status = 'left' then now() else left_at end
   where id = p_id returning * into dv;
  if p_status in ('cancelled','no_show') then
    update public.activity_bookings set status = 'cancelled' where day_visit_id = dv.id and status = 'booked';
    update public.day_visits set extras_paise = 0 where id = dv.id returning * into dv;
  end if;
  return public._dv_row(dv);
end $$;

-- money from day visitors (for Expenses & profit), by month
create or replace function public.resort_income(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text := public._tz(p_property);
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  return (with x as (select to_char((received_at at time zone v_tz)::date, 'YYYY-MM') as month,
                            case when kind = 'refund' then -amount_paise else amount_paise end as amt
                       from public.resort_payments where property_id = p_property
                        and (received_at at time zone v_tz)::date between p_from and p_to)
    select jsonb_build_object('total_paise', coalesce(sum(amt), 0),
      'months', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'income_paise', s) order by month)
                            from (select month, sum(amt) s from x group by month) m), '[]'::jsonb)) from x);
end $$;

-- ---------------------------------------------------------------- stay packages
create or replace function public.stay_packages_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(jsonb_build_object('id', sp.id, 'name', sp.name, 'nights', sp.nights, 'price_paise', sp.price_paise,
      'base_guests', sp.base_guests, 'extra_adult_paise', sp.extra_adult_paise, 'child_paise', sp.child_paise, 'meal_plan_id', sp.meal_plan_id,
      'meal_plan', (select name from public.meal_plans where id = sp.meal_plan_id), 'activity_ids', to_jsonb(sp.activity_ids),
      'activities', (select coalesce(jsonb_agg(a.name order by a.sort), '[]'::jsonb) from public.activities a where a.id = any (sp.activity_ids)),
      'includes', sp.includes, 'is_active', sp.is_active) order by sp.sort, sp.created_at)
    from public.stay_packages sp where sp.property_id = p_property), '[]'::jsonb);
end $$;

create or replace function public.stay_package_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', '')); v_meal uuid := nullif(p->>'meal_plan_id', '')::uuid;
  v_acts uuid[];
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._rs_is_resort(p_property);
  if char_length(v_name) < 1 then raise exception 'Give the package a name, e.g. “2N/3D Honeymoon”.'; end if;
  if coalesce(nullif(p->>'price_paise', '')::int, 0) <= 0 then raise exception 'Enter the package price.'; end if;
  if v_meal is not null and not exists (select 1 from public.meal_plans where id = v_meal and property_id = p_property) then
    raise exception 'That meal plan isn’t in your list.';
  end if;
  select coalesce(array_agg(a.id), '{}') into v_acts from public.activities a
   where a.property_id = p_property and a.id in (select x::uuid from jsonb_array_elements_text(coalesce(p->'activity_ids', '[]'::jsonb)) x);
  if v_id is null then
    if (select count(*) from public.stay_packages where property_id = p_property) >= 30 then raise exception 'Up to 30 packages.'; end if;
    insert into public.stay_packages (property_id, name, nights, price_paise, base_guests, extra_adult_paise, child_paise, meal_plan_id, activity_ids, includes, is_active, sort)
    values (p_property, left(v_name, 60), coalesce(nullif(p->>'nights', '')::int, 1), (p->>'price_paise')::int, coalesce(nullif(p->>'base_guests', '')::int, 2),
            coalesce(nullif(p->>'extra_adult_paise', '')::int, 0), coalesce(nullif(p->>'child_paise', '')::int, 0), v_meal, v_acts,
            nullif(left(btrim(coalesce(p->>'includes', '')), 500), ''), coalesce((p->>'is_active')::boolean, true),
            coalesce((select max(sort) + 1 from public.stay_packages where property_id = p_property), 0))
    returning id into v_id;
  else
    update public.stay_packages set name = left(v_name, 60), nights = coalesce(nullif(p->>'nights', '')::int, nights), price_paise = (p->>'price_paise')::int,
           base_guests = coalesce(nullif(p->>'base_guests', '')::int, base_guests), extra_adult_paise = coalesce(nullif(p->>'extra_adult_paise', '')::int, 0),
           child_paise = coalesce(nullif(p->>'child_paise', '')::int, 0), meal_plan_id = v_meal, activity_ids = v_acts,
           includes = nullif(left(btrim(coalesce(p->>'includes', '')), 500), ''), is_active = coalesce((p->>'is_active')::boolean, is_active)
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Package not found.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.stay_package_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.stay_packages where id = p_id;
  if v_prop is null then raise exception 'Package not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.stay_packages where id = p_id;                   -- bookings keep their package line
end $$;

-- price of a package for a booking's guests
create or replace function public._sp_price(sp public.stay_packages, b public.bookings) returns int language sql immutable as $$
  select sp.price_paise + sp.extra_adult_paise * greatest(greatest(b.visitors, 1) - sp.base_guests, 0) + sp.child_paise * coalesce(b.children, 0)
$$;

-- p_package null = no package (removes the package line, the included meal plan stays as "room only")
create or replace function public.booking_package_set(p_booking uuid, p_package uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; sp public.stay_packages; old public.booking_packages; v_room int; v_price int; v_diff int; v_charge jsonb; om public.booking_meals; mp public.meal_plans;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if b.status not in ('pending','confirmed','checked_in') then raise exception 'Packages can be set only on active bookings.'; end if;
  select * into old from public.booking_packages where booking_id = p_booking for update;
  if old.booking_id is not null then
    if old.charge_id is not null and exists (select 1 from public.booking_charges where id = old.charge_id) then perform public.remove_charge(old.charge_id); end if;
    delete from public.booking_meals where booking_id = p_booking and amount_paise = 0 and charge_id is null;      -- the package's meal plan
    delete from public.booking_packages where booking_id = p_booking;
    select * into b from public.bookings where id = p_booking;
  end if;
  if p_package is null then return jsonb_build_object('package', null); end if;

  select * into sp from public.stay_packages where id = p_package and property_id = b.property_id;
  if sp.id is null then raise exception 'That package isn’t in your list any more.'; end if;
  if b.nights <> sp.nights then
    raise exception '% is for % night(s) — change the dates to % night(s) first.', sp.name, sp.nights, sp.nights;
  end if;
  v_room := public._rs_room_paise(b);
  v_price := public._sp_price(sp, b);
  v_diff := v_price - v_room;
  if v_diff < 0 then
    raise exception 'The package price (%) is less than the room charge (%) for these nights. Lower the room rate on the booking, or raise the package price.',
      public._rs_rupees(v_price), public._rs_rupees(v_room);
  end if;
  if v_diff > 0 then
    v_charge := public.add_charge(b.id, jsonb_build_object('name', left('Package: ' || sp.name, 80), 'category', 'other', 'qty', 1, 'unit_price_paise', v_diff,
      'charged_on', public._local_date(b.property_id, b.check_in_at),
      'note', left('Package ' || public._rs_rupees(v_price) || ' = room ' || public._rs_rupees(v_room) || ' + inclusions', 200)));
  end if;
  insert into public.booking_packages (booking_id, property_id, package_id, package_name, price_paise, room_paise, charge_id, activity_ids)
  values (b.id, b.property_id, sp.id, sp.name, v_price, v_room, nullif(v_charge->>'id', '')::uuid, sp.activity_ids);
  -- the package's meal plan: included (₹0 on the bill), counted in the kitchen list
  if sp.meal_plan_id is not null then
    select * into om from public.booking_meals where booking_id = b.id;
    if om.booking_id is not null then
      if om.charge_id is not null and exists (select 1 from public.booking_charges where id = om.charge_id) then perform public.remove_charge(om.charge_id); end if;
      delete from public.booking_meals where booking_id = b.id;
    end if;
    select * into mp from public.meal_plans where id = sp.meal_plan_id;
    insert into public.booking_meals (booking_id, property_id, plan_id, plan_name, breakfast, lunch, dinner, adults, children, nights, amount_paise, charge_id, note)
    values (b.id, b.property_id, mp.id, mp.name || ' (in package)', mp.breakfast, mp.lunch, mp.dinner, greatest(b.visitors, 1), coalesce(b.children, 0), b.nights, 0, null,
            'Included in ' || sp.name);
  end if;
  return jsonb_build_object('package', sp.name, 'price_paise', v_price, 'room_paise', v_room, 'charge_paise', greatest(v_diff, 0));
end $$;

-- ---------------------------------------------------------------- extra beds
create or replace function public.booking_extra_beds_set(p_booking uuid, p_beds int) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; s public.resort_settings; old public.booking_extra_beds; v_charge jsonb;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  perform public._require_perm(b.property_id, 'add_extras');
  if b.status not in ('pending','confirmed','checked_in') then raise exception 'Extra beds can be set only on active bookings.'; end if;
  select * into s from public.resort_settings where property_id = b.property_id;
  if coalesce(p_beds, 0) > coalesce(s.extra_bed_max, 1) then raise exception 'Up to % extra bed(s) per room.', coalesce(s.extra_bed_max, 1); end if;
  select * into old from public.booking_extra_beds where booking_id = p_booking for update;
  if old.booking_id is not null then
    if old.charge_id is not null and exists (select 1 from public.booking_charges where id = old.charge_id) then perform public.remove_charge(old.charge_id); end if;
    delete from public.booking_extra_beds where booking_id = p_booking;
  end if;
  if coalesce(p_beds, 0) <= 0 then return jsonb_build_object('beds', 0); end if;
  if coalesce(s.extra_bed_paise, 0) > 0 then
    v_charge := public.add_charge(b.id, jsonb_build_object('name', 'Extra bed' || case when p_beds > 1 then ' × ' || p_beds else '' end, 'category', 'rental',
      'qty', b.nights, 'unit_price_paise', s.extra_bed_paise * p_beds, 'charged_on', public._local_date(b.property_id, b.check_in_at),
      'note', p_beds || ' bed' || case when p_beds > 1 then 's' else '' end || ' × ' || public._rs_rupees(s.extra_bed_paise) || ' a night'));
  end if;
  insert into public.booking_extra_beds (booking_id, property_id, beds, price_paise, nights, charge_id)
  values (b.id, b.property_id, p_beds, coalesce(s.extra_bed_paise, 0), b.nights, nullif(v_charge->>'id', '')::uuid);
  return jsonb_build_object('beds', p_beds, 'amount_paise', coalesce(s.extra_bed_paise, 0) * p_beds * b.nights);
end $$;

-- everything resort about one booking (booking page card)
create or replace function public.booking_resort_get(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found.' using errcode = 'P0404'; end if;
  perform public._rs_view(b.property_id);
  return jsonb_build_object(
    'package', (select jsonb_build_object('package_id', package_id, 'name', package_name, 'price_paise', price_paise, 'room_paise', room_paise,
                 'activities', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name,
                    'used', exists (select 1 from public.activity_bookings x where x.booking_id = b.id and x.activity_id = a.id and x.included and x.status <> 'cancelled'))), '[]'::jsonb)
                    from public.activities a where a.id = any (bp.activity_ids)))
                from public.booking_packages bp where bp.booking_id = b.id),
    'extra_beds', coalesce((select beds from public.booking_extra_beds where booking_id = b.id), 0),
    'settings', public.resort_settings_get(b.property_id),
    'group', (select jsonb_build_object('id', g.id, 'name', g.name, 'kind', g.kind) from public.booking_group_members m join public.booking_groups g on g.id = m.group_id where m.booking_id = b.id),
    'activities', coalesce((select jsonb_agg(jsonb_build_object('id', ab.id, 'name', ab.activity_name, 'day', ab.day, 'slot', ab.slot, 'persons', ab.persons + ab.children,
        'amount_paise', ab.amount_paise, 'included', ab.included, 'status', ab.status) order by ab.day, ab.slot) from public.activity_bookings ab where ab.booking_id = b.id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- groups & events
create or replace function public._grp_row(g public.booking_groups) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', g.id, 'name', g.name, 'kind', g.kind, 'contact_name', g.contact_name, 'contact_phone', g.contact_phone,
    'event_date', g.event_date, 'note', g.note, 'created_at', g.created_at,
    'rooms', (select count(*) from public.booking_group_members m join public.bookings b on b.id = m.booking_id where m.group_id = g.id and b.status not in ('cancelled','no_show')),
    'guests', (select coalesce(sum(greatest(b.visitors, 1) + coalesce(b.children, 0)), 0) from public.booking_group_members m join public.bookings b on b.id = m.booking_id
                where m.group_id = g.id and b.status not in ('cancelled','no_show')),
    'check_in_at', (select min(b.check_in_at) from public.booking_group_members m join public.bookings b on b.id = m.booking_id where m.group_id = g.id and b.status not in ('cancelled','no_show')),
    'check_out_at', (select max(b.check_out_at) from public.booking_group_members m join public.bookings b on b.id = m.booking_id where m.group_id = g.id and b.status not in ('cancelled','no_show')),
    'total_paise', (select coalesce(sum(b.total_paise), 0) from public.booking_group_members m join public.bookings b on b.id = m.booking_id where m.group_id = g.id and b.status not in ('cancelled','no_show')),
    'paid_paise', (select coalesce(sum(b.paid_paise), 0) from public.booking_group_members m join public.bookings b on b.id = m.booking_id where m.group_id = g.id),
    'balance_paise', (select coalesce(sum(b.balance_paise), 0) from public.booking_group_members m join public.bookings b on b.id = m.booking_id where m.group_id = g.id and b.status not in ('cancelled','no_show')))
$$;

create or replace function public.groups_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(public._grp_row(g) order by g.created_at desc) from public.booking_groups g where g.property_id = p_property), '[]'::jsonb);
end $$;

create or replace function public.group_get(p_group uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare g public.booking_groups;
begin
  select * into g from public.booking_groups where id = p_group;
  if g.id is null then raise exception 'Group not found.' using errcode = 'P0404'; end if;
  perform public._rs_view(g.property_id);
  return public._grp_row(g) || jsonb_build_object('bookings', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'status', b.status,
      'guest', gu.full_name, 'phone', gu.phone, 'room', r.name, 'unit', bd.label, 'adults', greatest(b.visitors, 1), 'children', coalesce(b.children, 0),
      'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at, 'nights', b.nights, 'total_paise', b.total_paise, 'paid_paise', b.paid_paise,
      'balance_paise', b.balance_paise, 'charges_paise', coalesce(b.charges_paise, 0)) order by r.name, bd.label)
    from public.booking_group_members m join public.bookings b on b.id = m.booking_id join public.guests gu on gu.id = b.guest_id
    join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id where m.group_id = g.id), '[]'::jsonb),
    'property', (select jsonb_build_object('name', name, 'address', address, 'city', city, 'phone', phone, 'upi_id', upi_id) from public.properties where id = g.property_id));
end $$;

create or replace function public.group_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', '')); g public.booking_groups;
  v_phone text := nullif(regexp_replace(coalesce(p->>'contact_phone', ''), '[\s\-()]', '', 'g'), ''); x text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  perform public._rs_is_resort(p_property);
  if char_length(v_name) < 2 then raise exception 'Give the group a name, e.g. “Priya & Arjun wedding”.'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the contact phone number.'; end if;
  if v_id is null then
    insert into public.booking_groups (property_id, name, kind, contact_name, contact_phone, event_date, note)
    values (p_property, left(v_name, 80), coalesce(nullif(p->>'kind', ''), 'other'), nullif(left(btrim(coalesce(p->>'contact_name', '')), 120), ''), v_phone,
            nullif(p->>'event_date', '')::date, nullif(left(btrim(coalesce(p->>'note', '')), 1000), ''))
    returning * into g;
  else
    update public.booking_groups set name = left(v_name, 80), kind = coalesce(nullif(p->>'kind', ''), kind),
           contact_name = nullif(left(btrim(coalesce(p->>'contact_name', '')), 120), ''), contact_phone = v_phone,
           event_date = nullif(p->>'event_date', '')::date, note = nullif(left(btrim(coalesce(p->>'note', '')), 1000), '')
     where id = v_id and property_id = p_property returning * into g;
    if g.id is null then raise exception 'Group not found.'; end if;
  end if;
  for x in select jsonb_array_elements_text(coalesce(p->'booking_ids', '[]'::jsonb)) loop
    if not exists (select 1 from public.bookings where id = x::uuid and property_id = p_property) then raise exception 'Booking not found.'; end if;
    insert into public.booking_group_members (booking_id, group_id, property_id) values (x::uuid, g.id, p_property)
    on conflict (booking_id) do update set group_id = excluded.group_id;
  end loop;
  return public._grp_row(g);
end $$;

create or replace function public.group_remove_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.booking_group_members where booking_id = p_booking;
  if v_prop is null then return; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  delete from public.booking_group_members where booking_id = p_booking;
end $$;

create or replace function public.group_delete(p_group uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.booking_groups where id = p_group;
  if v_prop is null then raise exception 'Group not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.booking_groups where id = p_group;               -- the bookings themselves stay
end $$;

-- one payment for the whole group: split over the rooms, earliest check-in first, through the normal payments table
create or replace function public.group_pay(p_group uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.booking_groups; v_left int := coalesce(nullif(p->>'amount_paise', '')::int, 0); v_method text := coalesce(nullif(p->>'method', ''), 'upi');
  v_ref text := nullif(upper(regexp_replace(coalesce(p->>'reference', ''), '\s', '', 'g')), ''); v_bal int; r record; v_part int; v_n int := 0; v_codes text[] := '{}'; v_code text;
begin
  select * into g from public.booking_groups where id = p_group;
  if g.id is null then raise exception 'Group not found.'; end if;
  perform public._assert_role(g.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._require_perm(g.property_id, 'record_payments');
  if v_left <= 0 then raise exception 'Enter the amount received.'; end if;
  if v_method not in ('upi','cash','card','bank') then raise exception 'Choose a payment method.'; end if;
  if v_method = 'upi' and (v_ref is null or v_ref !~ '^[0-9A-Z]{6,35}$') then raise exception 'Enter the UPI transaction ID (UTR).'; end if;
  select coalesce(sum(b.balance_paise), 0) into v_bal from public.booking_group_members m join public.bookings b on b.id = m.booking_id
   where m.group_id = g.id and b.status not in ('cancelled','no_show') and b.balance_paise > 0;
  if v_left > v_bal then raise exception 'Only % is due for this group.', public._rs_rupees(v_bal); end if;
  for r in select b.id, b.balance_paise from public.booking_group_members m join public.bookings b on b.id = m.booking_id
            where m.group_id = g.id and b.status not in ('cancelled','no_show') and b.balance_paise > 0 order by b.check_in_at, b.code for update of b loop
    exit when v_left <= 0;
    v_part := least(v_left, r.balance_paise); v_n := v_n + 1;
    begin
      insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, note)
      values (g.property_id, r.id, 'payment', v_method::public.payment_method, v_part, case when v_n = 1 then v_ref end,
              left('Group payment · ' || g.name || case when v_ref is not null and v_n > 1 then ' · UTR ' || v_ref else '' end, 200))
      returning code into v_code;
    exception when unique_violation then raise exception 'UPI transaction % was already recorded.', v_ref; end;
    v_codes := v_codes || v_code;
    v_left := v_left - v_part;
  end loop;
  return jsonb_build_object('receipts', to_jsonb(v_codes), 'rooms', v_n);
end $$;

-- ---------------------------------------------------------------- dashboard: today at the resort
create or replace function public.resort_today(p_property uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text := public._tz(p_property);
begin
  perform public._rs_view(p_property);
  return jsonb_build_object('day', p_day,
    'day_visits', (select jsonb_build_object('visits', count(*), 'people', coalesce(sum(adults + children), 0),
        'arrived', coalesce(sum(adults + children) filter (where status in ('arrived','left')), 0),
        'lunches', coalesce(sum(adults + children) filter (where lunch), 0))
      from public.day_visits where property_id = p_property and visit_date = p_day and status not in ('cancelled','no_show')),
    'activities', coalesce((select jsonb_agg(jsonb_build_object('name', activity_name, 'slot', slot, 'people', people, 'bookings', n) order by slot, activity_name)
      from (select activity_name, slot, sum(persons + children) people, count(*) n from public.activity_bookings
             where property_id = p_property and day = p_day and status in ('booked','done') group by activity_name, slot) s), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'kind', g.kind, 'rooms', x.rooms) order by g.name)
      from public.booking_groups g join (select m.group_id, count(*) rooms from public.booking_group_members m join public.bookings b on b.id = m.booking_id
            where b.status in ('pending','confirmed','checked_in') and (b.check_in_at at time zone v_tz)::date = p_day group by m.group_id) x on x.group_id = g.id
      where g.property_id = p_property), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- grants
do $$ declare f text; begin
  foreach f in array array[
    'resort_mode(uuid)','resort_set_mode(uuid, boolean)','resort_settings_get(uuid)','resort_settings_save(uuid, jsonb)',
    'activities_list(uuid)','activity_save(uuid, jsonb)','activity_delete(uuid)','activity_schedule(uuid, date)','activity_guests(uuid, date)',
    'activity_book(uuid, jsonb)','activity_booking_status(uuid, text)',
    'dayout_packages_list(uuid)','dayout_package_save(uuid, jsonb)','dayout_package_delete(uuid)',
    'day_visits_list(uuid, date)','day_visit_save(uuid, jsonb)','day_visit_pay(uuid, jsonb)','day_visit_status(uuid, text)','resort_income(uuid, date, date)',
    'stay_packages_list(uuid)','stay_package_save(uuid, jsonb)','stay_package_delete(uuid)','booking_package_set(uuid, uuid)',
    'booking_extra_beds_set(uuid, int)','booking_resort_get(uuid)',
    'groups_list(uuid)','group_get(uuid)','group_save(uuid, jsonb)','group_remove_booking(uuid)','group_delete(uuid)','group_pay(uuid, jsonb)',
    'resort_today(uuid, date)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
  foreach f in array array['_rs_view(uuid)','_rs_today(uuid)','_rs_is_resort(uuid)','_rs_room_paise(public.bookings)','_dv_row(public.day_visits)',
    '_rs_pay(public.day_visits, jsonb, text)','_sp_price(public.stay_packages, public.bookings)','_grp_row(public.booking_groups)','_rs_rupees(int)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;


-- =====================================================================
-- NammaStay · 036_investment.sql — My investment (owner only)
--
--   • Investments      what the owner put in (interiors, deposit, beds, later upgrades)
--   • Payback          profit since opening (income − expenses) against the money invested,
--                      % paid back, estimated break-even at the last 3 months' pace
--   • Milestones       first booking, first month in profit, first ₹1 lakh month,
--                      10 / 25 / 50 / 75 % paid back, break-even, 100 / 1,000 guests
--   • Licences checklist  what a hostel / homestay / PG / hotel / resort usually needs in the
--                      owner's state (the list itself is in the app: licences-data.js); items tick
--                      when the document is uploaded, or the owner marks them done / not needed
--   • Legal documents  licences, NOCs, agreements with expiry dates; files in a PRIVATE
--                      storage bucket "owner-docs"; reminders in the bell 30, 15 and 3 days
--                      before expiry, and when expired
--
-- OWNER ONLY: every function checks the owner role; managers, front desk and accountants
-- cannot read investments or documents (tables have no grants; files: owner-only policies).
--
-- Income = payments (refunds subtracted), plus PG rent (pg_rent_payments / rent_payments) and resort
-- day-visitor payments (resort_payments) when those tables exist. Expenses = expenses table.
--
-- ADD-ON ONLY — new tables, functions, one storage bucket; nothing existing is changed.
-- Safe to run more than once. Rollback: rollback_036_investment.sql
-- =====================================================================

-- ---------------------------------------------------------------- tables
create table if not exists public.investment_settings (
  property_id  uuid primary key references public.properties(id) on delete cascade,
  opened_on    date not null,
  updated_at   timestamptz not null default now()
);

create table if not exists public.investments (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  title         text not null check (char_length(btrim(title)) between 1 and 80),
  note          text check (char_length(note) <= 200),
  amount_paise  bigint not null check (amount_paise > 0 and amount_paise <= 100000000000),
  invested_on   date not null,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists investments_property on public.investments (property_id, invested_on);

create table if not exists public.legal_documents (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null references public.properties(id) on delete cascade,
  doc_type       text not null check (doc_type in ('trade_licence','fire_noc','fssai','gst','police','tourism','rental_agreement','lease_deed','insurance','building_approval','pollution','partnership','other',
                   'shops_establishment','professional_tax','frro','music','liquor','lift','labour','hostel_licence','environment','classification','rwa_noc')),
  title          text not null check (char_length(btrim(title)) between 1 and 80),
  doc_number     text check (char_length(doc_number) <= 60),
  issued_on      date,
  expires_on     date,
  note           text check (char_length(note) <= 300),
  file_path      text check (char_length(file_path) <= 300),
  file_name      text check (char_length(file_name) <= 160),
  file_size      int check (file_size between 0 and 10485760),
  reminded_level smallint not null default 0,   -- 0 none · 30 · 15 · 3 · -1 expired (bell reminders sent)
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (expires_on is null or issued_on is null or expires_on >= issued_on)
);
create index if not exists legal_documents_property on public.legal_documents (property_id, expires_on);

-- Licences checklist (state + property type picked by the owner; items marked "not needed" or "done without a file")
alter table public.investment_settings add column if not exists state_code text check (state_code ~ '^[0-9]{2}$');
alter table public.investment_settings add column if not exists checklist_kind text check (checklist_kind in ('hostel','homestay','pg','hotel','resort'));
alter table public.legal_documents drop constraint if exists legal_documents_doc_type_check;   -- (re)set the list of document types
alter table public.legal_documents add constraint legal_documents_doc_type_check check (doc_type in ('trade_licence','fire_noc','fssai','gst','police','tourism','rental_agreement','lease_deed','insurance','building_approval','pollution','partnership','other',
                   'shops_establishment','professional_tax','frro','music','liquor','lift','labour','hostel_licence','environment','classification','rwa_noc'));
create table if not exists public.legal_checklist (
  property_id  uuid not null references public.properties(id) on delete cascade,
  item_key     text not null check (item_key ~ '^[a-z0-9_]{1,40}$'),
  status       text not null check (status in ('not_needed','done')),
  updated_at   timestamptz not null default now(),
  primary key (property_id, item_key)
);

do $$
declare t text;
begin
  foreach t in array array['investment_settings','investments','legal_documents','legal_checklist'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);   -- owner reads/writes only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- private file storage (owner only)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('owner-docs', 'owner-docs', false, 10485760, array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Path layout: {property_id}/{random}.{ext}
drop policy if exists "owner-docs: owner read" on storage.objects;
create policy "owner-docs: owner read" on storage.objects for select to authenticated
  using (bucket_id = 'owner-docs' and exists (
    select 1 from public.my_property_ids(array['owner']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "owner-docs: owner upload" on storage.objects;
create policy "owner-docs: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'owner-docs' and exists (
    select 1 from public.my_property_ids(array['owner']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "owner-docs: owner delete" on storage.objects;
create policy "owner-docs: owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'owner-docs' and exists (
    select 1 from public.my_property_ids(array['owner']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));

-- ---------------------------------------------------------------- helpers
create or replace function public._inv_owner(p_property uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_property is null then raise exception 'Property missing.'; end if;
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
end $$;

create or replace function public._inv_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata'))::date
$$;

create or replace function public._inv_opened_on(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select opened_on from public.investment_settings where property_id = p_property),
    (select min(check_in_at)::date from public.bookings where property_id = p_property),
    (select created_at::date from public.properties where id = p_property))
$$;

-- Income and expenses per month from p_from's month to this month.
create or replace function public._inv_months(p_property uuid, p_from date)
returns table (month date, revenue_paise bigint, expenses_paise bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; v_to date; v_extra text := '';
begin
  select coalesce(timezone, 'Asia/Kolkata') into v_tz from public.properties where id = p_property;
  v_to := public._inv_today(p_property);
  if to_regclass('public.pg_rent_payments') is not null then
    v_extra := v_extra || ' union all select (received_at at time zone $2)::date, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint
                 from public.pg_rent_payments where property_id = $1';
  end if;
  if to_regclass('public.rent_payments') is not null then      -- PG rent (NammaStay 031 naming)
    v_extra := v_extra || ' union all select (received_at at time zone $2)::date, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint
                 from public.rent_payments where property_id = $1';
  end if;
  if to_regclass('public.resort_payments') is not null then
    v_extra := v_extra || ' union all select (received_at at time zone $2)::date, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint
                 from public.resort_payments where property_id = $1';
  end if;
  return query execute
    'with inc as (
       select (received_at at time zone $2)::date d, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint a
         from public.payments where property_id = $1' || v_extra || '),
     m as (select generate_series(date_trunc(''month'', $3)::date, date_trunc(''month'', $4)::date, interval ''1 month'')::date as month)
     select m.month,
            coalesce((select sum(a) from inc where d >= $3 and date_trunc(''month'', d)::date = m.month), 0)::bigint,
            coalesce((select sum(amount_paise) from public.expenses e where e.property_id = $1 and e.spent_on >= $3
                        and date_trunc(''month'', e.spent_on)::date = m.month), 0)::bigint
       from m order by m.month'
    using p_property, v_tz, p_from, v_to;
end $$;

-- Bell reminders 30 / 15 / 3 days before expiry, and once when expired (to every owner of the property).
create or replace function public._legal_docs_notify(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_today date := public._inv_today(p_property); v_left int; v_level smallint; n int := 0;
begin
  for r in select * from public.legal_documents where property_id = p_property and expires_on is not null loop
    v_left := r.expires_on - v_today;
    v_level := case when v_left < 0 then -1 when v_left <= 3 then 3 when v_left <= 15 then 15 when v_left <= 30 then 30 else 0 end;
    if v_level <> 0 and v_level is distinct from r.reminded_level
       and (r.reminded_level = 0 or v_level = -1 or v_level < r.reminded_level) then
      insert into public.notifications (property_id, user_id, kind, title, body)
      select p_property, m.user_id, 'legal_doc',
             case when v_left < 0 then r.title || ' has expired'
                  when v_left = 0 then r.title || ' expires today'
                  else r.title || ' expires in ' || v_left || ' day' || case when v_left = 1 then '' else 's' end end,
             'Expiry date ' || to_char(r.expires_on, 'DD Mon YYYY') || '. Renew it and update the date in My investment → Legal documents.'
        from public.property_members m where m.property_id = p_property and m.role = 'owner';
      update public.legal_documents set reminded_level = v_level where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- payback summary
create or replace function public.invest_summary(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_open date; v_today date; v_total bigint; v_rec bigint := 0; v_cum bigint := 0;
  v_months jsonb := '[]'::jsonb; v_ms jsonb := '[]'::jsonb; r record;
  v_first_profit date; v_lakh date; v_hit date[] := array[null,null,null,null,null]::date[];
  v_pcts int[] := array[10,25,50,75,100]; i int; v_avg bigint; v_left bigint; v_mleft int; v_est date;
  v_best record; v_first_booking date; v_g100 date; v_g1000 date; v_next text := null;
begin
  perform public._inv_owner(p_property);
  perform public._legal_docs_notify(p_property);
  v_open := public._inv_opened_on(p_property);
  v_today := public._inv_today(p_property);
  select coalesce(sum(amount_paise), 0) into v_total from public.investments where property_id = p_property;

  for r in select * from public._inv_months(p_property, v_open) loop
    v_cum := v_cum + (r.revenue_paise - r.expenses_paise);
    v_months := v_months || jsonb_build_object('month', to_char(r.month, 'YYYY-MM'), 'revenue_paise', r.revenue_paise,
                  'expenses_paise', r.expenses_paise, 'profit_paise', r.revenue_paise - r.expenses_paise, 'cumulative_paise', v_cum);
    if v_first_profit is null and r.revenue_paise - r.expenses_paise > 0 then v_first_profit := r.month; end if;
    if v_lakh is null and r.revenue_paise >= 10000000 then v_lakh := r.month; end if;
    if v_total > 0 then
      for i in 1..5 loop
        if v_hit[i] is null and v_cum * 100 >= v_total * v_pcts[i] then v_hit[i] := r.month; end if;
      end loop;
    end if;
  end loop;
  v_rec := v_cum;

  -- average profit of the last 3 complete months (this month is still running)
  select round(avg(profit))::bigint into v_avg from (
    select (x->>'profit_paise')::bigint profit from jsonb_array_elements(v_months) x
     where (x->>'month') < to_char(v_today, 'YYYY-MM') order by x->>'month' desc limit 3) t;
  v_left := greatest(v_total - v_rec, 0);
  if v_total > 0 and v_left > 0 and coalesce(v_avg, 0) > 0 then
    v_mleft := ceil(v_left::numeric / v_avg)::int;
    v_est := (date_trunc('month', v_today) + make_interval(months => v_mleft))::date;
  end if;

  select x->>'month' as month, (x->>'profit_paise')::bigint as profit into v_best
    from jsonb_array_elements(v_months) x order by (x->>'profit_paise')::bigint desc limit 1;

  select min(check_in_at)::date into v_first_booking from public.bookings
   where property_id = p_property and status not in ('cancelled');
  select created_at::date into v_g100 from public.guests where property_id = p_property order by created_at offset 99 limit 1;
  select created_at::date into v_g1000 from public.guests where property_id = p_property order by created_at offset 999 limit 1;

  v_ms := jsonb_build_array(
    jsonb_build_object('key','first_booking','title','First booking','achieved_on',v_first_booking),
    jsonb_build_object('key','first_profit','title','First month in profit','achieved_on',v_first_profit),
    jsonb_build_object('key','lakh_month','title','First ₹1 lakh month','achieved_on',v_lakh),
    jsonb_build_object('key','p10','title','10% paid back','achieved_on',v_hit[1],'pct',10),
    jsonb_build_object('key','p25','title','25% paid back','achieved_on',v_hit[2],'pct',25),
    jsonb_build_object('key','guests_100','title','100 guests','achieved_on',v_g100),
    jsonb_build_object('key','p50','title','Half way: 50% paid back','achieved_on',v_hit[3],'pct',50),
    jsonb_build_object('key','guests_1000','title','1,000 guests','achieved_on',v_g1000),
    jsonb_build_object('key','p75','title','75% paid back','achieved_on',v_hit[4],'pct',75),
    jsonb_build_object('key','p100','title','Break-even!','achieved_on',v_hit[5],'pct',100));
  if v_total > 0 then
    for i in 1..5 loop
      if v_hit[i] is null then v_next := 'p' || v_pcts[i]; exit; end if;
    end loop;
  end if;

  return jsonb_build_object(
    'opened_on', v_open, 'opened_set', exists (select 1 from public.investment_settings where property_id = p_property),
    'today', v_today,
    'invested_paise', v_total,
    'recovered_paise', v_rec,
    'remaining_paise', v_left,
    'pct', case when v_total > 0 then round(greatest(v_rec, 0) * 100.0 / v_total, 1) else null end,
    'avg3_paise', v_avg,
    'months_left', v_mleft,
    'breakeven_month', case when v_total > 0 and v_left = 0 then to_char(v_hit[5], 'YYYY-MM') else to_char(v_est, 'YYYY-MM') end,
    'best_month', case when v_best.month is not null and v_best.profit > 0 then jsonb_build_object('month', v_best.month, 'profit_paise', v_best.profit) end,
    'months', v_months,
    'milestones', v_ms,
    'next', v_next,
    'next_needed_paise', case when v_next is not null then greatest(ceil(v_total * substr(v_next, 2)::int / 100.0)::bigint - v_rec, 0) end,
    'expenses_this_month', exists (select 1 from public.expenses where property_id = p_property and spent_on >= date_trunc('month', v_today)::date),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'note', note, 'amount_paise', amount_paise,
                'invested_on', invested_on) order by invested_on, created_at), '[]'::jsonb) from public.investments where property_id = p_property));
end $$;

create or replace function public.invest_settings_save(p_property uuid, p_opened_on date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._inv_owner(p_property);
  if p_opened_on is null or p_opened_on > public._inv_today(p_property) then raise exception 'Choose the date your property opened (not in the future).'; end if;
  if p_opened_on < date '1990-01-01' then raise exception 'That opening date looks wrong.'; end if;
  insert into public.investment_settings (property_id, opened_on) values (p_property, p_opened_on)
  on conflict (property_id) do update set opened_on = excluded.opened_on, updated_at = now();
  return jsonb_build_object('opened_on', p_opened_on);
end $$;

create or replace function public.investment_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := (p->>'amount_paise')::bigint; v_on date := nullif(p->>'invested_on', '')::date;
  v_title text := btrim(coalesce(p->>'title', '')); r public.investments;
begin
  perform public._inv_owner(p_property);
  if v_title = '' then raise exception 'Give the investment a name (e.g. Interiors, Beds).'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter the amount invested.'; end if;
  if v_on is null then v_on := public._inv_today(p_property); end if;
  if v_on > public._inv_today(p_property) then raise exception 'The date can''t be in the future.'; end if;
  if v_id is null then
    insert into public.investments (property_id, title, note, amount_paise, invested_on)
    values (p_property, v_title, nullif(btrim(p->>'note'), ''), v_amt, v_on) returning * into r;
  else
    update public.investments set title = v_title, note = nullif(btrim(p->>'note'), ''), amount_paise = v_amt, invested_on = v_on
     where id = v_id and property_id = p_property returning * into r;
    if r.id is null then raise exception 'Investment not found.'; end if;
  end if;
  return to_jsonb(r);
end $$;

create or replace function public.investment_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.investments where id = p_id;
  if v_prop is null then raise exception 'Investment not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.investments where id = p_id;
end $$;

-- ---------------------------------------------------------------- legal documents
create or replace function public.legal_docs_list(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date;
begin
  perform public._inv_owner(p_property);
  perform public._legal_docs_notify(p_property);
  v_today := public._inv_today(p_property);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'title', d.title, 'doc_number', d.doc_number,
            'issued_on', d.issued_on, 'expires_on', d.expires_on, 'note', d.note, 'file_path', d.file_path, 'file_name', d.file_name,
            'file_size', d.file_size, 'days_left', d.expires_on - v_today,
            'status', case when d.expires_on is null then 'no_expiry' when d.expires_on < v_today then 'expired'
                           when d.expires_on - v_today <= 30 then 'due' else 'valid' end)
          order by (d.expires_on is null), d.expires_on, d.title), '[]'::jsonb)
          from public.legal_documents d where d.property_id = p_property);
end $$;

create or replace function public.legal_doc_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_path text := nullif(p->>'file_path', ''); v_exp date := nullif(p->>'expires_on', '')::date;
  v_iss date := nullif(p->>'issued_on', '')::date; v_title text := btrim(coalesce(p->>'title', '')); r public.legal_documents; old public.legal_documents;
begin
  perform public._inv_owner(p_property);
  if v_title = '' then raise exception 'Give the document a name.'; end if;
  if v_exp is not null and v_iss is not null and v_exp < v_iss then raise exception 'The expiry date is before the issue date.'; end if;
  if v_path is not null and (v_path not like p_property::text || '/%' or v_path like '%..%') then raise exception 'File not allowed.'; end if;
  if v_id is null then
    insert into public.legal_documents (property_id, doc_type, title, doc_number, issued_on, expires_on, note, file_path, file_name, file_size)
    values (p_property, coalesce(nullif(p->>'doc_type', ''), 'other'), v_title, nullif(btrim(p->>'doc_number'), ''), v_iss, v_exp,
            nullif(btrim(p->>'note'), ''), v_path, nullif(p->>'file_name', ''), nullif(p->>'file_size', '')::int)
    returning * into r;
  else
    select * into old from public.legal_documents where id = v_id and property_id = p_property;
    if old.id is null then raise exception 'Document not found.'; end if;
    update public.legal_documents set doc_type = coalesce(nullif(p->>'doc_type', ''), doc_type), title = v_title,
           doc_number = nullif(btrim(p->>'doc_number'), ''), issued_on = v_iss, expires_on = v_exp, note = nullif(btrim(p->>'note'), ''),
           file_path = case when p ? 'file_path' then v_path else file_path end,
           file_name = case when p ? 'file_path' then nullif(p->>'file_name', '') else file_name end,
           file_size = case when p ? 'file_path' then nullif(p->>'file_size', '')::int else file_size end,
           reminded_level = case when expires_on is distinct from v_exp then 0 else reminded_level end,   -- renewed: reminders start again
           updated_at = now()
     where id = v_id returning * into r;
  end if;
  return jsonb_build_object('id', r.id, 'old_file_path', case when old.id is not null and old.file_path is distinct from r.file_path then old.file_path end);
end $$;

create or replace function public.legal_doc_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.legal_documents;
begin
  select * into d from public.legal_documents where id = p_id;
  if d.id is null then raise exception 'Document not found.'; end if;
  perform public._inv_owner(d.property_id);
  delete from public.legal_documents where id = p_id;
  return jsonb_build_object('file_path', d.file_path);   -- the app removes the file from storage
end $$;

-- Dashboard: documents expired or expiring within 30 days (owner only; others get nothing).
create or replace function public.legal_docs_alerts(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date;
begin
  if not exists (select 1 from public.property_members where property_id = p_property and user_id = auth.uid() and role = 'owner') then
    return jsonb_build_object('count', 0, 'items', '[]'::jsonb);
  end if;
  perform public._legal_docs_notify(p_property);
  v_today := public._inv_today(p_property);
  return (select jsonb_build_object('count', count(*), 'items', coalesce(jsonb_agg(jsonb_build_object('title', title, 'expires_on', expires_on,
            'days_left', expires_on - v_today) order by expires_on) filter (where rn <= 3), '[]'::jsonb))
          from (select title, expires_on, row_number() over (order by expires_on) rn from public.legal_documents
                 where property_id = p_property and expires_on is not null and expires_on - v_today <= 30) t);
end $$;

-- Licences checklist: the owner's state + property type, and items marked by hand.
create or replace function public.legal_checklist_get(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._inv_owner(p_property);
  return jsonb_build_object(
    'state_code', coalesce((select state_code from public.investment_settings where property_id = p_property),
                           (select nullif(bill_state, '') from public.properties where id = p_property)),
    'kind', (select checklist_kind from public.investment_settings where property_id = p_property),
    'marks', (select coalesce(jsonb_object_agg(item_key, status), '{}'::jsonb) from public.legal_checklist where property_id = p_property),
    'doc_types', (select coalesce(jsonb_agg(distinct doc_type), '[]'::jsonb) from public.legal_documents where property_id = p_property));
end $$;

create or replace function public.legal_checklist_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text := nullif(p->>'item_key', ''); v_status text := nullif(p->>'status', '');
begin
  perform public._inv_owner(p_property);
  if p ? 'state_code' or p ? 'kind' then
    if p ? 'state_code' and nullif(p->>'state_code', '') !~ '^[0-9]{2}$' then raise exception 'Choose your state.'; end if;
    if p ? 'kind' and coalesce(p->>'kind', '') not in ('hostel','homestay','pg','hotel','resort') then raise exception 'Choose the property type.'; end if;
    insert into public.investment_settings (property_id, opened_on, state_code, checklist_kind)
    values (p_property, public._inv_opened_on(p_property), nullif(p->>'state_code', ''), nullif(p->>'kind', ''))
    on conflict (property_id) do update set
      state_code = case when p ? 'state_code' then excluded.state_code else investment_settings.state_code end,
      checklist_kind = case when p ? 'kind' then excluded.checklist_kind else investment_settings.checklist_kind end,
      updated_at = now();
  end if;
  if v_key is not null then
    if v_key !~ '^[a-z0-9_]{1,40}$' then raise exception 'Unknown checklist item.'; end if;
    if v_status is null then
      delete from public.legal_checklist where property_id = p_property and item_key = v_key;
    elsif v_status in ('not_needed','done') then
      insert into public.legal_checklist (property_id, item_key, status) values (p_property, v_key, v_status)
      on conflict (property_id, item_key) do update set status = excluded.status, updated_at = now();
    else raise exception 'Unknown status.'; end if;
  end if;
  return public.legal_checklist_get(p_property);
end $$;

-- Optional daily job (pg_cron): reminders even when nobody opens the app. See README.
create or replace function public.legal_docs_remind_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  for r in select distinct property_id from public.legal_documents where expires_on is not null loop
    n := n + public._legal_docs_notify(r.property_id);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- grants
do $$
declare f text;
begin
  foreach f in array array['invest_summary(uuid)','invest_settings_save(uuid,date)','investment_save(uuid,jsonb)','investment_delete(uuid)',
    'legal_docs_list(uuid)','legal_doc_save(uuid,jsonb)','legal_doc_delete(uuid)','legal_docs_alerts(uuid)',
    'legal_checklist_get(uuid)','legal_checklist_save(uuid,jsonb)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
  foreach f in array array['_inv_owner(uuid)','_inv_today(uuid)','_inv_opened_on(uuid)','_inv_months(uuid,date)','_legal_docs_notify(uuid)',
    'legal_docs_remind_all()'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

-- Check: should say true
select to_regclass('public.investments') is not null and to_regclass('public.legal_documents') is not null
   and exists (select 1 from storage.buckets where id = 'owner-docs' and not public) as investment_installed;


-- =====================================================================
-- NammaStay · 037_business_health.sql — Business health (report card)
--
-- One score out of 100 from the property's own data, 8 areas with green / amber / red,
-- and the top things to do:
--   occupancy · pricing · profit · cash (unpaid dues) · booking mix (direct vs OTA)
--   guests (cancellations, no-shows, repeat guests) · compliance (documents, 036) · payback (036)
-- Mostly compares the property with ITSELF (last 30 days vs the 30 before, and vs last year).
-- Areas without enough data say "unknown" and are left out of the score.
--
-- Owner: every area. Manager: an operations view (occupancy, cash, booking mix, guests) — no
-- profit, payback or documents. Others: refused.
-- A snapshot is kept per week (trend), and once a week the owners get a summary in the bell.
--
-- ADD-ON ONLY — new table + functions; reads existing tables; nothing existing is changed.
-- Works with or without 036_investment.sql (then compliance and payback are skipped).
-- Safe to run more than once. Rollback: rollback_037_business_health.sql
-- =====================================================================

create table if not exists public.business_health_snapshots (
  property_id uuid not null references public.properties(id) on delete cascade,
  week_start  date not null,
  score       int check (score between 0 and 100),
  areas       jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (property_id, week_start)
);
alter table public.business_health_snapshots enable row level security;
revoke all on public.business_health_snapshots from anon, authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function public._bh_tz(p_property uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata')
$$;

-- Occupied bed/room-nights in [p_from, p_to] (bookings + OTA calendar blocks + PG tenancies), units, full nights.
create or replace function public._bh_occ(p_property uuid, p_from date, p_to date,
  out units int, out available bigint, out occupied bigint, out full_nights int, out ota_nights bigint, out direct_nights bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text := public._bh_tz(p_property); v_pg text := '';
begin
  select count(*) into units from public.beds where property_id = p_property and is_active;
  available := units::bigint * (p_to - p_from + 1);
  if to_regclass('public.pg_tenancies') is not null then
    v_pg := ' union select d, t.bed_id, ''pg'' from nights n join public.pg_tenancies t on t.property_id = $1
               and t.start_date <= n.d and (t.move_out_on is null or n.d < t.move_out_on) and t.status <> ''moved_out''';
  elsif to_regclass('public.tenancies') is not null then
    v_pg := ' union select d, t.bed_id, ''pg'' from nights n join public.tenancies t on t.property_id = $1
               and t.start_date <= n.d and (t.move_out_on is null or n.d < t.move_out_on) and t.booking_id is null';
  end if;
  execute
   'with nights as (select generate_series($2::date, $3::date, interval ''1 day'')::date d),
         occ as (
           select n.d, b.bed_id, case when b.source = ''ota'' then ''ota'' else ''direct'' end src
             from nights n join public.bookings b on b.property_id = $1
              and b.status in (''confirmed'', ''checked_in'', ''checked_out'')
              and (b.check_in_at at time zone $4)::date <= n.d and n.d < (b.check_out_at at time zone $4)::date
           union
           select n.d, k.bed_id, ''ota'' from nights n join public.bed_blocks k on k.property_id = $1 and k.feed_id is not null
              and (k.starts_at at time zone $4)::date <= n.d and n.d < (k.ends_at at time zone $4)::date' || v_pg || '),
         per_night as (select d, count(distinct bed_id) c from occ group by d)
    select (select count(*) from (select distinct d, bed_id from occ) x),
           (select count(*) from per_night where c >= greatest(1, ceil($5 * 0.95))),
           (select count(*) from (select distinct d, bed_id from occ where src = ''ota'') x),
           (select count(*) from (select distinct d, bed_id from occ where src <> ''ota'') x)'
    into occupied, full_nights, ota_nights, direct_nights
    using p_property, p_from, p_to, v_tz, units;
  if units = 0 then full_nights := 0; end if;
end $$;

-- Money received in [p_from, p_to] (payments − refunds, + PG rent, + resort day visitors).
create or replace function public._bh_income(p_property uuid, p_from date, p_to date) returns bigint
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text := public._bh_tz(p_property); v_sql text; v bigint; t text;
begin
  v_sql := 'select coalesce(sum(case when kind::text = ''refund'' then -amount_paise else amount_paise end), 0)::bigint from (
              select kind::text kind, amount_paise, received_at from public.payments where property_id = $1';
  foreach t in array array['pg_rent_payments', 'rent_payments', 'resort_payments'] loop
    if to_regclass('public.' || t) is not null then
      v_sql := v_sql || ' union all select kind::text, amount_paise, received_at from public.' || t || ' where property_id = $1';
    end if;
  end loop;
  v_sql := v_sql || ') x where (received_at at time zone $4)::date between $2 and $3';
  execute v_sql into v using p_property, p_from, p_to, v_tz;
  return v;
end $$;

create or replace function public._bh_area(p_key text, p_title text, p_status text, p_value text, p_detail text, p_how text, p_tip text, p_weight int)
returns jsonb language sql immutable as $$
  select jsonb_build_object('key', p_key, 'title', p_title, 'status', p_status, 'value', p_value, 'detail', p_detail,
           'how', p_how, 'tip', case when p_status in ('amber', 'red', 'unknown') then p_tip end, 'weight', p_weight)
$$;

-- ---------------------------------------------------------------- the report card
create or replace function public.business_health(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role; v_owner boolean; v_today date; v_from date; v_pfrom date; v_pto date;
  o record; op record; oy record; v_occ numeric; v_pocc numeric; v_yocc numeric;
  v_inc bigint; v_pinc bigint; v_exp bigint; v_exp_rows int; v_rev_n numeric; v_prev_n numeric;
  v_due bigint := 0; v_due_old bigint := 0; v_due_guests int := 0; v_pg_due bigint := 0;
  m record; v_ota_share numeric; v_comm bigint; v_inc90 bigint;
  v_cnt int; v_bad int; v_repeat numeric; v_guests int;
  v_docs int; v_exp_docs int; v_due_docs int; v_inv jsonb;
  areas jsonb := '[]'::jsonb; a jsonb; v_score numeric; v_wsum numeric := 0; v_sum numeric := 0; st text; tip text;
  v_actions jsonb; v_week date; v_trend jsonb; v_snap_score int;
begin
  if auth.uid() is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  select role into v_role from public.property_members where property_id = p_property and user_id = auth.uid();
  if v_role is null or v_role not in ('owner', 'manager') then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  v_owner := v_role = 'owner';
  v_today := (now() at time zone public._bh_tz(p_property))::date;
  v_from := v_today - 29; v_pfrom := v_today - 59; v_pto := v_today - 30;

  -- 1 occupancy
  o := public._bh_occ(p_property, v_from, v_today);
  op := public._bh_occ(p_property, v_pfrom, v_pto);
  oy := public._bh_occ(p_property, (v_from - interval '1 year')::date, (v_today - interval '1 year')::date);
  if o.available > 0 then
    v_occ := round(o.occupied * 100.0 / o.available, 1);
    v_pocc := case when op.available > 0 then round(op.occupied * 100.0 / op.available, 1) end;
    v_yocc := case when oy.available > 0 and oy.occupied > 0 then round(oy.occupied * 100.0 / oy.available, 1) end;
    st := case when v_occ >= 65 or (v_pocc is not null and v_occ >= v_pocc + 5) then 'green'
               when v_occ < 40 and (v_pocc is null or v_occ <= v_pocc) then 'red' else 'amber' end;
    areas := areas || public._bh_area('occupancy', 'Occupancy', st, v_occ || '%',
      'Last 30 days' || coalesce(' · previous 30 days ' || v_pocc || '%', '') || coalesce(' · same time last year ' || v_yocc || '%', ''),
      'Nights sold ÷ nights available (' || o.units || ' units × 30 nights), incl. OTA calendar blocks.',
      case when v_pocc is not null and v_occ < v_pocc then 'Occupancy is falling: run a weekday offer, refresh OTA photos and ask past guests to come back.'
           else 'Fill empty nights: open more OTAs, add weekday / long-stay discounts and share your booking link on WhatsApp.' end, 20);
  else
    areas := areas || public._bh_area('occupancy', 'Occupancy', 'unknown', '—', 'No rooms or beds set up', 'Needs rooms / beds.', 'Add your rooms or beds in Setup.', 20);
  end if;

  -- 2 pricing (owners and managers who see reports)
  v_inc := public._bh_income(p_property, v_from, v_today);
  v_pinc := public._bh_income(p_property, v_pfrom, v_pto);
  if v_owner then
    if o.available > 0 and (v_inc > 0 or v_pinc > 0) then
      v_rev_n := v_inc::numeric / o.available; v_prev_n := case when op.available > 0 then v_pinc::numeric / op.available end;
      st := case when v_prev_n is null or v_prev_n = 0 then (case when v_inc > 0 then 'amber' else 'unknown' end)
                 when v_rev_n >= v_prev_n * 1.03 then 'green' when v_rev_n >= v_prev_n * 0.95 then 'amber' else 'red' end;
      if o.full_nights >= 4 and st = 'green' then st := 'amber'; end if;
      areas := areas || public._bh_area('pricing', 'Pricing', st, '₹' || round(v_rev_n / 100) || ' / night',
        'Money received per available unit-night' || coalesce(', was ₹' || round(v_prev_n / 100), '') || ' · ' || o.full_nights || ' full nights in 30 days',
        'Money received in the last 30 days ÷ nights available.',
        case when o.full_nights >= 4 then 'You were full on ' || o.full_nights || ' nights — raise prices on those days (weekends, holidays).'
             else 'Earnings per night are slipping: check you aren’t discounting too much and add extras (breakfast, tours).' end, 10);
    else
      areas := areas || public._bh_area('pricing', 'Pricing', 'unknown', '—', 'No payments recorded yet', 'Needs payments.', 'Record payments in NammaStay so earnings per night can be tracked.', 10);
    end if;

    -- 3 profit
    select coalesce(sum(amount_paise), 0), count(*) into v_exp, v_exp_rows from public.expenses where property_id = p_property and spent_on between v_from and v_today;
    if v_exp_rows = 0 or v_inc <= 0 then
      areas := areas || public._bh_area('profit', 'Profit', 'unknown', '—', case when v_exp_rows = 0 then 'No expenses recorded in the last 30 days' else 'No income in the last 30 days' end,
        'Money received − expenses, last 30 days.', 'Add rent, salaries and bills in Expenses & profit — without them profit can’t be measured.', 20);
    else
      st := case when (v_inc - v_exp) * 100 >= v_inc * 25 then 'green' when (v_inc - v_exp) * 100 >= v_inc * 10 then 'amber' else 'red' end;
      areas := areas || public._bh_area('profit', 'Profit', st, round((v_inc - v_exp) * 100.0 / v_inc) || '% margin',
        '₹' || to_char(round((v_inc - v_exp) / 100.0), 'FM99,99,99,999') || ' profit on ₹' || to_char(round(v_inc / 100.0), 'FM99,99,99,999') || ' received (30 days)',
        '(Money received − expenses) ÷ money received, last 30 days.',
        'Margin is thin: look at your biggest expense categories and OTA commission; small price rises help most.', 20);
    end if;
  end if;

  -- 4 cash: unpaid dues
  select coalesce(sum(balance_paise), 0), coalesce(sum(balance_paise) filter (where status = 'checked_out' and check_out_at < now() - interval '7 days'), 0),
         count(distinct guest_id) filter (where balance_paise > 0)
    into v_due, v_due_old, v_due_guests
    from public.bookings where property_id = p_property and status in ('checked_in', 'checked_out') and balance_paise > 0;
  if to_regclass('public.pg_rent_dues') is not null then
    execute 'select coalesce(sum(amount_paise - paid_paise), 0) from public.pg_rent_dues where property_id = $1 and amount_paise > paid_paise and due_on < $2'
      into v_pg_due using p_property, v_today - 7;
  elsif to_regclass('public.rent_dues') is not null then
    execute 'select coalesce(sum(amount_paise - paid_paise - coalesce(credit_paise, 0)), 0) from public.rent_dues where property_id = $1 and amount_paise > paid_paise + coalesce(credit_paise, 0) and due_on < $2'
      into v_pg_due using p_property, v_today - 7;
  end if;
  v_due_old := v_due_old + greatest(v_pg_due, 0); v_due := v_due + greatest(v_pg_due, 0);
  st := case when v_due_old = 0 then 'green' when v_due_old * 20 <= greatest(v_inc, 1) then 'amber' else 'red' end;
  areas := areas || public._bh_area('cash', 'Unpaid dues', st, '₹' || to_char(round(v_due / 100.0), 'FM99,99,99,999'),
    case when v_due_old > 0 then '₹' || to_char(round(v_due_old / 100.0), 'FM99,99,99,999') || ' overdue more than 7 days' else 'Nothing overdue' end
      || case when v_due_guests > 0 then ' · ' || v_due_guests || ' guest' || case when v_due_guests > 1 then 's' else '' end || ' owe money' else '' end,
    'Balances of checked-in / checked-out bookings (and PG rent overdue 7+ days).',
    'Send WhatsApp payment reminders today and take advance payments at booking.', 15);

  -- 5 booking mix (last 90 days, nights)
  m := public._bh_occ(p_property, v_today - 89, v_today);
  if m.ota_nights + m.direct_nights > 0 then
    v_ota_share := round(m.ota_nights * 100.0 / (m.ota_nights + m.direct_nights));
    v_inc90 := public._bh_income(p_property, v_today - 89, v_today);
    select coalesce(sum(amount_paise), 0) into v_comm from public.expenses where property_id = p_property and category = 'ota_commission' and spent_on between v_today - 89 and v_today;
    st := case when v_ota_share <= 40 then 'green' when v_ota_share <= 65 then 'amber' else 'red' end;
    areas := areas || public._bh_area('mix', 'Direct vs OTA', st, v_ota_share || '% OTA',
      (100 - v_ota_share) || '% direct / walk-in nights (90 days)' || case when v_owner and v_comm > 0 and v_inc90 > 0 then ' · OTA commission ' || round(v_comm * 100.0 / v_inc90) || '% of income' else '' end,
      'OTA nights (OTA bookings + OTA calendar blocks) ÷ all sold nights, last 90 days.',
      'Most guests come through OTAs: give returning guests a direct-booking discount, add your WhatsApp / booking link to your Google profile.', 10);
  else
    areas := areas || public._bh_area('mix', 'Direct vs OTA', 'unknown', '—', 'No stays in the last 90 days', 'Needs bookings.', 'Add bookings or connect your OTA calendars.', 10);
  end if;

  -- 6 guests: cancellations / no-shows, repeat guests (bookings created in 90 days)
  select count(*), count(*) filter (where status in ('cancelled', 'no_show')) into v_cnt, v_bad
    from public.bookings where property_id = p_property and created_at >= now() - interval '90 days' and status <> 'pending';
  if v_cnt >= 5 then
    select count(distinct b.guest_id), count(distinct b.guest_id) filter (where exists (select 1 from public.bookings e where e.property_id = b.property_id
             and e.guest_id = b.guest_id and e.id <> b.id and e.status in ('checked_out', 'checked_in', 'confirmed')))
      into v_guests, v_cnt from public.bookings b where b.property_id = p_property and b.created_at >= now() - interval '90 days' and b.status in ('confirmed', 'checked_in', 'checked_out');
    v_repeat := case when v_guests > 0 then round(v_cnt * 100.0 / v_guests) end;
    select count(*) into v_cnt from public.bookings where property_id = p_property and created_at >= now() - interval '90 days' and status <> 'pending';
    st := case when v_bad * 100 <= v_cnt * 10 then 'green' when v_bad * 100 <= v_cnt * 20 then 'amber' else 'red' end;
    areas := areas || public._bh_area('guests', 'Cancellations & repeat guests', st, round(v_bad * 100.0 / v_cnt) || '% cancelled / no-show',
      v_bad || ' of ' || v_cnt || ' bookings (90 days)' || coalesce(' · ' || v_repeat || '% repeat guests', ''),
      'Cancelled + no-show ÷ bookings made in the last 90 days; repeat = guests who stayed before.',
      'Many cancellations: take a small advance, confirm 24 hours before arrival on WhatsApp.', 10);
  else
    areas := areas || public._bh_area('guests', 'Cancellations & repeat guests', 'unknown', '—', 'Fewer than 5 bookings in 90 days', 'Needs more bookings.', null, 10);
  end if;

  if v_owner then
    -- 7 compliance (036)
    if to_regclass('public.legal_documents') is not null then
      execute 'select count(*), count(*) filter (where expires_on < $2), count(*) filter (where expires_on between $2 and $2 + 30) from public.legal_documents where property_id = $1'
        into v_docs, v_exp_docs, v_due_docs using p_property, v_today;
      if v_docs = 0 then
        areas := areas || public._bh_area('compliance', 'Licences & documents', 'unknown', '—', 'No documents added', 'Documents in My investment → Legal documents.',
          'Add your licences with expiry dates (My investment → Legal documents) and go through the Licences checklist.', 10);
      else
        st := case when v_exp_docs > 0 then 'red' when v_due_docs > 0 then 'amber' else 'green' end;
        areas := areas || public._bh_area('compliance', 'Licences & documents', st,
          case when v_exp_docs > 0 then v_exp_docs || ' expired' when v_due_docs > 0 then v_due_docs || ' due soon' else 'All valid' end,
          v_docs || ' documents stored' || case when v_due_docs > 0 then ' · ' || v_due_docs || ' expire within 30 days' else '' end,
          'Expiry dates of documents in My investment → Legal documents.',
          'Renew expiring licences now — operating with an expired licence or fire NOC can bring fines or closure.', 10);
      end if;
    end if;
    -- 8 payback (036)
    if to_regprocedure('public.invest_summary(uuid)') is not null then
      execute 'select public.invest_summary($1)' into v_inv using p_property;
      if coalesce((v_inv->>'invested_paise')::bigint, 0) > 0 then
        st := case when (v_inv->>'remaining_paise')::bigint = 0 then 'green'
                   when v_inv->>'breakeven_month' is null then 'red'
                   when (v_inv->>'months_left')::int <= 36 then 'green' else 'amber' end;
        areas := areas || public._bh_area('payback', 'Payback', st, coalesce(floor((v_inv->>'pct')::numeric) || '% paid back', '—'),
          case when (v_inv->>'remaining_paise')::bigint = 0 then 'Investment fully recovered'
               when v_inv->>'breakeven_month' is not null then 'Break-even estimated ' || to_char(to_date(v_inv->>'breakeven_month', 'YYYY-MM'), 'Mon YYYY')
               else 'No break-even estimate yet (needs monthly profit)' end,
          'Profit since opening ÷ money invested (My investment).',
          'Payback is slow: improving occupancy, prices and dues above brings your break-even date closer.', 5);
      end if;
    end if;
  end if;

  -- score + top actions
  for a in select * from jsonb_array_elements(areas) loop
    if a->>'status' <> 'unknown' then
      v_wsum := v_wsum + (a->>'weight')::int;
      v_sum := v_sum + (a->>'weight')::int * case a->>'status' when 'green' then 100 when 'amber' then 60 else 25 end;
    end if;
  end loop;
  v_score := case when v_wsum > 0 then round(v_sum / v_wsum) end;
  if m.ota_nights + m.direct_nights = 0 and coalesce(v_inc, 0) = 0 then v_score := null; end if;   -- brand new: nothing to judge yet
  select coalesce(jsonb_agg(jsonb_build_object('area', x->>'key', 'status', x->>'status', 'text', x->>'tip')
           order by case x->>'status' when 'red' then 0 when 'amber' then 1 else 2 end, (x->>'weight')::int desc), '[]'::jsonb)
    into v_actions from (select x from jsonb_array_elements(areas) x where x->>'tip' is not null limit 20) t;
  v_actions := (select coalesce(jsonb_agg(e), '[]'::jsonb) from (select e from jsonb_array_elements(v_actions) e limit 3) t);

  -- weekly snapshot (owner view only) + Monday summary in the bell
  v_week := date_trunc('week', v_today)::date;
  if v_owner and v_score is not null then
    insert into public.business_health_snapshots (property_id, week_start, score, areas)
    values (p_property, v_week, v_score::int, (select jsonb_object_agg(x->>'key', x->>'status') from jsonb_array_elements(areas) x))
    on conflict (property_id, week_start) do update set score = excluded.score, areas = excluded.areas, updated_at = now();
    if not exists (select 1 from public.notifications where property_id = p_property and kind = 'health_weekly' and created_at >= v_week) then
      insert into public.notifications (property_id, user_id, kind, title, body)
      select p_property, pm.user_id, 'health_weekly', 'Business health this week: ' || v_score::int || '/100',
             coalesce('Top action: ' || (v_actions->0->>'text'), 'All areas look good — keep it up!')
        from public.property_members pm where pm.property_id = p_property and pm.role = 'owner';
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('week_start', week_start, 'score', score) order by week_start), '[]'::jsonb) into v_trend
    from (select week_start, score from public.business_health_snapshots where property_id = p_property order by week_start desc limit 26) t;

  return jsonb_build_object('view', case when v_owner then 'owner' else 'operations' end, 'today', v_today, 'from', v_from,
    'score', v_score::int, 'label', case when v_score is null then 'Not enough data' when v_score >= 75 then 'Healthy' when v_score >= 55 then 'Needs attention' else 'At risk' end,
    'areas', areas, 'actions', v_actions, 'trend', case when v_owner then v_trend else '[]'::jsonb end);
end $$;

-- ---------------------------------------------------------------- grants
do $$
declare f text;
begin
  execute 'revoke execute on function public.business_health(uuid) from public, anon';
  execute 'grant execute on function public.business_health(uuid) to authenticated';
  foreach f in array array['_bh_tz(uuid)', '_bh_occ(uuid,date,date)', '_bh_income(uuid,date,date)',
    '_bh_area(text,text,text,text,text,text,text,integer)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

select to_regprocedure('public.business_health(uuid)') is not null as business_health_installed;


-- =====================================================================
-- NammaStay · 038_booking_page.sql — Book direct (zero commission)
--
-- Every property can switch on its own public booking page:
--     https://thenammastay.com/stay.html?p=<slug>
--
--   • Guests see photos, live availability (straight from the NammaStay calendar), prices
--     (price rules included), house rules, cancellation policy, reviews from verified stays
--   • Booking (default): guest picks dates + room/bed type → booked at once, pays at the property.
--     NammaStay takes no commission. Owner can choose "I confirm each booking myself" instead.
--   • Optional advance (owner's choice): beds are HELD as "pending" bookings for a few minutes →
--     guest pays the advance by UPI DIRECTLY to the property's own UPI ID (NammaStay never touches
--     the money) → guest enters the UTR → owner checks the bank app and taps Confirm → the advance
--     is recorded as a UPI payment and the bookings become confirmed.
--   • Unpaid holds (advance mode only) expire by themselves (default 30 minutes) and the beds free up.
--   • Reviews: only guests with a checked-out booking can review (link from the owner).
--
-- Owner: page settings. Owner + manager: requests and reviews. Guests (not signed in):
-- only the bp_* functions below, which show nothing private and are rate limited.
--
-- Needs (already on the live project): 026 price rules (_night_rate), 027 room types (cx_groups),
-- 007 subscriptions (_access_state). Uses 036 legal documents for the licence badge if installed.
--
-- ADD-ON ONLY — new tables, functions, one PUBLIC storage bucket for page photos ("stay-photos");
-- nothing existing is changed. Bookings made here are ordinary bookings (source "direct").
-- Safe to run more than once. Rollback: rollback_038_booking_page.sql
-- =====================================================================

do $$ begin
  if to_regprocedure('public.cx_groups(uuid)') is null or to_regprocedure('public._night_rate(uuid,uuid,integer,date)') is null
     or to_regprocedure('public._access_state(uuid)') is null then
    raise exception 'Run the earlier NammaStay migrations first (price rules, room types, subscriptions).';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.booking_pages (
  property_id      uuid primary key references public.properties(id) on delete cascade,
  slug             text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$' and slug !~ '--'),
  enabled          boolean not null default false,
  headline         text check (char_length(headline) <= 120),
  about            text check (char_length(about) <= 2000),
  amenities        text[] not null default '{}' check (cardinality(amenities) <= 30),
  house_rules      text check (char_length(house_rules) <= 1500),
  cancel_policy    text check (char_length(cancel_policy) <= 1000),
  advance_mode     text not null default 'none' check (advance_mode in ('percent','first_night','none')),
  advance_pct      int  not null default 30 check (advance_pct between 10 and 100),
  approve_first    boolean not null default false,           -- no advance: wait for the owner's OK instead of instant
  hold_minutes     int  not null default 30 check (hold_minutes between 15 and 180),
  max_nights       int  not null default 30 check (max_nights between 1 and 90),
  book_ahead_days  int  not null default 365 check (book_ahead_days between 14 and 730),
  whatsapp         text check (whatsapp is null or whatsapp ~ '^\+?[0-9]{8,15}$'),
  instagram        text check (instagram is null or instagram ~ '^[A-Za-z0-9._]{1,30}$'),
  map_url          text check (map_url is null or (map_url ~ '^https://' and char_length(map_url) <= 400)),
  show_address     boolean not null default true,
  show_licences    boolean not null default true,
  show_reviews     boolean not null default true,
  photos           jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 12),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create sequence if not exists public.booking_request_seq start 1001;

create table if not exists public.booking_requests (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  code          text not null unique default ('WEB-' || nextval('public.booking_request_seq')),
  token         uuid not null unique default gen_random_uuid(),     -- the guest's private status link
  status        text not null check (status in ('awaiting_payment','payment_claimed','awaiting_confirmation','confirmed','declined','expired','cancelled')),
  booking_ids   uuid[] not null default '{}',
  room_type     text not null,
  room_name     text not null,
  unit          text not null check (unit in ('bed','room')),
  units         int  not null check (units between 1 and 10),
  guests        int  not null check (guests between 1 and 40),
  check_in      date not null,
  check_out     date not null check (check_out > check_in),
  guest_name    text not null check (char_length(guest_name) between 2 and 120),
  guest_phone   text not null check (guest_phone ~ '^\+?[0-9]{8,15}$'),
  guest_email   text check (guest_email is null or guest_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  guest_note    text check (char_length(guest_note) <= 500),
  total_paise   int  not null check (total_paise >= 0),
  advance_paise int  not null default 0 check (advance_paise >= 0),
  utr           text check (utr is null or utr ~ '^[0-9A-Z]{6,35}$'),
  claimed_at    timestamptz,
  beds_lost     boolean not null default false,                       -- paid after the hold ran out and the beds were taken
  expires_at    timestamptz,
  decided_at    timestamptz,
  decided_by    uuid,
  owner_note    text check (char_length(owner_note) <= 500),
  client_key    text,                                                  -- hashed network address, for rate limits only
  created_at    timestamptz not null default now()
);
create index if not exists booking_requests_property on public.booking_requests (property_id, created_at desc);
create index if not exists booking_requests_open on public.booking_requests (property_id, expires_at)
  where status in ('awaiting_payment','awaiting_confirmation');
create index if not exists booking_requests_client on public.booking_requests (client_key, created_at desc);
create unique index if not exists booking_requests_utr on public.booking_requests (property_id, utr) where utr is not null;

create table if not exists public.stay_reviews (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  booking_id  uuid not null unique references public.bookings(id) on delete cascade,
  guest_name  text not null check (char_length(btrim(guest_name)) between 2 and 60),
  rating      int  not null check (rating between 1 and 5),
  body        text check (char_length(body) <= 1000),
  stayed_on   date not null,
  hidden      boolean not null default false,
  reply       text check (char_length(reply) <= 600),
  replied_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists stay_reviews_property on public.stay_reviews (property_id, created_at desc);

do $$ declare t text; begin
  foreach t in array array['booking_pages','booking_requests','stay_reviews'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);    -- only through the functions below
  end loop;
end $$;
revoke all on sequence public.booking_request_seq from anon, authenticated;

-- ---------------------------------------------------------------- page photos (PUBLIC bucket; owner + manager upload)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('stay-photos', 'stay-photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Path layout: {property_id}/{random}.{ext}
drop policy if exists "stay-photos: staff upload" on storage.objects;
create policy "stay-photos: staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'stay-photos' and exists (
    select 1 from public.my_property_ids(array['owner','manager']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "stay-photos: staff delete" on storage.objects;
create policy "stay-photos: staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'stay-photos' and exists (
    select 1 from public.my_property_ids(array['owner','manager']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));

-- ---------------------------------------------------------------- helpers (server only)
create or replace function public._bp_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata'))::date
$$;

-- Is the page taking bookings? (switched on, subscription running, not in PG mode)
create or replace function public._bp_open(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select bp.enabled from public.booking_pages bp where bp.property_id = p_property), false)
     and public._access_state(p_property) not in ('expired','suspended')
     and coalesce((select (to_jsonb(p)->>'is_pg')::boolean from public.properties p where p.id = p_property), false) = false
$$;

-- Hashed caller address (Supabase passes request headers); null when unknown
create or replace function public._bp_client_key() returns text
language plpgsql stable set search_path = public, pg_temp as $$
declare h json; ip text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  ip := coalesce(h->>'cf-connecting-ip', split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1), h->>'x-real-ip');
  return case when coalesce(btrim(ip), '') = '' then null else md5('nammastay-bp:' || btrim(ip)) end;
end $$;

-- Stay as a time range, property time
create or replace function public._bp_range(p public.properties, p_in date, p_out date) returns tstzrange
language sql stable set search_path = public, pg_temp as $$
  select tstzrange((p_in::timestamp + p.checkin_time) at time zone p.timezone, (p_out::timestamp + p.checkout_time) at time zone p.timezone, '[)')
$$;

-- Room / bed types the page sells (same grouping as the API and channel manager)
create or replace function public._bp_rooms(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', g->>'group_key', 'room_id', g->>'room_id', 'name', g->>'title',
      'description', (select r.description from public.rooms r where r.id = (g->>'room_id')::uuid),
      'unit', case when p.kind = 'hostel' and (g->>'occ_adults')::int <= 1 then 'bed' else 'room' end,
      'units', (g->>'count')::int, 'rate_paise', (g->>'rate_paise')::int,
      'max_guests', (select max(coalesce(bd.max_guests, 1)) from public.beds bd where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid)),
      'base_guests', (select max(coalesce(bd.base_guests, 1)) from public.beds bd where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid)),
      'extra_guest_paise', (select max(coalesce(bd.extra_guest_paise, 0)) from public.beds bd where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid)),
      'bed_ids', g->'bed_ids') order by g->>'sort', g->>'title'), '[]'::jsonb)
    from jsonb_array_elements(public.cx_groups(p_property)) g, public.properties p
   where p.id = p_property
$$;

-- Free units of one type for a range
create or replace function public._bp_free(p public.properties, p_beds jsonb, p_range tstzrange) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from jsonb_array_elements_text(p_beds) bid
   where not exists (select 1 from public.bookings k where k.bed_id = bid::uuid and k.status in ('pending','confirmed','checked_in') and k.stay && p_range)
     and not exists (select 1 from public.bed_blocks z where z.bed_id = bid::uuid and z.period && p_range)
$$;

create or replace function public._bp_min_stay(p_property uuid, p_room uuid, p_day date) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(1, coalesce((select max(r.min_nights) from public.rate_rules r
    where r.property_id = p_property and r.is_active and r.min_nights is not null
      and (r.room_ids is null or p_room = any (r.room_ids))
      and ((r.kind = 'season' and p_day between r.date_from and r.date_to)
        or (r.kind = 'weekend' and extract(dow from p_day)::smallint = any (r.weekdays)))), 1))
$$;

-- Free the beds of unpaid holds whose time ran out
create or replace function public._bp_expire(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  for r in select * from public.booking_requests
            where property_id = p_property and status in ('awaiting_payment','awaiting_confirmation') and expires_at < now()
            for update skip locked loop
    update public.bookings set status = 'cancelled', cancelled_at = now(),
           note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': ' ||
                  case when r.status = 'awaiting_payment' then 'advance not paid in time — beds released.' else 'not confirmed in time — beds released.' end), 2000)
     where id = any (r.booking_ids) and status = 'pending';
    update public.booking_requests set status = 'expired' where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- For a scheduled job (optional): expire everywhere
create or replace function public.bp_expire_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v int := 0; pid uuid;
begin
  for pid in select distinct property_id from public.booking_requests
              where status in ('awaiting_payment','awaiting_confirmation') and expires_at < now() loop
    v := v + public._bp_expire(pid);
  end loop;
  return v;
end $$;

create or replace function public._bp_page_by_slug(p_slug text) returns public.booking_pages
language sql stable security definer set search_path = public, pg_temp as $$
  select * from public.booking_pages where slug = lower(btrim(coalesce(p_slug, '')))
$$;

-- Licence documents on file (only if the My investment pack, 036, is installed)
create or replace function public._bp_licences(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  if to_regclass('public.legal_documents') is null then return '[]'::jsonb; end if;
  execute $q$select coalesce(jsonb_agg(distinct d.doc_type), '[]'::jsonb) from public.legal_documents d
             where d.property_id = $1 and d.doc_type in ('trade_licence','fire_noc','fssai','gst','police','tourism','building_approval','pollution')
               and (d.expires_on is null or d.expires_on >= $2)$q$
    into v using p_property, public._bp_today(p_property);
  return coalesce(v, '[]'::jsonb);
end $$;

-- What the guest's status page shows
create or replace function public._bp_request_json(r public.booking_requests) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('code', r.code, 'token', r.token, 'status', r.status, 'room_name', r.room_name, 'unit', r.unit,
           'units', r.units, 'guests', r.guests, 'check_in', r.check_in, 'check_out', r.check_out, 'nights', r.check_out - r.check_in,
           'guest_name', r.guest_name, 'total_paise', r.total_paise, 'advance_paise', r.advance_paise,
           'balance_paise', r.total_paise - r.advance_paise, 'utr', r.utr, 'expires_at', r.expires_at, 'beds_lost', r.beds_lost,
           'seconds_left', case when r.status = 'awaiting_payment' then greatest(0, extract(epoch from r.expires_at - now()))::int end,
           'property', jsonb_build_object('name', p.name, 'city', p.city, 'slug', bp.slug, 'upi_id', p.upi_id,
              'payee', left(coalesce(nullif(to_jsonb(p)->>'legal_name', ''), p.name), 50),
              'whatsapp', coalesce(bp.whatsapp, p.phone), 'checkin_time', to_char(p.checkin_time, 'HH24:MI'),
              'checkout_time', to_char(p.checkout_time, 'HH24:MI'), 'cancel_policy', bp.cancel_policy),
           'self_checkin_token', case when r.status = 'confirmed' then
              (select b.self_checkin_token from public.bookings b where b.id = r.booking_ids[1]) end)
    from public.properties p left join public.booking_pages bp on bp.property_id = p.id
   where p.id = r.property_id
$$;

-- ---------------------------------------------------------------- PUBLIC (guests, not signed in)
create or replace function public.bp_public(p_slug text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare bp public.booking_pages; p public.properties; v_open boolean; rv jsonb; rooms jsonb;
begin
  bp := public._bp_page_by_slug(p_slug);
  if bp.property_id is null then return jsonb_build_object('found', false); end if;
  select * into p from public.properties where id = bp.property_id;
  v_open := public._bp_open(p.id);
  if not bp.enabled then return jsonb_build_object('found', false); end if;
  perform public._bp_expire(p.id);
  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) into rv
    from (select jsonb_build_object('name', r.guest_name, 'rating', r.rating, 'body', r.body, 'stayed_on', to_char(r.stayed_on, 'Mon YYYY'),
                 'reply', r.reply) j, r.created_at
            from public.stay_reviews r where r.property_id = p.id and not r.hidden order by r.created_at desc limit 12) x;
  select coalesce(jsonb_agg(e - 'bed_ids' - 'room_id'), '[]'::jsonb) into rooms from jsonb_array_elements(public._bp_rooms(p.id)) e;
  return jsonb_build_object('found', true, 'open', v_open,
    'property', jsonb_build_object('name', p.name, 'kind', p.kind, 'city', p.city,
       'address', case when bp.show_address then p.address end, 'timezone', p.timezone,
       'checkin_time', to_char(p.checkin_time, 'HH24:MI'), 'checkout_time', to_char(p.checkout_time, 'HH24:MI'),
       'whatsapp', coalesce(bp.whatsapp, p.phone), 'instagram', bp.instagram, 'map_url', bp.map_url),
    'page', jsonb_build_object('slug', bp.slug, 'headline', bp.headline, 'about', bp.about, 'amenities', to_jsonb(bp.amenities),
       'house_rules', bp.house_rules, 'cancel_policy', bp.cancel_policy, 'photos', bp.photos,
       'advance_mode', case when bp.advance_mode <> 'none' and coalesce(p.upi_id, '') = '' then 'none' else bp.advance_mode end,
       'advance_pct', bp.advance_pct, 'approve_first', bp.approve_first or (bp.advance_mode <> 'none' and coalesce(p.upi_id, '') = ''),
       'hold_minutes', bp.hold_minutes, 'max_nights', bp.max_nights, 'book_ahead_days', bp.book_ahead_days),
    'today', public._bp_today(p.id),
    'rooms', rooms,
    'licences', case when bp.show_licences then public._bp_licences(p.id) else '[]'::jsonb end,
    'reviews', case when bp.show_reviews then jsonb_build_object(
        'count', (select count(*) from public.stay_reviews r where r.property_id = p.id and not r.hidden),
        'average', (select round(avg(r.rating)::numeric, 1) from public.stay_reviews r where r.property_id = p.id and not r.hidden),
        'items', rv) end);
end $$;

-- p_from .. p_to = check-in .. check-out (also used for the 2-week calendar strip)
create or replace function public.bp_availability(p_slug text, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare bp public.booking_pages; p public.properties; v_today date;
begin
  bp := public._bp_page_by_slug(p_slug);
  if bp.property_id is null or not bp.enabled then raise exception 'This booking page is not available.' using errcode = 'P0404'; end if;
  select * into p from public.properties where id = bp.property_id;
  v_today := public._bp_today(p.id);
  if p_from is null or p_to is null or p_to <= p_from then raise exception 'Choose a check-out date after check-in.'; end if;
  if p_from < v_today then raise exception 'Check-in can''t be in the past.'; end if;
  if p_to - p_from > 62 then raise exception 'Choose at most 62 nights.'; end if;
  if p_from > v_today + bp.book_ahead_days then raise exception 'Bookings open % days ahead.', bp.book_ahead_days; end if;
  perform public._bp_expire(p.id);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', g->>'id',
      'nights', (select jsonb_agg(jsonb_build_object('date', d::date,
            'free', public._bp_free(p, g->'bed_ids', public._bp_range(p, d::date, d::date + 1))
                    * (case when public._bp_open(p.id) then 1 else 0 end),
            'price_paise', public._night_rate(p.id, (g->>'room_id')::uuid, (g->>'rate_paise')::int, d::date),
            'min_stay', public._bp_min_stay(p.id, (g->>'room_id')::uuid, d::date)) order by d)
          from generate_series(p_from, p_to - 1, interval '1 day') d),
      'free_for_stay', public._bp_free(p, g->'bed_ids', public._bp_range(p, p_from, p_to)) * (case when public._bp_open(p.id) then 1 else 0 end),
      'stay_paise', (select sum(public._night_rate(p.id, (g->>'room_id')::uuid, (g->>'rate_paise')::int, d::date))
                       from generate_series(p_from, p_to - 1, interval '1 day') d)::int,
      'min_stay', (select max(public._bp_min_stay(p.id, (g->>'room_id')::uuid, d::date)) from generate_series(p_from, p_to - 1, interval '1 day') d)
    )), '[]'::jsonb)
    from jsonb_array_elements(public._bp_rooms(p.id)) g);
end $$;

-- p: { room_type, check_in, check_out, units, guests, name, phone, email?, note?, website? (left empty by people) }
create or replace function public.bp_request(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  bp public.booking_pages; pr public.properties; g jsonb; v_today date; v_in date; v_out date; v_n int;
  v_units int; v_guests int; v_name text; v_phone text; v_mail text; v_note text; v_key text;
  v_guest uuid; v_bed uuid; v_bk uuid; v_ids uuid[] := '{}'; v_tries int; v_vis int; v_extra int;
  v_total int; v_adv int; v_status text; v_r public.booking_requests; v_code text; v_unit text; v_min int; v_maxg int;
begin
  bp := public._bp_page_by_slug(p_slug);
  if bp.property_id is null or not bp.enabled then raise exception 'This booking page is not available.' using errcode = 'P0404'; end if;
  if not public._bp_open(bp.property_id) then raise exception 'Online booking is paused right now — please message the host on WhatsApp.'; end if;
  if coalesce(p->>'website', '') <> '' then raise exception 'Please try again.'; end if;          -- form filled by a robot
  select * into pr from public.properties where id = bp.property_id;
  perform public._bp_expire(pr.id);
  v_today := public._bp_today(pr.id);

  select e into g from jsonb_array_elements(public._bp_rooms(pr.id)) e where e->>'id' = p->>'room_type';
  if g is null then raise exception 'Please choose a room or bed type.'; end if;
  begin v_in := (p->>'check_in')::date; v_out := (p->>'check_out')::date;
  exception when others then raise exception 'Choose your check-in and check-out dates.'; end;
  if v_in is null or v_out is null or v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;
  if v_in < v_today then raise exception 'Check-in can''t be in the past.'; end if;
  if v_in > v_today + bp.book_ahead_days then raise exception 'Bookings open % days ahead.', bp.book_ahead_days; end if;
  v_n := v_out - v_in;
  if v_n > bp.max_nights then raise exception 'You can book up to % nights online — message the host for longer stays.', bp.max_nights; end if;
  select max(public._bp_min_stay(pr.id, (g->>'room_id')::uuid, d::date)) into v_min from generate_series(v_in, v_out - 1, interval '1 day') d;
  if v_n < v_min then raise exception 'Minimum stay for these dates is % nights.', v_min; end if;

  v_unit := g->>'unit';
  v_units := coalesce(nullif(p->>'units', '')::int, 1);
  if v_units not between 1 and 10 then raise exception 'You can book 1 to 10 % at a time.', v_unit || 's'; end if;
  v_maxg := greatest(1, (g->>'max_guests')::int);
  v_guests := case when v_unit = 'bed' then v_units else coalesce(nullif(p->>'guests', '')::int, v_units) end;
  if v_guests < v_units then raise exception 'Each room needs at least one guest.'; end if;
  if v_guests > v_units * v_maxg then raise exception '% % fit up to % guests.', v_units, case when v_units = 1 then 'room' else 'rooms' end, v_units * v_maxg; end if;

  v_name := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  if char_length(v_name) < 2 or char_length(v_name) > 120 then raise exception 'Please enter your full name.'; end if;
  v_phone := public._clean_phone(p->>'phone');
  if v_phone is not null and v_phone ~ '^[6-9][0-9]{9}$' then v_phone := '+91' || v_phone; end if;
  if v_phone is null or v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please enter a WhatsApp number we can reach you on.'; end if;
  v_mail := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  if v_mail is not null and v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address looks wrong.'; end if;
  v_note := nullif(left(btrim(coalesce(p->>'note', '')), 500), '');

  -- limits against abuse
  v_key := public._bp_client_key();
  if v_key is not null and (select count(*) from public.booking_requests where client_key = v_key and created_at > now() - interval '1 hour') >= 6 then
    raise exception 'Too many booking attempts — please wait a while or message the host.';
  end if;
  if (select count(*) from public.booking_requests where property_id = pr.id and guest_phone = v_phone
        and status in ('awaiting_payment','awaiting_confirmation')) >= 2 then
    raise exception 'You already have a booking waiting — finish or cancel it first.';
  end if;
  if (select count(*) from public.booking_requests where property_id = pr.id and guest_phone = v_phone
        and created_at > now() - interval '24 hours' and status not in ('cancelled','expired','declined')) >= 3 then
    raise exception 'You have already booked here today — message the host on WhatsApp to add more.';
  end if;
  if (select count(*) from public.booking_requests where property_id = pr.id and status in ('awaiting_payment','awaiting_confirmation')) >= 25 then
    raise exception 'The page is busy — please try again in a few minutes.';
  end if;
  if public._bp_free(pr, g->'bed_ids', public._bp_range(pr, v_in, v_out)) < v_units then
    v_tries := public._bp_free(pr, g->'bed_ids', public._bp_range(pr, v_in, v_out));
    raise exception '%', case when v_tries = 0 then 'Sorry — fully booked for these dates.'
                              else format('Sorry — only %s %s free for these dates.', v_tries, v_unit || case when v_tries = 1 then '' else 's' end) end
      using errcode = 'P0409';
  end if;

  -- guest card (same phone at this property = same guest)
  select id into v_guest from public.guests where property_id = pr.id and phone = v_phone order by created_at limit 1;
  if v_guest is null then
    insert into public.guests (property_id, full_name, phone, email) values (pr.id, v_name, v_phone, v_mail) returning id into v_guest;
  elsif v_mail is not null then
    update public.guests set email = coalesce(email, v_mail) where id = v_guest;
  end if;

  v_code := 'WEB-' || nextval('public.booking_request_seq');
  v_status := case when bp.advance_mode <> 'none' and coalesce(pr.upi_id, '') <> '' then 'awaiting_payment'
                   when bp.approve_first or bp.advance_mode <> 'none' then 'awaiting_confirmation'
                   else 'confirmed' end;

  for i in 1 .. v_units loop
    v_vis := case when v_unit = 'bed' then 1 else v_guests / v_units + case when i <= v_guests % v_units then 1 else 0 end end;
    v_tries := 0;
    loop
      select bd.id, greatest(0, v_vis - coalesce(bd.base_guests, 1)) * coalesce(bd.extra_guest_paise, 0) into v_bed, v_extra
        from public.beds bd
       where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid) and bd.is_active and bd.id <> all (
               select k.bed_id from public.bookings k where k.id = any (v_ids))
         and coalesce(bd.max_guests, 1) >= v_vis
         and not exists (select 1 from public.bookings x where x.bed_id = bd.id and x.status in ('pending','confirmed','checked_in')
                           and x.stay && public._bp_range(pr, v_in, v_out))
         and not exists (select 1 from public.bed_blocks z where z.bed_id = bd.id and z.period && public._bp_range(pr, v_in, v_out))
       order by bd.sort, bd.label limit 1;
      if v_bed is null then raise exception 'Sorry — those were just booked. Please pick again.' using errcode = 'P0409'; end if;
      begin
        insert into public.bookings (property_id, guest_id, bed_id, visitors, extra_paise, check_in_at, check_out_at, nights,
                                     rate_paise, total_paise, status, source, note, send_confirmation, created_by)
        values (pr.id, v_guest, v_bed, v_vis, v_extra,
                (v_in::timestamp + pr.checkin_time) at time zone pr.timezone, (v_out::timestamp + pr.checkout_time) at time zone pr.timezone,
                v_n, (g->>'rate_paise')::int, v_n * ((g->>'rate_paise')::int + v_extra),
                case when v_status = 'confirmed' then 'confirmed' else 'pending' end::public.booking_status, 'direct',
                left(concat_ws(E'\n', 'Booking page ' || v_code || case v_status when 'awaiting_payment' then ' · waiting for UPI advance'
                                                                   when 'awaiting_confirmation' then ' · waiting for your OK' else '' end,
                               case when v_note is not null then 'Guest note: ' || v_note end), 2000),
                false, null)
        returning id into v_bk;
        v_ids := v_ids || v_bk;
        exit;
      exception when exclusion_violation then
        v_tries := v_tries + 1;
        if v_tries > 5 then raise exception 'Sorry — those were just booked. Please pick again.' using errcode = 'P0409'; end if;
      end;
    end loop;
  end loop;

  select sum(total_paise)::int into v_total from public.bookings where id = any (v_ids);    -- price rules already applied
  v_adv := case when v_status <> 'awaiting_payment' then 0
                when bp.advance_mode = 'percent' then least(v_total, (ceil(v_total * bp.advance_pct / 100.0 / 100.0) * 100)::int)
                else least(v_total, (select sum(public._night_rate(pr.id, b.room_id, b.rate_paise, v_in) + k.extra_paise)::int
                                       from public.bookings k join public.beds b on b.id = k.bed_id where k.id = any (v_ids))) end;
  if v_status = 'awaiting_payment' and v_adv = 0 then v_status := 'confirmed';
    update public.bookings set status = 'confirmed' where id = any (v_ids);
  end if;

  insert into public.booking_requests (property_id, code, status, booking_ids, room_type, room_name, unit, units, guests, check_in, check_out,
                                       guest_name, guest_phone, guest_email, guest_note, total_paise, advance_paise, expires_at, client_key,
                                       decided_at)
  values (pr.id, v_code, v_status, v_ids, g->>'id', g->>'name', v_unit, v_units, v_guests, v_in, v_out,
          v_name, v_phone, v_mail, v_note, v_total, v_adv,
          case v_status when 'awaiting_payment' then now() + make_interval(mins => bp.hold_minutes)
                        when 'awaiting_confirmation' then now() + interval '24 hours' end, v_key,
          case when v_status = 'confirmed' then now() end)
  returning * into v_r;

  if v_status = 'confirmed' then
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (pr.id, 'web_booking', 'Booking page: new booking ' || v_code,
            format('%s · %s %s · %s → %s · pays at the property', v_name, v_units, v_unit || case when v_units > 1 then 's' else '' end, to_char(v_in, 'DD Mon'), to_char(v_out, 'DD Mon')), v_ids[1]);
  end if;
  if v_status = 'awaiting_confirmation' then
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (pr.id, 'web_request', 'Booking page: ' || v_code || ' needs your OK',
            format('%s · %s %s · %s → %s', v_name, v_units, v_unit || case when v_units > 1 then 's' else '' end, to_char(v_in, 'DD Mon'), to_char(v_out, 'DD Mon')), v_ids[1]);
  end if;
  return public._bp_request_json(v_r);
end $$;

create or replace function public.bp_request_status(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests;
begin
  select property_id into r.property_id from public.booking_requests where token = p_token;
  if r.property_id is null then raise exception 'Booking not found — check the link.' using errcode = 'P0404'; end if;
  perform public._bp_expire(r.property_id);
  select * into r from public.booking_requests where token = p_token;
  return public._bp_request_json(r);
end $$;

-- Guest: "I've paid" + the UPI reference (UTR) from their payment app
create or replace function public.bp_claim_paid(p_token uuid, p_utr text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests; v_utr text;
begin
  select * into r from public.booking_requests where token = p_token for update;
  if not found then raise exception 'Booking not found — check the link.' using errcode = 'P0404'; end if;
  v_utr := upper(regexp_replace(coalesce(p_utr, ''), '[^0-9A-Za-z]', '', 'g'));
  if v_utr !~ '^[0-9A-Z]{6,35}$' then raise exception 'Enter the UPI reference (UTR) — usually 12 digits — from your payment app.'; end if;
  if r.status in ('payment_claimed','confirmed') and r.utr is not null then return public._bp_request_json(r); end if;
  if r.status not in ('awaiting_payment','expired') then raise exception 'This booking can''t take a payment now (%). Please message the host.', replace(r.status, '_', ' '); end if;
  if r.status = 'expired' and r.expires_at < now() - interval '24 hours' then
    raise exception 'This booking expired a while ago. If you paid, message the host with your UTR.';
  end if;
  if exists (select 1 from public.payments where property_id = r.property_id and method = 'upi' and reference = v_utr)
     or exists (select 1 from public.booking_requests where property_id = r.property_id and utr = v_utr and id <> r.id) then
    raise exception 'This UPI reference was already used for another booking. Check the number.';
  end if;
  if r.status = 'expired' then                                   -- paid a little late: try to get the beds back
    begin
      update public.bookings set status = 'pending', cancelled_at = null where id = any (r.booking_ids) and status = 'cancelled';
    exception when exclusion_violation then
      r.beds_lost := true;
    end;
  end if;
  update public.booking_requests set status = 'payment_claimed', utr = v_utr, claimed_at = now(), expires_at = null, beds_lost = r.beds_lost
   where id = r.id returning * into r;
  insert into public.notifications (property_id, kind, title, body, booking_id)
  values (r.property_id, 'web_paid', 'Booking page: ' || r.code || ' says advance paid',
          format('%s paid ₹%s · UTR %s — check your bank app and confirm.%s', r.guest_name, to_char(r.advance_paise / 100.0, 'FM99,99,99,990'), v_utr,
                 case when r.beds_lost then ' Beds were taken after the hold ran out — move or refund.' else '' end), r.booking_ids[1]);
  return public._bp_request_json(r);
end $$;

-- Guest cancels before paying
create or replace function public.bp_cancel_request(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests;
begin
  select * into r from public.booking_requests where token = p_token for update;
  if not found then raise exception 'Booking not found — check the link.' using errcode = 'P0404'; end if;
  if r.status not in ('awaiting_payment','awaiting_confirmation') then
    raise exception 'This booking can''t be cancelled here — please message the host.';
  end if;
  update public.bookings set status = 'cancelled', cancelled_at = now(),
         note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': cancelled by the guest before paying.'), 2000)
   where id = any (r.booking_ids) and status = 'pending';
  update public.booking_requests set status = 'cancelled', expires_at = null where id = r.id returning * into r;
  return public._bp_request_json(r);
end $$;

-- Reviews: the link carries the booking's own private token (the self check-in token)
create or replace function public.bp_review_get(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; p public.properties; g public.guests; rv public.stay_reviews;
begin
  select * into b from public.bookings where self_checkin_token = p_token;
  if not found then raise exception 'Review link not found.' using errcode = 'P0404'; end if;
  select * into p from public.properties where id = b.property_id;
  select * into g from public.guests where id = b.guest_id;
  select * into rv from public.stay_reviews where booking_id = b.id;
  return jsonb_build_object('property', p.name, 'slug', (select slug from public.booking_pages where property_id = p.id),
    'can_review', b.status = 'checked_out' and coalesce(b.departed_at, b.check_out_at) > now() - interval '90 days',
    'status', b.status, 'check_in', public._local_date(p.id, b.check_in_at), 'check_out', public._local_date(p.id, b.check_out_at),
    'first_name', split_part(g.full_name, ' ', 1),
    'review', case when rv.id is not null then jsonb_build_object('rating', rv.rating, 'body', rv.body, 'name', rv.guest_name) end);
end $$;

create or replace function public.bp_review_submit(p_token uuid, p_rating int, p_body text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; v_new boolean;
begin
  select * into b from public.bookings where self_checkin_token = p_token;
  if not found then raise exception 'Review link not found.' using errcode = 'P0404'; end if;
  if b.status <> 'checked_out' then raise exception 'You can review after you check out.'; end if;
  if coalesce(b.departed_at, b.check_out_at) < now() - interval '90 days' then raise exception 'Reviews are open for 90 days after the stay.'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose 1 to 5 stars.'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 60 then raise exception 'Add the name to show with your review (e.g. Ananya, Bengaluru).'; end if;
  v_new := not exists (select 1 from public.stay_reviews where booking_id = b.id);
  insert into public.stay_reviews (property_id, booking_id, guest_name, rating, body, stayed_on)
  values (b.property_id, b.id, btrim(p_name), p_rating, nullif(left(btrim(coalesce(p_body, '')), 1000), ''), public._local_date(b.property_id, b.check_in_at))
  on conflict (booking_id) do update set guest_name = excluded.guest_name, rating = excluded.rating, body = excluded.body, updated_at = now();
  if v_new then
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (b.property_id, 'web_review', 'New review · ' || repeat('★', p_rating), btrim(p_name) || ' · ' || b.code, b.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- STAFF (signed in)
create or replace function public.bp_settings_get(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role public.member_role; bp public.booking_pages; p public.properties; v_slug text; n int := 1;
begin
  v_role := public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  select * into p from public.properties where id = p_property;
  select * into bp from public.booking_pages where property_id = p_property;
  if bp.property_id is null then                                  -- suggest an address from the name
    v_slug := trim(both '-' from regexp_replace(regexp_replace(lower(p.name), '[^a-z0-9]+', '-', 'g'), '-+', '-', 'g'));
    if char_length(v_slug) < 3 then v_slug := 'stay-' || substr(replace(p.id::text, '-', ''), 1, 6); end if;
    v_slug := left(v_slug, 44);
    while exists (select 1 from public.booking_pages where slug = v_slug) loop
      n := n + 1; v_slug := left(regexp_replace(v_slug, '-[0-9]+$', ''), 44) || '-' || n;
    end loop;
  end if;
  return jsonb_build_object('role', v_role, 'exists', bp.property_id is not null,
    'page', case when bp.property_id is not null then to_jsonb(bp) - 'property_id' else jsonb_build_object(
       'slug', v_slug, 'enabled', false, 'headline', null, 'about', null, 'amenities', '[]'::jsonb, 'house_rules',
       'Check-in from ' || to_char(p.checkin_time, 'HH12:MI AM') || ' · Check-out by ' || to_char(p.checkout_time, 'HH12:MI AM') || E'\nGovernment photo ID needed at check-in',
       'cancel_policy', 'Free cancellation up to 3 days before check-in — the advance is refunded by UPI. After that, the advance is kept.',
       'advance_mode', 'none', 'advance_pct', 30, 'approve_first', false, 'hold_minutes', 30, 'max_nights', 30, 'book_ahead_days', 365,
       'whatsapp', null, 'instagram', null, 'map_url', null, 'show_address', true, 'show_licences', true, 'show_reviews', true, 'photos', '[]'::jsonb) end,
    'property', jsonb_build_object('name', p.name, 'kind', p.kind, 'city', p.city, 'phone', p.phone, 'upi_id', p.upi_id,
       'is_pg', coalesce((to_jsonb(p)->>'is_pg')::boolean, false)),
    'access', public._access_state(p_property),
    'rooms', (select count(*) from jsonb_array_elements(public._bp_rooms(p_property))),
    'licences', public._bp_licences(p_property),
    'licences_installed', to_regclass('public.legal_documents') is not null);
end $$;

create or replace function public.bp_slug_free(p_property uuid, p_slug text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return not exists (select 1 from public.booking_pages where slug = lower(btrim(p_slug)) and property_id <> p_property)
     and lower(btrim(p_slug)) not in ('admin','api','app','www','stay','demo','login','signup','help','support','nammastay','test','book','booking');
end $$;

-- Owner only. p: any of the booking_pages columns
create or replace function public.bp_settings_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_slug text; v_photos jsonb; v_am text[]; v_wa text; v_mode text; pr public.properties;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select * into pr from public.properties where id = p_property;
  v_slug := lower(btrim(coalesce(p->>'slug', '')));
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$' or v_slug ~ '--' then
    raise exception 'Page address: 3–50 letters, numbers and single dashes (e.g. social-backpackers-gokarna).';
  end if;
  if not public.bp_slug_free(p_property, v_slug) then raise exception 'That page address is taken — try adding your town.'; end if;
  v_mode := coalesce(nullif(p->>'advance_mode', ''), 'none');
  if coalesce((p->>'enabled')::boolean, false) then
    if coalesce((to_jsonb(pr)->>'is_pg')::boolean, false) then raise exception 'The booking page is for nightly stays — it is off while PG mode is on.'; end if;
    if jsonb_array_length(public._bp_rooms(p_property)) = 0 then raise exception 'Add your rooms and beds first (Rooms & beds).'; end if;
    if v_mode <> 'none' and coalesce(pr.upi_id, '') = '' then
      raise exception 'Add your UPI ID first (Settings → Payments) — guests pay the advance straight to it. Or choose "No advance".';
    end if;
  end if;
  v_photos := coalesce(p->'photos', '[]'::jsonb);
  if jsonb_typeof(v_photos) <> 'array' or jsonb_array_length(v_photos) > 12 then raise exception 'Up to 12 photos.'; end if;
  if exists (select 1 from jsonb_array_elements(v_photos) e
              where coalesce(e->>'path', '') not like p_property::text || '/%' or e->>'path' ~ '\.\.' or char_length(coalesce(e->>'caption', '')) > 80) then
    raise exception 'Photo list is invalid — please upload again.';
  end if;
  v_photos := (select coalesce(jsonb_agg(jsonb_build_object('path', e->>'path', 'caption', nullif(btrim(coalesce(e->>'caption', '')), ''))), '[]'::jsonb)
                 from jsonb_array_elements(v_photos) e);
  select coalesce(array_agg(x), '{}') into v_am from (
    select distinct on (lower(btrim(a))) left(btrim(a), 40) x from jsonb_array_elements_text(coalesce(p->'amenities', '[]'::jsonb)) a
     where btrim(a) <> '' limit 30) s;
  v_wa := public._clean_phone(p->>'whatsapp');
  if v_wa ~ '^[6-9][0-9]{9}$' then v_wa := '+91' || v_wa; end if;

  insert into public.booking_pages as bp (property_id, slug, enabled, headline, about, amenities, house_rules, cancel_policy, advance_mode, advance_pct,
       approve_first, hold_minutes, max_nights, book_ahead_days, whatsapp, instagram, map_url, show_address, show_licences, show_reviews, photos)
  values (p_property, v_slug, coalesce((p->>'enabled')::boolean, false), nullif(btrim(p->>'headline'), ''), nullif(btrim(p->>'about'), ''), v_am,
       nullif(btrim(p->>'house_rules'), ''), nullif(btrim(p->>'cancel_policy'), ''), v_mode, coalesce(nullif(p->>'advance_pct', '')::int, 30),
       coalesce((p->>'approve_first')::boolean, false), coalesce(nullif(p->>'hold_minutes', '')::int, 30), coalesce(nullif(p->>'max_nights', '')::int, 30),
       coalesce(nullif(p->>'book_ahead_days', '')::int, 365), v_wa, nullif(ltrim(btrim(coalesce(p->>'instagram', '')), '@'), ''),
       nullif(btrim(p->>'map_url'), ''), coalesce((p->>'show_address')::boolean, true), coalesce((p->>'show_licences')::boolean, true),
       coalesce((p->>'show_reviews')::boolean, true), v_photos)
  on conflict (property_id) do update set slug = excluded.slug, enabled = excluded.enabled, headline = excluded.headline, about = excluded.about,
       amenities = excluded.amenities, house_rules = excluded.house_rules, cancel_policy = excluded.cancel_policy, advance_mode = excluded.advance_mode,
       advance_pct = excluded.advance_pct, approve_first = excluded.approve_first, hold_minutes = excluded.hold_minutes, max_nights = excluded.max_nights,
       book_ahead_days = excluded.book_ahead_days, whatsapp = excluded.whatsapp, instagram = excluded.instagram, map_url = excluded.map_url,
       show_address = excluded.show_address, show_licences = excluded.show_licences, show_reviews = excluded.show_reviews, photos = excluded.photos,
       updated_at = now();
  return public.bp_settings_get(p_property);
end $$;

-- Owner + manager: requests from the page (newest first). p_filter: 'open' (needs action) | 'all'
create or replace function public.bp_requests(p_property uuid, p_filter text default 'open') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._bp_expire(p_property);
  return jsonb_build_object(
    'counts', jsonb_build_object(
       'needs_action', (select count(*) from public.booking_requests where property_id = p_property and status in ('payment_claimed','awaiting_confirmation')),
       'waiting_payment', (select count(*) from public.booking_requests where property_id = p_property and status = 'awaiting_payment'),
       'confirmed_30d', (select count(*) from public.booking_requests where property_id = p_property and status = 'confirmed' and created_at > now() - interval '30 days'),
       'value_30d', (select coalesce(sum(total_paise), 0) from public.booking_requests where property_id = p_property and status = 'confirmed' and created_at > now() - interval '30 days')),
    'items', coalesce((select jsonb_agg(x.j order by x.ord, x.created_at desc) from (
       select jsonb_build_object('id', r.id, 'code', r.code, 'token', r.token, 'status', r.status, 'room_name', r.room_name, 'unit', r.unit,
                'units', r.units, 'guests', r.guests, 'check_in', r.check_in, 'check_out', r.check_out, 'nights', r.check_out - r.check_in,
                'guest_name', r.guest_name, 'guest_phone', r.guest_phone, 'guest_email', r.guest_email, 'guest_note', r.guest_note,
                'total_paise', r.total_paise, 'advance_paise', r.advance_paise, 'utr', r.utr, 'claimed_at', r.claimed_at, 'beds_lost', r.beds_lost,
                'expires_at', r.expires_at, 'decided_at', r.decided_at, 'owner_note', r.owner_note, 'created_at', r.created_at,
                'bookings', (select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'status', b.status, 'bed', bd.label, 'paid_paise', b.paid_paise,
                                 'self_checkin_token', b.self_checkin_token) order by b.code)
                               from public.bookings b join public.beds bd on bd.id = b.bed_id where b.id = any (r.booking_ids))) j,
              r.created_at,
              case r.status when 'payment_claimed' then 0 when 'awaiting_confirmation' then 1 when 'awaiting_payment' then 2 else 3 end ord
         from public.booking_requests r
        where r.property_id = p_property
          and (coalesce(p_filter, 'open') = 'all' or r.status in ('payment_claimed','awaiting_confirmation','awaiting_payment')
               or (r.status in ('confirmed','declined') and r.decided_at > now() - interval '2 days'))
        order by ord, r.created_at desc limit 200) x), '[]'::jsonb));
end $$;

-- p_action: 'confirm' (advance received → recorded as a UPI payment) | 'confirm_unpaid' (confirm without recording money)
--           | 'decline' (beds released; if the guest paid, refund them)
create or replace function public.bp_request_decide(p_id uuid, p_action text, p_amount int default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests; v_left int; v_amt int; v_part int; b record; i int := 0; v_ref text;
begin
  select * into r from public.booking_requests where id = p_id for update;
  if not found then raise exception 'Request not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(r.property_id, array['owner','manager']::public.member_role[]);
  if p_action not in ('confirm','confirm_unpaid','decline') then raise exception 'Unknown action.'; end if;
  if r.status in ('confirmed','declined','cancelled') then raise exception 'Already %.', r.status; end if;
  if r.status = 'expired' and p_action <> 'decline' then
    -- late OK from the owner: take the beds back if still free
    begin
      update public.bookings set status = 'pending', cancelled_at = null where id = any (r.booking_ids) and status = 'cancelled';
    exception when exclusion_violation then
      raise exception 'The hold ran out and those beds/rooms are booked now. Decline, or book the guest into other beds from Bookings.';
    end;
  end if;

  if p_action = 'decline' then
    update public.bookings set status = 'cancelled', cancelled_at = now(),
           note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': declined' || coalesce(' — ' || nullif(btrim(p_note), ''), '')), 2000)
     where id = any (r.booking_ids) and status in ('pending','confirmed');
    update public.booking_requests set status = 'declined', decided_at = now(), decided_by = auth.uid(), owner_note = nullif(left(btrim(coalesce(p_note, '')), 500), '')
     where id = r.id returning * into r;
    return jsonb_build_object('status', r.status, 'refund_paise', case when r.utr is not null then r.advance_paise else 0 end);
  end if;

  if r.beds_lost and exists (select 1 from public.bookings where id = any (r.booking_ids) and status = 'cancelled') then
    raise exception 'Those beds/rooms were booked by someone else after the hold ran out. Decline (and refund), or book the guest into other beds from Bookings.';
  end if;

  update public.bookings set status = 'confirmed',
         note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': confirmed'), 2000)
   where id = any (r.booking_ids) and status = 'pending';

  if p_action = 'confirm' and r.status in ('payment_claimed','awaiting_payment','expired') then
    v_amt := coalesce(p_amount, r.advance_paise);
    if v_amt <= 0 or v_amt > r.total_paise then raise exception 'Amount received must be between ₹1 and the booking total.'; end if;
    v_left := v_amt;
    for b in select k.id, k.total_paise - k.paid_paise as due from public.bookings k where k.id = any (r.booking_ids) order by k.code loop
      exit when v_left <= 0;
      i := i + 1;
      v_part := case when i = r.units then v_left else least(v_left, greatest(b.due, 0)) end;
      continue when v_part <= 0;
      v_ref := case when r.utr is null then null when i = 1 then r.utr else left(r.utr, 60) || '-' || i end;
      begin
        insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, note)
        values (r.property_id, b.id, 'payment', 'upi', v_part, v_ref, 'Advance via booking page ' || r.code);
      exception when unique_violation then
        raise exception 'UPI reference % is already recorded on another payment — check it in Payments.', r.utr;
      end;
      v_left := v_left - v_part;
    end loop;
  end if;

  update public.booking_requests set status = 'confirmed', decided_at = now(), decided_by = auth.uid(),
         owner_note = nullif(left(btrim(coalesce(p_note, '')), 500), ''),
         advance_paise = case when p_action = 'confirm' and r.status <> 'awaiting_confirmation' then coalesce(p_amount, r.advance_paise) else r.advance_paise end
   where id = r.id returning * into r;
  return jsonb_build_object('status', r.status, 'refund_paise', 0);
end $$;

-- Owner + manager: the number for the menu badge (requests that need a tap)
create or replace function public.bp_counts(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if not exists (select 1 from public.booking_pages where property_id = p_property) then return 0; end if;
  perform public._bp_expire(p_property);
  return (select count(*) from public.booking_requests where property_id = p_property and status in ('payment_claimed','awaiting_confirmation'));
end $$;

-- Owner + manager: reviews, and recent guests to ask
create or replace function public.bp_reviews(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return jsonb_build_object(
    'average', (select round(avg(rating)::numeric, 1) from public.stay_reviews where property_id = p_property and not hidden),
    'count', (select count(*) from public.stay_reviews where property_id = p_property and not hidden),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.guest_name, 'rating', r.rating, 'body', r.body, 'stayed_on', r.stayed_on,
               'hidden', r.hidden, 'reply', r.reply, 'created_at', r.created_at, 'booking_code', b.code) order by r.created_at desc)
             from public.stay_reviews r join public.bookings b on b.id = r.booking_id where r.property_id = p_property), '[]'::jsonb),
    'ask', coalesce((select jsonb_agg(x.j order by x.out_at desc) from (
             select jsonb_build_object('booking_id', b.id, 'code', b.code, 'guest_name', g.full_name, 'phone', g.phone,
                      'check_out', public._local_date(p_property, b.check_out_at), 'token', b.self_checkin_token) j, b.check_out_at out_at
               from public.bookings b join public.guests g on g.id = b.guest_id
              where b.property_id = p_property and b.status = 'checked_out' and g.phone is not null
                and coalesce(b.departed_at, b.check_out_at) > now() - interval '30 days'
                and not exists (select 1 from public.stay_reviews r where r.booking_id = b.id)
              order by b.check_out_at desc limit 30) x), '[]'::jsonb));
end $$;

create or replace function public.bp_review_moderate(p_id uuid, p_hidden boolean, p_reply text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.stay_reviews where id = p_id;
  if v_prop is null then raise exception 'Review not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  update public.stay_reviews set hidden = coalesce(p_hidden, hidden), reply = nullif(left(btrim(coalesce(p_reply, '')), 600), ''),
         replied_at = case when nullif(btrim(coalesce(p_reply, '')), '') is distinct from reply then now() else replied_at end, updated_at = now()
   where id = p_id;
end $$;

-- ---------------------------------------------------------------- who may call what
do $$ declare f text; begin
  foreach f in array array['bp_public(text)','bp_availability(text,date,date)','bp_request(text,jsonb)','bp_request_status(uuid)',
      'bp_claim_paid(uuid,text)','bp_cancel_request(uuid)','bp_review_get(uuid)','bp_review_submit(uuid,integer,text,text)'] loop
    execute 'revoke execute on function public.' || f || ' from public';
    execute 'grant execute on function public.' || f || ' to anon, authenticated';
  end loop;
  foreach f in array array['bp_counts(uuid)','bp_settings_get(uuid)','bp_slug_free(uuid,text)','bp_settings_save(uuid,jsonb)','bp_requests(uuid,text)',
      'bp_request_decide(uuid,text,integer,text)','bp_reviews(uuid)','bp_review_moderate(uuid,boolean,text)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
  foreach f in array array['_bp_today(uuid)','_bp_open(uuid)','_bp_client_key()','_bp_range(public.properties,date,date)','_bp_rooms(uuid)',
      '_bp_free(public.properties,jsonb,tstzrange)','_bp_min_stay(uuid,uuid,date)','_bp_expire(uuid)','bp_expire_all()','_bp_page_by_slug(text)',
      '_bp_licences(uuid)','_bp_request_json(public.booking_requests)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

-- Check: should say true
select to_regclass('public.booking_pages') is not null and to_regclass('public.booking_requests') is not null
   and to_regclass('public.stay_reviews') is not null
   and exists (select 1 from storage.buckets where id = 'stay-photos' and public) as booking_page_installed;


-- =====================================================================
-- NammaStay · 039_my_business.sql — My business: loans, partners, lease (owner only)
--
-- Adds three cards to My investment (now called "My business"). Each card only shows if the
-- owner answers "yes" to its question:
--   • Loans & EMIs   EMI, interest paid so far, amount still owed, payoff date, reminder before each EMI.
--                    Payback is shown AFTER loan interest ("real payback"), unless the owner says the
--                    EMIs are already entered as expenses (then nothing is counted twice).
--   • Partners       who put in what, profit share %, each partner's share of profit so far, payouts,
--                    balance due, statement to share.
--   • Lease          start / end, rent increase every N months, deposit, lock-in, notice period;
--                    compares break-even with the lease end ("break even before you have to leave?");
--                    reminders 180 / 90 / 30 days before the lease ends, before a rent increase and
--                    before the notice deadline.
--
-- Needs 036_investment.sql (My investment). OWNER ONLY, like 036.
-- ADD-ON ONLY — new tables and functions, plus one nullable column investments.partner_id (036's own
-- table, "who paid for this"). Nothing in the live app's own tables changes.
-- Safe to run more than once. Rollback: rollback_039_my_business.sql
-- =====================================================================

do $$ begin
  if to_regprocedure('public.invest_summary(uuid)') is null then
    raise exception 'Run 036_investment.sql (My investment) first.';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.business_profile (
  property_id     uuid primary key references public.properties(id) on delete cascade,
  has_loan        boolean,                     -- null = not answered yet
  has_partners    boolean,
  is_rented       boolean,
  emi_in_expenses boolean not null default false,   -- EMIs already entered in Expenses → don't subtract interest again
  updated_at      timestamptz not null default now()
);

create table if not exists public.business_loans (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  lender        text not null check (char_length(btrim(lender)) between 2 and 80),
  principal_paise bigint not null check (principal_paise between 100 and 100000000000),
  rate_pct      numeric(5,2) not null check (rate_pct between 0 and 60),
  tenure_months int not null check (tenure_months between 1 and 360),
  emi_paise     bigint check (emi_paise is null or emi_paise > 0),   -- null = worked out from amount, rate, months
  first_emi_on  date not null,
  closed_on     date,                                                  -- closed early / prepaid
  note          text check (char_length(note) <= 200),
  created_at    timestamptz not null default now()
);
create index if not exists business_loans_property on public.business_loans (property_id);

create table if not exists public.business_partners (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 2 and 60),
  phone       text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  share_pct   numeric(5,2) not null check (share_pct > 0 and share_pct <= 100),
  is_me       boolean not null default false,                         -- the owner's own row
  note        text check (char_length(note) <= 200),
  created_at  timestamptz not null default now()
);
create index if not exists business_partners_property on public.business_partners (property_id);
create unique index if not exists business_partners_one_me on public.business_partners (property_id) where is_me;

create table if not exists public.partner_payouts (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  partner_id   uuid not null references public.business_partners(id) on delete cascade,
  amount_paise bigint not null check (amount_paise between 100 and 100000000000),
  paid_on      date not null,
  note         text check (char_length(note) <= 200),
  created_at   timestamptz not null default now()
);
create index if not exists partner_payouts_partner on public.partner_payouts (partner_id, paid_on);

create table if not exists public.business_lease (
  property_id      uuid primary key references public.properties(id) on delete cascade,
  landlord         text check (char_length(landlord) <= 80),
  start_on         date not null,
  end_on           date not null,
  rent_paise       bigint not null check (rent_paise between 0 and 100000000000),   -- monthly rent at the start
  increase_pct     numeric(5,2) not null default 0 check (increase_pct between 0 and 50),
  increase_every_months int not null default 12 check (increase_every_months between 1 and 120),
  deposit_paise    bigint not null default 0 check (deposit_paise >= 0),
  lock_in_months   int not null default 0 check (lock_in_months between 0 and 240),
  notice_months    int not null default 0 check (notice_months between 0 and 24),
  note             text check (char_length(note) <= 200),
  updated_at       timestamptz not null default now(),
  check (end_on > start_on)
);

create table if not exists public.business_reminders (      -- which reminders were already sent (no repeats)
  property_id uuid not null references public.properties(id) on delete cascade,
  key         text not null,
  sent_at     timestamptz not null default now(),
  primary key (property_id, key)
);

alter table public.investments add column if not exists partner_id uuid references public.business_partners(id) on delete set null;

do $$ declare t text; begin
  foreach t in array array['business_profile','business_loans','business_partners','partner_payouts','business_lease','business_reminders'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);    -- owner reads/writes only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- loan maths (equal monthly instalments)
create or replace function public._biz_months(p_from date, p_to date) returns int
language sql immutable as $$
  select (extract(year from age(p_to, p_from)) * 12 + extract(month from age(p_to, p_from)))::int
$$;

create or replace function public._biz_loan(l public.business_loans, p_today date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  r numeric := l.rate_pct / 1200.0; n int := l.tenure_months; p numeric := l.principal_paise;
  emi numeric; k int; bal numeric; f numeric; paid_int numeric; tot_int numeric; asof date;
begin
  emi := coalesce(l.emi_paise::numeric, case when r = 0 then p / n else p * r * power(1 + r, n) / (power(1 + r, n) - 1) end);
  asof := least(p_today, coalesce(l.closed_on, p_today));
  k := (select count(*) from generate_series(0, n - 1) i where (l.first_emi_on + make_interval(months => i))::date <= asof);
  f := power(1 + r, k);
  bal := case when r = 0 then greatest(p - emi * k, 0) else greatest(p * f - emi * (f - 1) / r, 0) end;
  paid_int := greatest(emi * k - (p - bal), 0);
  tot_int := greatest(emi * n - p, 0);
  return jsonb_build_object(
    'id', l.id, 'lender', l.lender, 'principal_paise', l.principal_paise, 'rate_pct', l.rate_pct, 'tenure_months', n,
    'emi_paise', round(emi)::bigint, 'emi_entered', l.emi_paise is not null, 'first_emi_on', l.first_emi_on, 'closed_on', l.closed_on, 'note', l.note,
    'emis_paid', k, 'emis_left', case when l.closed_on is not null then 0 else n - k end,
    'outstanding_paise', case when l.closed_on is not null then 0 else round(bal)::bigint end,
    'interest_paid_paise', round(paid_int)::bigint,
    'interest_total_paise', case when l.closed_on is not null then round(paid_int)::bigint else round(tot_int)::bigint end,
    'interest_left_paise', case when l.closed_on is not null then 0 else round(greatest(tot_int - paid_int, 0))::bigint end,
    'interest_this_month_paise', case when l.closed_on is not null or k >= n then 0 else round(bal * r)::bigint end,
    'next_emi_on', case when l.closed_on is not null or k >= n then null else (l.first_emi_on + make_interval(months => k))::date end,
    'last_emi_on', (l.first_emi_on + make_interval(months => n - 1))::date,
    'done', l.closed_on is not null or k >= n);
end $$;

-- ---------------------------------------------------------------- lease maths
create or replace function public._biz_lease(b public.business_lease, p_today date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare v_steps int; v_rent numeric; v_next date; v_lock date; v_notice date; v_left int; v_to_end numeric := 0; d date; s int;
begin
  v_steps := case when p_today < b.start_on then 0 else floor(public._biz_months(b.start_on, p_today) / b.increase_every_months::numeric)::int end;
  v_rent := b.rent_paise * power(1 + b.increase_pct / 100.0, v_steps);
  v_next := (b.start_on + make_interval(months => (v_steps + 1) * b.increase_every_months))::date;
  if v_next >= b.end_on or b.increase_pct = 0 then v_next := null; end if;
  v_lock := case when b.lock_in_months > 0 then (b.start_on + make_interval(months => b.lock_in_months))::date end;
  v_notice := case when b.notice_months > 0 then (b.end_on - make_interval(months => b.notice_months))::date end;
  v_left := greatest(public._biz_months(p_today, b.end_on), 0);
  d := date_trunc('month', greatest(p_today, b.start_on))::date;
  while d < b.end_on and d < p_today + 3660 loop                       -- rent still to pay until the lease ends
    s := floor(public._biz_months(b.start_on, d) / b.increase_every_months::numeric)::int;
    v_to_end := v_to_end + b.rent_paise * power(1 + b.increase_pct / 100.0, greatest(s, 0));
    d := (d + interval '1 month')::date;
  end loop;
  return jsonb_build_object('landlord', b.landlord, 'start_on', b.start_on, 'end_on', b.end_on, 'rent_start_paise', b.rent_paise,
    'increase_pct', b.increase_pct, 'increase_every_months', b.increase_every_months, 'deposit_paise', b.deposit_paise,
    'lock_in_months', b.lock_in_months, 'notice_months', b.notice_months, 'note', b.note,
    'rent_now_paise', round(v_rent)::bigint, 'next_increase_on', v_next,
    'next_rent_paise', case when v_next is null then null else round(v_rent * (1 + b.increase_pct / 100.0))::bigint end,
    'lock_in_until', v_lock, 'notice_by', v_notice, 'months_left', v_left, 'days_left', b.end_on - p_today,
    'rent_to_end_paise', round(v_to_end)::bigint, 'ended', b.end_on <= p_today);
end $$;

-- ---------------------------------------------------------------- reminders in the bell (once each)
create or replace function public._biz_remind(p_property uuid, p_key text, p_title text, p_body text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.business_reminders (property_id, key) values (p_property, p_key) on conflict do nothing;
  if not found then return 0; end if;
  insert into public.notifications (property_id, user_id, kind, title, body)
  select p_property, m.user_id, 'my_business', p_title, p_body from public.property_members m where m.property_id = p_property and m.role = 'owner';
  return 1;
end $$;

create or replace function public._biz_notify(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date := public._inv_today(p_property); l public.business_loans; j jsonb; b public.business_lease; x jsonb; n int := 0; lvl int; v_left int;
begin
  for l in select * from public.business_loans where property_id = p_property and closed_on is null loop
    j := public._biz_loan(l, v_today);
    if (j->>'next_emi_on') is not null and (j->>'next_emi_on')::date - v_today between 0 and 3 then
      n := n + public._biz_remind(p_property, 'emi:' || l.id || ':' || (j->>'next_emi_on'),
        'EMI ' || to_char((j->>'emi_paise')::bigint / 100.0, 'FM₹99,99,99,990') || ' due ' || to_char((j->>'next_emi_on')::date, 'DD Mon'),
        l.lender || ' loan — keep the money in the account to avoid a bounce charge.');
    end if;
  end loop;
  select * into b from public.business_lease where property_id = p_property;
  if b.property_id is not null and coalesce((select is_rented from public.business_profile where property_id = p_property), true) then
    x := public._biz_lease(b, v_today);
    v_left := b.end_on - v_today;
    lvl := case when v_left < 0 then null when v_left <= 30 then 30 when v_left <= 90 then 90 when v_left <= 180 then 180 end;
    if lvl is not null then
      n := n + public._biz_remind(p_property, 'lease_end:' || b.end_on || ':' || lvl,
        'Lease ends in ' || v_left || ' days (' || to_char(b.end_on, 'DD Mon YYYY') || ')',
        'Talk to your landlord about renewing — see My business → Loans, partners & lease.');
    end if;
    if (x->>'notice_by') is not null and (x->>'notice_by')::date - v_today between 0 and 30 then
      n := n + public._biz_remind(p_property, 'notice:' || (x->>'notice_by'),
        'Lease notice deadline ' || to_char((x->>'notice_by')::date, 'DD Mon YYYY'),
        'Your lease needs ' || b.notice_months || ' month(s) notice before it ends. Decide to renew or leave before this date.');
    end if;
    if (x->>'next_increase_on') is not null and (x->>'next_increase_on')::date - v_today between 0 and 30 then
      n := n + public._biz_remind(p_property, 'rent_up:' || (x->>'next_increase_on'),
        'Rent goes up on ' || to_char((x->>'next_increase_on')::date, 'DD Mon'),
        'New rent about ' || to_char((x->>'next_rent_paise')::bigint / 100.0, 'FM₹99,99,99,990') || ' a month (+' || b.increase_pct || '%).');
    end if;
  end if;
  return n;
end $$;

create or replace function public.biz_remind_all() returns int        -- optional daily job (pg_cron)
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; n int := 0;
begin
  for pid in select property_id from public.business_loans where closed_on is null union select property_id from public.business_lease loop
    n := n + public._biz_notify(pid);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- the whole picture (owner)
create or replace function public.biz_summary(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_today date; s jsonb; pr public.business_profile; l public.business_loans; v_loans jsonb := '[]'::jsonb; j jsonb;
  v_int_paid bigint := 0; v_int_month bigint := 0; v_owed bigint := 0; v_emi bigint := 0;
  v_inv bigint; v_rec bigint; v_real bigint; v_avg bigint; v_ravg bigint; v_left bigint; v_mleft int; v_be text;
  b public.business_lease; v_lease jsonb; v_verdict text; v_parts jsonb; v_share numeric; v_alerts jsonb := '[]'::jsonb;
begin
  perform public._inv_owner(p_property);
  v_today := public._inv_today(p_property);
  perform public._biz_notify(p_property);
  s := public.invest_summary(p_property);
  select * into pr from public.business_profile where property_id = p_property;

  for l in select * from public.business_loans where property_id = p_property order by first_emi_on, created_at loop
    j := public._biz_loan(l, v_today);
    v_loans := v_loans || j;
    v_int_paid := v_int_paid + (j->>'interest_paid_paise')::bigint;
    v_int_month := v_int_month + (j->>'interest_this_month_paise')::bigint;
    v_owed := v_owed + (j->>'outstanding_paise')::bigint;
    if not (j->>'done')::boolean then v_emi := v_emi + (j->>'emi_paise')::bigint; end if;
    if (j->>'next_emi_on') is not null and (j->>'next_emi_on')::date - v_today between 0 and 7 then
      v_alerts := v_alerts || jsonb_build_object('kind', 'emi', 'level', 'amber', 'text',
        format('EMI of %s to %s due %s', to_char((j->>'emi_paise')::bigint / 100.0, 'FM₹99,99,99,990'), l.lender, to_char((j->>'next_emi_on')::date, 'DD Mon')));
    end if;
  end loop;
  if coalesce(pr.emi_in_expenses, false) then v_int_paid := 0; v_int_month := 0; end if;

  -- payback after loan interest
  v_inv := (s->>'invested_paise')::bigint; v_rec := (s->>'recovered_paise')::bigint; v_avg := nullif(s->>'avg3_paise', '')::bigint;
  v_real := v_rec - v_int_paid;
  v_ravg := case when v_avg is null then null else v_avg - v_int_month end;
  v_left := greatest(v_inv - v_real, 0);
  v_mleft := case when v_inv > 0 and v_left > 0 and v_ravg > 0 then ceil(v_left::numeric / v_ravg)::int end;
  v_be := case when v_inv > 0 and v_left = 0 then 'done'
               when v_mleft is not null then to_char(date_trunc('month', v_today) + make_interval(months => v_mleft), 'YYYY-MM') end;

  -- lease
  select * into b from public.business_lease where property_id = p_property;
  if b.property_id is not null then
    v_lease := public._biz_lease(b, v_today);
    v_verdict := case when v_be = 'done' then 'done' when v_be is null then 'unknown'
                      when to_date(v_be, 'YYYY-MM') <= (b.end_on - interval '6 months') then 'ok'
                      when to_date(v_be, 'YYYY-MM') <= b.end_on then 'tight' else 'risk' end;
    v_lease := v_lease || jsonb_build_object('verdict', v_verdict);
    if coalesce(pr.is_rented, true) then
      if b.end_on - v_today between 0 and 180 then
        v_alerts := v_alerts || jsonb_build_object('kind', 'lease', 'level', case when b.end_on - v_today <= 60 then 'red' else 'amber' end,
          'text', format('Lease ends in %s days (%s). Talk to your landlord about renewing.', b.end_on - v_today, to_char(b.end_on, 'DD Mon YYYY')));
      end if;
      if v_verdict = 'risk' then
        v_alerts := v_alerts || jsonb_build_object('kind', 'lease_payback', 'level', 'red',
          'text', format('At this pace you break even around %s — after your lease ends (%s). Ask for a longer lease now.', to_char(to_date(v_be, 'YYYY-MM'), 'Mon YYYY'), to_char(b.end_on, 'Mon YYYY')));
      end if;
      if (v_lease->>'notice_by') is not null and (v_lease->>'notice_by')::date - v_today between 0 and 60 then
        v_alerts := v_alerts || jsonb_build_object('kind', 'notice', 'level', 'amber', 'text',
          format('Lease notice deadline %s — decide to renew or leave before then.', to_char((v_lease->>'notice_by')::date, 'DD Mon YYYY')));
      end if;
      if (v_lease->>'next_increase_on') is not null and (v_lease->>'next_increase_on')::date - v_today between 0 and 60 then
        v_alerts := v_alerts || jsonb_build_object('kind', 'rent_up', 'level', 'amber', 'text',
          format('Rent goes up on %s to about %s a month.', to_char((v_lease->>'next_increase_on')::date, 'DD Mon'), to_char((v_lease->>'next_rent_paise')::bigint / 100.0, 'FM₹99,99,99,990')));
      end if;
    end if;
  end if;

  -- partners
  select coalesce(sum(share_pct), 0) into v_share from public.business_partners where property_id = p_property;
  select coalesce(jsonb_agg(x.j order by x.is_me desc, x.created_at), '[]'::jsonb) into v_parts from (
    select bp.is_me, bp.created_at, jsonb_build_object('id', bp.id, 'name', bp.name, 'phone', bp.phone, 'share_pct', bp.share_pct, 'is_me', bp.is_me, 'note', bp.note,
      'invested_paise', coalesce((select sum(i.amount_paise) from public.investments i where i.property_id = p_property
                                    and (i.partner_id = bp.id or (bp.is_me and i.partner_id is null))), 0),
      'profit_share_paise', round(greatest(v_real, 0) * bp.share_pct / 100.0)::bigint,
      'paid_out_paise', coalesce((select sum(po.amount_paise) from public.partner_payouts po where po.partner_id = bp.id), 0),
      'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', po.id, 'amount_paise', po.amount_paise, 'paid_on', po.paid_on, 'note', po.note) order by po.paid_on desc)
                            from (select * from public.partner_payouts where partner_id = bp.id order by paid_on desc limit 24) po), '[]'::jsonb)) j
      from public.business_partners bp where bp.property_id = p_property) x;
  if jsonb_array_length(v_parts) > 0 and v_share <> 100 then
    v_alerts := v_alerts || jsonb_build_object('kind', 'shares', 'level', 'amber', 'text', format('Partner shares add up to %s%% — they should make 100%%.', v_share));
  end if;

  return jsonb_build_object(
    'today', v_today,
    'profile', jsonb_build_object('has_loan', pr.has_loan, 'has_partners', pr.has_partners, 'is_rented', pr.is_rented, 'emi_in_expenses', coalesce(pr.emi_in_expenses, false)),
    'payback', jsonb_build_object('invested_paise', v_inv, 'profit_paise', v_rec, 'interest_paid_paise', v_int_paid, 'real_recovered_paise', v_real,
       'real_pct', case when v_inv > 0 then round(greatest(v_real, 0) * 100.0 / v_inv, 1) end, 'real_left_paise', v_left,
       'avg3_paise', v_avg, 'interest_this_month_paise', v_int_month, 'real_avg3_paise', v_ravg, 'real_months_left', v_mleft, 'real_breakeven', v_be,
       'plain_breakeven', s->>'breakeven_month'),
    'loans', jsonb_build_object('items', v_loans, 'owed_paise', v_owed, 'emi_month_paise', v_emi, 'interest_paid_paise', v_int_paid),
    'partners', jsonb_build_object('items', v_parts, 'total_share', v_share,
       'unassigned_paise', case when exists (select 1 from public.business_partners where property_id = p_property and is_me) then 0
                                else coalesce((select sum(amount_paise) from public.investments where property_id = p_property and partner_id is null), 0) end,
       'paid_by', coalesce((select jsonb_object_agg(id, partner_id) from public.investments where property_id = p_property and partner_id is not null), '{}'::jsonb)),
    'lease', v_lease,
    'alerts', v_alerts);
end $$;

-- ---------------------------------------------------------------- saving (owner)
-- p: { has_loan?, has_partners?, is_rented?, emi_in_expenses? }  (only the keys sent are changed)
create or replace function public.biz_profile_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._inv_owner(p_property);
  insert into public.business_profile (property_id) values (p_property) on conflict do nothing;
  update public.business_profile set
    has_loan        = case when p ? 'has_loan' then (p->>'has_loan')::boolean else has_loan end,
    has_partners    = case when p ? 'has_partners' then (p->>'has_partners')::boolean else has_partners end,
    is_rented       = case when p ? 'is_rented' then (p->>'is_rented')::boolean else is_rented end,
    emi_in_expenses = case when p ? 'emi_in_expenses' then coalesce((p->>'emi_in_expenses')::boolean, false) else emi_in_expenses end,
    updated_at = now()
  where property_id = p_property;
  return public.biz_summary(p_property);
end $$;

-- p: { id?, lender, principal_paise, rate_pct, tenure_months, emi_paise?, first_emi_on, closed_on?, note? }
create or replace function public.biz_loan_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_first date; v_closed date;
begin
  perform public._inv_owner(p_property);
  if char_length(btrim(coalesce(p->>'lender', ''))) < 2 then raise exception 'Who gave the loan? (e.g. SBI, HDFC, family)'; end if;
  if coalesce((p->>'principal_paise')::bigint, 0) < 100 then raise exception 'Enter the loan amount.'; end if;
  if (p->>'rate_pct') is null or (p->>'rate_pct')::numeric not between 0 and 60 then raise exception 'Interest rate should be between 0 and 60%% a year.'; end if;
  if coalesce((p->>'tenure_months')::int, 0) not between 1 and 360 then raise exception 'Loan period: 1 to 360 months.'; end if;
  begin v_first := (p->>'first_emi_on')::date; v_closed := nullif(p->>'closed_on', '')::date;
  exception when others then raise exception 'Check the dates.'; end;
  if v_first is null then raise exception 'When was (or is) the first EMI?'; end if;
  if v_closed is not null and v_closed < v_first - 31 then raise exception 'The closing date is before the loan started.'; end if;
  if v_id is null then
    insert into public.business_loans (property_id, lender, principal_paise, rate_pct, tenure_months, emi_paise, first_emi_on, closed_on, note)
    values (p_property, btrim(p->>'lender'), (p->>'principal_paise')::bigint, (p->>'rate_pct')::numeric, (p->>'tenure_months')::int,
            nullif(p->>'emi_paise', '')::bigint, v_first, v_closed, nullif(btrim(p->>'note'), ''));
  else
    update public.business_loans set lender = btrim(p->>'lender'), principal_paise = (p->>'principal_paise')::bigint, rate_pct = (p->>'rate_pct')::numeric,
           tenure_months = (p->>'tenure_months')::int, emi_paise = nullif(p->>'emi_paise', '')::bigint, first_emi_on = v_first, closed_on = v_closed,
           note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Loan not found.'; end if;
  end if;
  insert into public.business_profile (property_id, has_loan) values (p_property, true)
  on conflict (property_id) do update set has_loan = true, updated_at = now();
  return public.biz_summary(p_property);
end $$;

create or replace function public.biz_loan_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.business_loans where id = p_id;
  if v_prop is null then raise exception 'Loan not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.business_loans where id = p_id;
  return public.biz_summary(v_prop);
end $$;

-- p: { id?, name, phone?, share_pct, is_me?, note? }
create or replace function public.biz_partner_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_phone text; v_share numeric; v_other numeric;
begin
  perform public._inv_owner(p_property);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the partner''s name.'; end if;
  v_share := nullif(p->>'share_pct', '')::numeric;
  if v_share is null or v_share <= 0 or v_share > 100 then raise exception 'Profit share should be between 1 and 100%%.'; end if;
  if coalesce((p->>'is_me')::boolean, false) and exists (select 1 from public.business_partners where property_id = p_property and is_me and id is distinct from v_id) then
    raise exception 'You are already in the list.';
  end if;
  select coalesce(sum(share_pct), 0) into v_other from public.business_partners where property_id = p_property and id is distinct from v_id;
  if v_other + v_share > 100 then raise exception 'Shares would add up to %, more than 100%%. Lower someone''s share first.', (v_other + v_share)::text || '%'; end if;
  v_phone := public._clean_phone(p->>'phone');
  if v_phone ~ '^[6-9][0-9]{9}$' then v_phone := '+91' || v_phone; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the phone number.'; end if;
  if v_id is null then
    insert into public.business_partners (property_id, name, phone, share_pct, is_me, note)
    values (p_property, btrim(p->>'name'), v_phone, v_share, coalesce((p->>'is_me')::boolean, false), nullif(btrim(p->>'note'), ''));
  else
    update public.business_partners set name = btrim(p->>'name'), phone = v_phone, share_pct = v_share, note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Partner not found.'; end if;
  end if;
  insert into public.business_profile (property_id, has_partners) values (p_property, true)
  on conflict (property_id) do update set has_partners = true, updated_at = now();
  return public.biz_summary(p_property);
end $$;

create or replace function public.biz_partner_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.business_partners where id = p_id;
  if v_prop is null then raise exception 'Partner not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.business_partners where id = p_id;          -- payouts go with them; their investments become "unassigned"
  return public.biz_summary(v_prop);
end $$;

-- Who paid for an investment item (null = not set / the owner)
create or replace function public.biz_investment_partner(p_investment uuid, p_partner uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.investments where id = p_investment;
  if v_prop is null then raise exception 'Investment not found.'; end if;
  perform public._inv_owner(v_prop);
  if p_partner is not null and not exists (select 1 from public.business_partners where id = p_partner and property_id = v_prop) then
    raise exception 'Partner not found.';
  end if;
  update public.investments set partner_id = p_partner where id = p_investment;
  return public.biz_summary(v_prop);
end $$;

-- p: { id?, partner_id, amount_paise, paid_on, note? }
create or replace function public.biz_payout_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_on date;
begin
  perform public._inv_owner(p_property);
  if not exists (select 1 from public.business_partners where id = (p->>'partner_id')::uuid and property_id = p_property) then raise exception 'Choose the partner.'; end if;
  if coalesce((p->>'amount_paise')::bigint, 0) < 100 then raise exception 'Enter the amount paid.'; end if;
  v_on := coalesce(nullif(p->>'paid_on', '')::date, public._inv_today(p_property));
  if v_on > public._inv_today(p_property) then raise exception 'The date can''t be in the future.'; end if;
  if v_id is null then
    insert into public.partner_payouts (property_id, partner_id, amount_paise, paid_on, note)
    values (p_property, (p->>'partner_id')::uuid, (p->>'amount_paise')::bigint, v_on, nullif(btrim(p->>'note'), ''));
  else
    update public.partner_payouts set amount_paise = (p->>'amount_paise')::bigint, paid_on = v_on, note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Payout not found.'; end if;
  end if;
  return public.biz_summary(p_property);
end $$;

create or replace function public.biz_payout_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.partner_payouts where id = p_id;
  if v_prop is null then raise exception 'Payout not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.partner_payouts where id = p_id;
  return public.biz_summary(v_prop);
end $$;

-- p: { landlord?, start_on, end_on, rent_paise, increase_pct?, increase_every_months?, deposit_paise?, lock_in_months?, notice_months?, note? }
create or replace function public.biz_lease_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_start date; v_end date;
begin
  perform public._inv_owner(p_property);
  begin v_start := (p->>'start_on')::date; v_end := (p->>'end_on')::date;
  exception when others then raise exception 'Check the lease dates.'; end;
  if v_start is null or v_end is null then raise exception 'Enter when the lease started and when it ends.'; end if;
  if v_end <= v_start then raise exception 'The lease end must be after the start.'; end if;
  if coalesce((p->>'rent_paise')::bigint, -1) < 0 then raise exception 'Enter the monthly rent at the start of the lease.'; end if;
  insert into public.business_lease as bl (property_id, landlord, start_on, end_on, rent_paise, increase_pct, increase_every_months, deposit_paise, lock_in_months, notice_months, note)
  values (p_property, nullif(btrim(p->>'landlord'), ''), v_start, v_end, (p->>'rent_paise')::bigint, coalesce(nullif(p->>'increase_pct', '')::numeric, 0),
          coalesce(nullif(p->>'increase_every_months', '')::int, 12), coalesce(nullif(p->>'deposit_paise', '')::bigint, 0),
          coalesce(nullif(p->>'lock_in_months', '')::int, 0), coalesce(nullif(p->>'notice_months', '')::int, 0), nullif(btrim(p->>'note'), ''))
  on conflict (property_id) do update set landlord = excluded.landlord, start_on = excluded.start_on, end_on = excluded.end_on, rent_paise = excluded.rent_paise,
     increase_pct = excluded.increase_pct, increase_every_months = excluded.increase_every_months, deposit_paise = excluded.deposit_paise,
     lock_in_months = excluded.lock_in_months, notice_months = excluded.notice_months, note = excluded.note, updated_at = now();
  insert into public.business_profile (property_id, is_rented) values (p_property, true)
  on conflict (property_id) do update set is_rented = true, updated_at = now();
  return public.biz_summary(p_property);
end $$;

-- ---------------------------------------------------------------- who may call what
do $$ declare f text; begin
  foreach f in array array['biz_summary(uuid)','biz_profile_save(uuid,jsonb)','biz_loan_save(uuid,jsonb)','biz_loan_delete(uuid)',
      'biz_partner_save(uuid,jsonb)','biz_partner_delete(uuid)','biz_investment_partner(uuid,uuid)','biz_payout_save(uuid,jsonb)',
      'biz_payout_delete(uuid)','biz_lease_save(uuid,jsonb)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
  foreach f in array array['_biz_months(date,date)','_biz_loan(public.business_loans,date)','_biz_lease(public.business_lease,date)',
      '_biz_remind(uuid,text,text,text)','_biz_notify(uuid)','biz_remind_all()'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

-- Check: should say true
select to_regclass('public.business_loans') is not null and to_regclass('public.business_partners') is not null
   and to_regclass('public.business_lease') is not null as my_business_installed;


-- =====================================================================
-- NammaStay · 040_company.sql — Company: NammaStay's own business numbers (platform admins only)
--
-- Adds one admin page, "Company", with two tabs:
--   • My company      money put in and how much has come back (payback), runway, monthly income vs
--                     costs, where the money goes, milestones (paying properties), founders,
--                     unit economics, renewals & company filings (GST, ROC, domain, trademark…).
--   • Company health  one score from 8 areas: growth, customers leaving, trial → paid, new
--                     properties getting started, inactive customers, payments to collect,
--                     runway and filings. Top things to do + weekly trend.
--
-- Subscription income, paying properties, trials and churn come from the existing billing tables
-- (subscriptions, subscription_payments, plans) — read only, through admin_revenue(). If the platform
-- has a GSTIN, income is counted after GST (the GST part is not company money).
-- Costs, money put in, founders, other income, cash in bank and renewals are entered by the admin.
--
-- PLATFORM ADMINS ONLY (is_platform_admin()). ADD-ON ONLY — new tables and functions; nothing in
-- the live app's tables or functions changes. Safe to run more than once.
-- Rollback: rollback_040_company.sql
-- =====================================================================

do $$ begin
  if to_regprocedure('public.admin_revenue()') is null or to_regprocedure('public._assert_platform_admin()') is null then
    raise exception 'The admin billing functions (admin_revenue) are missing — run the main setup first.';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.company_profile (
  id                 smallint primary key default 1 check (id = 1),     -- one row
  started_on         date,                                               -- payback is counted from this month
  cash_paise         bigint check (cash_paise is null or cash_paise between 0 and 100000000000000),
  cash_updated_on    date,
  runway_goal_months int not null default 6 check (runway_goal_months between 1 and 36),
  updated_at         timestamptz not null default now()
);

create table if not exists public.company_founders (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(btrim(name)) between 2 and 60),
  role       text check (char_length(role) <= 60),
  share_pct  numeric(5,2) not null check (share_pct >= 0 and share_pct <= 100),
  is_me      boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.company_investments (
  id          uuid primary key default gen_random_uuid(),
  made_on     date not null,
  amount_paise bigint not null check (amount_paise between 100 and 100000000000000),
  source      text not null default 'founder' check (source in ('founder', 'investor', 'loan', 'grant', 'other')),
  founder_id  uuid references public.company_founders(id) on delete set null,   -- "put in by"
  note        text check (char_length(note) <= 200),
  created_at  timestamptz not null default now()
);

create table if not exists public.company_costs (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(btrim(name)) between 2 and 80),
  category     text not null check (category in ('salaries', 'marketing', 'servers', 'tools', 'office', 'compliance', 'other')),
  every        text not null check (every in ('month', 'year', 'once')),   -- yearly costs are spread ÷ 12
  amount_paise bigint not null check (amount_paise between 100 and 100000000000),
  starts_on    date not null,                                             -- for 'once': the day it was paid
  ends_on      date,                                                      -- stopped (null = still running)
  note         text check (char_length(note) <= 200),
  created_at   timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);

create table if not exists public.company_income (                        -- income outside subscriptions
  id           uuid primary key default gen_random_uuid(),
  received_on  date not null,
  amount_paise bigint not null check (amount_paise between 100 and 100000000000),
  source       text not null check (char_length(btrim(source)) between 2 and 80),
  note         text check (char_length(note) <= 200),
  created_at   timestamptz not null default now()
);

create table if not exists public.company_renewals (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('gst', 'tds', 'roc', 'itr', 'domain', 'ssl', 'trademark', 'server', 'licence', 'other')),
  title        text not null check (char_length(btrim(title)) between 2 and 80),
  due_on       date,                                                      -- null = pending, no date yet (e.g. trademark)
  repeat       text not null default 'none' check (repeat in ('none', 'month', 'quarter', 'year')),
  amount_paise bigint check (amount_paise is null or amount_paise between 0 and 100000000000),
  done_on      date,                                                      -- set when a one-off item is finished
  note         text check (char_length(note) <= 200),
  created_at   timestamptz not null default now()
);

create table if not exists public.company_health_snapshots (
  week_start date primary key,
  score      int not null check (score between 0 and 100),
  areas      jsonb not null default '[]',
  created_at timestamptz not null default now()
);

alter table public.company_profile          enable row level security;
alter table public.company_founders         enable row level security;
alter table public.company_investments      enable row level security;
alter table public.company_costs            enable row level security;
alter table public.company_income           enable row level security;
alter table public.company_renewals         enable row level security;
alter table public.company_health_snapshots enable row level security;
-- No policies and no grants: only the functions below (platform admins) read or write these tables.
revoke all on public.company_profile, public.company_founders, public.company_investments, public.company_costs,
              public.company_income, public.company_renewals, public.company_health_snapshots from anon, authenticated;

-- ---------------------------------------------------------------- helpers (server only)
-- Today's month in India
create or replace function public._co_month0() returns date
language sql stable set search_path = public, pg_temp as $$
  select date_trunc('month', now() at time zone 'Asia/Kolkata')::date
$$;

-- Subscription money without the GST part (only when the platform is GST registered)
create or replace function public._co_net(p_paise numeric) returns bigint
language sql stable security definer set search_path = public, pg_temp as $$
  select round(coalesce(p_paise, 0) * 100.0 / (100 + coalesce((select case when gstin is not null then gst_rate else 0 end from public.platform_settings where id = 1), 0)))::bigint
$$;

-- Costs that belong to one month: monthly costs running that month, yearly costs ÷ 12, one-off costs paid that month
create or replace function public._co_month_costs(p_month date) returns bigint
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(case
           when c.every = 'once'  then case when date_trunc('month', c.starts_on)::date = p_month then c.amount_paise else 0 end
           when c.every = 'month' then c.amount_paise
           else round(c.amount_paise / 12.0) end), 0)::bigint
    from public.company_costs c
   where (c.every = 'once' and date_trunc('month', c.starts_on)::date = p_month)
      or (c.every <> 'once' and c.starts_on <= (p_month + interval '1 month - 1 day')::date
          and (c.ends_on is null or c.ends_on >= p_month))
$$;

-- Paying properties and MRR at a moment in the past, from the paid periods (complimentary excluded)
create or replace function public._co_paying_at(p_at timestamptz, out mrr_paise bigint, out paying int)
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(x.amount_paise::numeric / greatest(x.period_months, 1)), 0)::bigint, count(*)::int
    from (select distinct on (sp.property_id) sp.property_id, sp.amount_paise, pl.period_months
            from public.subscription_payments sp
            join public.plans pl on pl.id = sp.plan_id
            join public.subscriptions s on s.property_id = sp.property_id and not s.is_complimentary
           where sp.status = 'approved'
             and coalesce(sp.period_start, sp.reviewed_at) <= p_at
             and coalesce(sp.period_end, coalesce(sp.period_start, sp.reviewed_at) + make_interval(months => greatest(pl.period_months, 1))) > p_at
           order by sp.property_id, sp.reviewed_at desc) x
$$;

-- Next due date after a renewal is done
create or replace function public._co_next_due(p_due date, p_repeat text) returns date
language sql immutable as $$
  select case p_repeat when 'month' then (p_due + interval '1 month')::date
                       when 'quarter' then (p_due + interval '3 months')::date
                       when 'year' then (p_due + interval '1 year')::date end
$$;

create or replace function public._co_renewals() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'kind', r.kind, 'title', r.title, 'due_on', r.due_on, 'repeat', r.repeat, 'amount_paise', r.amount_paise,
           'done_on', r.done_on, 'note', r.note,
           'days_left', case when r.due_on is not null then r.due_on - (now() at time zone 'Asia/Kolkata')::date end,
           'state', case when r.done_on is not null then 'done'
                         when r.due_on is null then 'pending'
                         when r.due_on < (now() at time zone 'Asia/Kolkata')::date then 'overdue'
                         when r.due_on <= (now() at time zone 'Asia/Kolkata')::date + 7 then 'soon'
                         else 'ok' end)
         order by (r.done_on is not null), r.due_on nulls last, r.title), '[]'::jsonb)
    from public.company_renewals r
$$;

-- ---------------------------------------------------------------- My company
create or replace function public.company_summary() returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_rev jsonb; prof public.company_profile%rowtype;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_m0 date := public._co_month0(); v_start date;
  v_mrr bigint; v_mrr_net bigint; v_paying int; v_prev record;
  v_invested bigint; v_cum bigint := 0; v_pace bigint; v_costs_now bigint; v_other3 bigint; v_profit_now bigint;
  v_months jsonb; v_left bigint; v_be date; v_runway numeric; v_firsts date[]; v_ms jsonb;
  v_new30 int; v_new_m int; v_new90 int; v_mkt90 bigint; v_srv bigint; v_gst boolean;
begin
  perform public._assert_platform_admin();
  v_rev := public.admin_revenue();
  select * into prof from public.company_profile where id = 1;
  v_mrr := coalesce((v_rev->>'mrr_paise')::bigint, 0); v_mrr_net := public._co_net(v_mrr);
  v_paying := coalesce((v_rev->>'paying')::int, 0);
  select * into v_prev from public._co_paying_at(now() - interval '30 days');
  select coalesce(sum(amount_paise), 0) into v_invested from public.company_investments;
  v_gst := exists (select 1 from public.platform_settings where id = 1 and gstin is not null);

  -- first month counted for payback
  v_start := coalesce(date_trunc('month', prof.started_on)::date,
               least((select date_trunc('month', min(made_on))::date from public.company_investments),
                     (select date_trunc('month', min(starts_on))::date from public.company_costs),
                     (select date_trunc('month', min(reviewed_at at time zone 'Asia/Kolkata'))::date from public.subscription_payments where status = 'approved')),
               v_m0);
  v_start := greatest(least(v_start, v_m0), (v_m0 - interval '10 years')::date);

  -- month by month since the start (income after GST, other income, costs)
  with mm as (
    select g::date m,
           public._co_net((select coalesce(sum(sp.amount_paise), 0) from public.subscription_payments sp
                            where sp.status = 'approved' and date_trunc('month', sp.reviewed_at at time zone 'Asia/Kolkata')::date = g::date)) sub,
           (select coalesce(sum(i.amount_paise), 0) from public.company_income i where date_trunc('month', i.received_on)::date = g::date) oth,
           public._co_month_costs(g::date) cost
      from generate_series(v_start, v_m0, interval '1 month') g)
  select coalesce((select sum(sub + oth - cost) from mm), 0),
         (select round(avg(sub + oth - cost)) from (select * from mm where m < v_m0 order by m desc limit 3) z),
         coalesce((select sum(oth) from mm where m < v_m0 and m >= (v_m0 - interval '3 months')::date), 0),
         (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'income_paise', sub + oth, 'subscriptions_paise', sub,
                   'other_paise', oth, 'costs_paise', cost, 'profit_paise', sub + oth - cost) order by m), '[]'::jsonb)
            from (select * from mm order by m desc limit 12) z)
    into v_cum, v_pace, v_other3, v_months;

  -- run rate today: MRR (after GST) + average other income − monthly costs
  select coalesce(sum(case when every = 'month' then amount_paise else round(amount_paise / 12.0) end), 0)
    into v_costs_now from public.company_costs
   where every <> 'once' and starts_on <= v_today and (ends_on is null or ends_on >= v_today);
  v_profit_now := v_mrr_net + round(v_other3 / 3.0)::bigint - v_costs_now;
  v_pace := coalesce(v_pace, v_profit_now);

  v_left := greatest(v_invested - greatest(v_cum, 0), 0);
  if v_invested > 0 and v_left = 0 then v_be := v_today;
  elsif v_left > 0 and greatest(v_pace, v_profit_now) > 0 then
    v_be := (v_m0 + make_interval(months => ceil(v_left::numeric / greatest(v_pace, v_profit_now))::int))::date;
  end if;
  v_runway := case when v_profit_now >= 0 then null when prof.cash_paise is null then null
                   else round(prof.cash_paise::numeric / (-v_profit_now), 1) end;

  -- milestones: the day the Nth property first paid
  select array_agg(f order by f) into v_firsts from (
    select min(sp.reviewed_at at time zone 'Asia/Kolkata')::date f from public.subscription_payments sp
      join public.subscriptions s on s.property_id = sp.property_id and not s.is_complimentary
     where sp.status = 'approved' group by sp.property_id) z;
  select jsonb_agg(jsonb_build_object('target', t, 'reached_on', v_firsts[t], 'kind', 'properties') order by t) into v_ms
    from unnest(array[1, 10, 25, 50, 100, 250, 500, 1000]) t;
  v_new30 := (select count(*) from unnest(coalesce(v_firsts, '{}')) f where f > v_today - 30);
  v_new_m := (select count(*) from unnest(coalesce(v_firsts, '{}')) f where f >= v_m0);
  v_new90 := (select count(*) from unnest(coalesce(v_firsts, '{}')) f where f > v_today - 90);
  -- marketing spent in the last 90 days (for cost to win one customer)
  select coalesce(sum(case when c.every = 'once' then case when c.starts_on > v_today - 90 then c.amount_paise else 0 end
                           else (case when c.every = 'month' then c.amount_paise else c.amount_paise / 12.0 end)
                                * greatest(0, least(3.0, ((least(coalesce(c.ends_on, v_today), v_today) - greatest(c.starts_on, v_today - 90)) + 1) / 30.0)) end), 0)::bigint
    into v_mkt90 from public.company_costs c where c.category = 'marketing';
  select coalesce(sum(case when every = 'month' then amount_paise else round(amount_paise / 12.0) end), 0) into v_srv
    from public.company_costs where category = 'servers' and every <> 'once' and starts_on <= v_today and (ends_on is null or ends_on >= v_today);

  return jsonb_build_object(
    'profile', jsonb_build_object('started_on', prof.started_on, 'counted_from', v_start, 'cash_paise', prof.cash_paise,
                 'cash_updated_on', prof.cash_updated_on, 'runway_goal_months', coalesce(prof.runway_goal_months, 6)),
    'gst_registered', v_gst,
    'income', jsonb_build_object('mrr_paise', v_mrr, 'mrr_net_paise', v_mrr_net, 'mrr_prev_net_paise', public._co_net(v_prev.mrr_paise),
                 'other_avg_paise', round(v_other3 / 3.0)::bigint),
    'customers', jsonb_build_object('paying', v_paying, 'paying_prev', v_prev.paying, 'trials', coalesce((v_rev->>'trials')::int, 0),
                 'new_this_month', v_new_m, 'new_30d', v_new30, 'new_90d', v_new90, 'churned_30d', coalesce((v_rev->>'churned_30')::int, 0)),
    'run_rate', jsonb_build_object('income_paise', v_mrr_net + round(v_other3 / 3.0)::bigint, 'costs_paise', v_costs_now, 'profit_paise', v_profit_now),
    'payback', jsonb_build_object('invested_paise', v_invested, 'recovered_paise', least(greatest(v_cum, 0), v_invested),
                 'profit_so_far_paise', v_cum, 'left_paise', v_left, 'pace_paise', v_pace,
                 'pct', case when v_invested > 0 then least(100, floor(greatest(v_cum, 0) * 100.0 / v_invested)) else 0 end,
                 'break_even_on', v_be),
    'runway', jsonb_build_object('self_funding', v_profit_now >= 0, 'months', v_runway, 'burn_paise', greatest(-v_profit_now, 0),
                 'cash_paise', prof.cash_paise, 'goal_months', coalesce(prof.runway_goal_months, 6)),
    'months', v_months,
    'milestones', v_ms,
    'costs', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'category', c.category, 'every', c.every,
                 'amount_paise', c.amount_paise, 'starts_on', c.starts_on, 'ends_on', c.ends_on, 'note', c.note,
                 'running', c.every <> 'once' and c.starts_on <= v_today and (c.ends_on is null or c.ends_on >= v_today))
                 order by (c.every <> 'once' and (c.ends_on is null or c.ends_on >= v_today)) desc, c.category, c.amount_paise desc), '[]'::jsonb)
              from public.company_costs c where c.every <> 'once' or c.starts_on > v_today - 365),
    'cost_split', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'monthly_paise', amt) order by amt desc), '[]'::jsonb) from (
                 select category, sum(case when every = 'month' then amount_paise else round(amount_paise / 12.0) end)::bigint amt
                   from public.company_costs where every <> 'once' and starts_on <= v_today and (ends_on is null or ends_on >= v_today)
                  group by category) z),
    'income_list', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'received_on', i.received_on, 'amount_paise', i.amount_paise,
                 'source', i.source, 'note', i.note) order by i.received_on desc), '[]'::jsonb)
              from public.company_income i where i.received_on > v_today - 365),
    'investments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'made_on', x.made_on, 'amount_paise', x.amount_paise, 'source', x.source,
                 'founder_id', x.founder_id, 'founder', f.name, 'note', x.note) order by x.made_on desc), '[]'::jsonb)
              from public.company_investments x left join public.company_founders f on f.id = x.founder_id),
    'founders', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'role', f.role, 'share_pct', f.share_pct, 'is_me', f.is_me,
                 'invested_paise', (select coalesce(sum(amount_paise), 0) from public.company_investments x where x.founder_id = f.id))
                 order by f.is_me desc, f.share_pct desc, f.name), '[]'::jsonb) from public.company_founders f),
    'renewals', public._co_renewals(),
    'unit', jsonb_build_object(
                 'arpu_paise', case when v_paying > 0 then v_mrr_net / v_paying end,
                 'cost_per_property_paise', case when v_paying > 0 then v_costs_now / v_paying end,
                 'server_per_property_paise', case when v_paying > 0 then v_srv / v_paying end,
                 'cac_paise', case when v_new90 > 0 then v_mkt90 / v_new90 end,
                 'cac_payback_months', case when v_new90 > 0 and v_paying > 0 and v_mrr_net > 0 then round((v_mkt90::numeric / v_new90) / (v_mrr_net::numeric / v_paying), 1) end,
                 'marketing_90d_paise', v_mkt90)
  );
end $$;

create or replace function public.company_profile_save(p jsonb) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_cash bigint := nullif(p->>'cash_paise', '')::bigint; v_goal int := coalesce(nullif(p->>'runway_goal_months', '')::int, 6);
        v_started date := nullif(p->>'started_on', '')::date;
begin
  perform public._assert_platform_admin();
  if v_started is not null and v_started > (now() at time zone 'Asia/Kolkata')::date then raise exception 'The start date can''t be in the future.'; end if;
  if v_goal not between 1 and 36 then raise exception 'Runway goal: between 1 and 36 months.'; end if;
  if v_cash is not null and v_cash < 0 then raise exception 'Cash in bank can''t be negative.'; end if;
  insert into public.company_profile as c (id, started_on, cash_paise, cash_updated_on, runway_goal_months, updated_at)
  values (1, v_started, v_cash, case when v_cash is not null then (now() at time zone 'Asia/Kolkata')::date end, v_goal, now())
  on conflict (id) do update set started_on = excluded.started_on, runway_goal_months = excluded.runway_goal_months, updated_at = now(),
    cash_paise = excluded.cash_paise,
    cash_updated_on = case when excluded.cash_paise is distinct from c.cash_paise then excluded.cash_updated_on else c.cash_updated_on end;
end $$;

create or replace function public.company_founder_save(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_share numeric := coalesce(nullif(p->>'share_pct', '')::numeric, 0);
        v_me boolean := coalesce((p->>'is_me')::boolean, false); v_other numeric;
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the founder''s name.'; end if;
  if v_share < 0 or v_share > 100 then raise exception 'Share: between 0 and 100%%.'; end if;
  if v_me and exists (select 1 from public.company_founders where is_me and id is distinct from v_id) then raise exception 'You are already in the list.'; end if;
  select coalesce(sum(share_pct), 0) into v_other from public.company_founders where id is distinct from v_id;
  if v_other + v_share > 100 then raise exception 'Shares would add up to % %%. Keep the total at 100%% or less.', v_other + v_share; end if;
  if v_id is null then
    insert into public.company_founders (name, role, share_pct, is_me) values (btrim(p->>'name'), nullif(btrim(p->>'role'), ''), v_share, v_me) returning id into v_id;
  else
    update public.company_founders set name = btrim(p->>'name'), role = nullif(btrim(p->>'role'), ''), share_pct = v_share, is_me = v_me where id = v_id;
    if not found then raise exception 'Founder not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.company_founder_delete(p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  delete from public.company_founders where id = p_id;    -- money they put in stays (no longer linked)
end $$;

create or replace function public.company_investment_save(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := nullif(p->>'amount_paise', '')::bigint; v_on date := nullif(p->>'made_on', '')::date;
        v_src text := coalesce(nullif(p->>'source', ''), 'founder'); v_f uuid := nullif(p->>'founder_id', '')::uuid;
begin
  perform public._assert_platform_admin();
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_on is null then raise exception 'Pick the date.'; end if;
  if v_on > (now() at time zone 'Asia/Kolkata')::date then raise exception 'The date can''t be in the future.'; end if;
  if v_src not in ('founder', 'investor', 'loan', 'grant', 'other') then raise exception 'Unknown source.'; end if;
  if v_f is not null and not exists (select 1 from public.company_founders where id = v_f) then raise exception 'Founder not found.'; end if;
  if v_id is null then
    insert into public.company_investments (made_on, amount_paise, source, founder_id, note)
    values (v_on, v_amt, v_src, v_f, nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_investments set made_on = v_on, amount_paise = v_amt, source = v_src, founder_id = v_f, note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Entry not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.company_investment_delete(p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin perform public._assert_platform_admin(); delete from public.company_investments where id = p_id; end $$;

create or replace function public.company_cost_save(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := nullif(p->>'amount_paise', '')::bigint;
        v_from date := nullif(p->>'starts_on', '')::date; v_to date := nullif(p->>'ends_on', '')::date;
        v_cat text := coalesce(nullif(p->>'category', ''), 'other'); v_every text := coalesce(nullif(p->>'every', ''), 'month');
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Give the cost a name, e.g. "Supabase".'; end if;
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_from is null then raise exception 'Pick the start date.'; end if;
  if v_to is not null and v_to < v_from then raise exception 'The stop date is before the start date.'; end if;
  if v_cat not in ('salaries', 'marketing', 'servers', 'tools', 'office', 'compliance', 'other') then raise exception 'Unknown category.'; end if;
  if v_every not in ('month', 'year', 'once') then raise exception 'Choose how often it is paid.'; end if;
  if v_every = 'once' then v_to := null; end if;
  if v_id is null then
    insert into public.company_costs (name, category, every, amount_paise, starts_on, ends_on, note)
    values (btrim(p->>'name'), v_cat, v_every, v_amt, v_from, v_to, nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_costs set name = btrim(p->>'name'), category = v_cat, every = v_every, amount_paise = v_amt,
           starts_on = v_from, ends_on = v_to, note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Cost not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.company_cost_delete(p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin perform public._assert_platform_admin(); delete from public.company_costs where id = p_id; end $$;

create or replace function public.company_income_save(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := nullif(p->>'amount_paise', '')::bigint; v_on date := nullif(p->>'received_on', '')::date;
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'source', ''))) < 2 then raise exception 'Where did the money come from? e.g. "Setup fee — Hotel Arya".'; end if;
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_on is null then raise exception 'Pick the date.'; end if;
  if v_on > (now() at time zone 'Asia/Kolkata')::date then raise exception 'The date can''t be in the future.'; end if;
  if v_id is null then
    insert into public.company_income (received_on, amount_paise, source, note) values (v_on, v_amt, btrim(p->>'source'), nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_income set received_on = v_on, amount_paise = v_amt, source = btrim(p->>'source'), note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Entry not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.company_income_delete(p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin perform public._assert_platform_admin(); delete from public.company_income where id = p_id; end $$;

create or replace function public.company_renewal_save(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_kind text := coalesce(nullif(p->>'kind', ''), 'other');
        v_rep text := coalesce(nullif(p->>'repeat', ''), 'none'); v_due date := nullif(p->>'due_on', '')::date;
        v_amt bigint := nullif(p->>'amount_paise', '')::bigint;
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'title', ''))) < 2 then raise exception 'Give it a name, e.g. "GSTR-3B".'; end if;
  if v_kind not in ('gst', 'tds', 'roc', 'itr', 'domain', 'ssl', 'trademark', 'server', 'licence', 'other') then raise exception 'Unknown type.'; end if;
  if v_rep not in ('none', 'month', 'quarter', 'year') then raise exception 'Choose how often it repeats.'; end if;
  if v_rep <> 'none' and v_due is null then raise exception 'A repeating item needs its next due date.'; end if;
  if v_id is null then
    insert into public.company_renewals (kind, title, due_on, repeat, amount_paise, note)
    values (v_kind, btrim(p->>'title'), v_due, v_rep, v_amt, nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_renewals set kind = v_kind, title = btrim(p->>'title'), due_on = v_due, repeat = v_rep, amount_paise = v_amt,
           note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Item not found.'; end if;
  end if;
  return v_id;
end $$;

-- Mark done: a repeating item moves to its next due date; a one-off item is closed
create or replace function public.company_renewal_done(p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare r public.company_renewals%rowtype;
begin
  perform public._assert_platform_admin();
  select * into r from public.company_renewals where id = p_id for update;
  if not found then raise exception 'Item not found.'; end if;
  if r.repeat <> 'none' then
    update public.company_renewals set due_on = public._co_next_due(r.due_on, r.repeat) where id = p_id returning * into r;
  else
    update public.company_renewals set done_on = (now() at time zone 'Asia/Kolkata')::date where id = p_id returning * into r;
  end if;
  return jsonb_build_object('due_on', r.due_on, 'done_on', r.done_on);
end $$;

create or replace function public.company_renewal_delete(p_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin perform public._assert_platform_admin(); delete from public.company_renewals where id = p_id; end $$;

-- Menu badge: filings / renewals overdue or due within 7 days
create or replace function public.company_badge() returns int
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_platform_admin() then return 0; end if;
  return (select count(*) from public.company_renewals where done_on is null and due_on is not null
           and due_on <= (now() at time zone 'Asia/Kolkata')::date + 7)::int;
end $$;

-- ---------------------------------------------------------------- Company health
create or replace function public._co_area(p_key text, p_status text, p_value text, p_detail text, p_todo text, p_link text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('key', p_key, 'status', p_status, 'value', p_value, 'detail', p_detail, 'todo', p_todo, 'link', p_link,
           'score', case p_status when 'good' then 100 when 'watch' then 60 when 'act' then 20 end)
$$;

create or replace function public.company_health() returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s jsonb; v_rev jsonb; a jsonb := '[]'::jsonb; v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_week date := (date_trunc('week', now() at time zone 'Asia/Kolkata'))::date;
  v_mrr bigint; v_prev bigint; v_g numeric; v_paying int; v_churn int; v_ct int; v_cp int; v_n int; v_k int;
  v_pend int; v_grace int; v_profit bigint; v_months numeric; v_goal int; v_over int; v_soon int; v_ren int;
  v_score int; v_hist jsonb; v_last int;
begin
  perform public._assert_platform_admin();
  s := public.company_summary();
  v_rev := public.admin_revenue();
  v_mrr := (s->'income'->>'mrr_net_paise')::bigint; v_prev := (s->'income'->>'mrr_prev_net_paise')::bigint;
  v_paying := (s->'customers'->>'paying')::int;

  -- 1 growth: monthly income now vs 30 days ago
  if v_prev = 0 and v_mrr = 0 then
    a := a || public._co_area('growth', null, null, 'No paying properties yet.', 'Get your first paying property.', 'leads.html');
  else
    v_g := case when v_prev > 0 then round((v_mrr - v_prev) * 100.0 / v_prev, 1) else 100 end;
    a := a || public._co_area('growth', case when v_g >= 5 then 'good' when v_g >= 0 then 'watch' else 'act' end,
               case when v_g >= 0 then '+' else '' end || v_g || '%', 'Monthly income now vs 30 days ago (target: 5%+ a month).',
               case when v_g < 0 then 'Monthly income went down — call properties that stopped paying.' when v_g < 5 then 'Growth is slow — follow up your open leads this week.' end,
               case when v_g < 0 then 'subscribers.html' else 'leads.html' end);
  end if;

  -- 2 customers leaving (30 days)
  v_churn := coalesce((v_rev->>'churned_30')::int, 0);
  if v_paying + v_churn = 0 then
    a := a || public._co_area('churn', null, null, 'No paying properties yet.', null, 'subscribers.html');
  else
    v_g := round(v_churn * 100.0 / (v_paying + v_churn), 1);
    a := a || public._co_area('churn', case when v_g <= 3 then 'good' when v_g <= 7 then 'watch' else 'act' end, v_churn || ' left · ' || v_g || '%',
               'Properties whose paid period ended in the last 30 days without renewing (target: 3% or less).',
               case when v_g > 3 then 'Call the ' || v_churn || ' that left — ask why, offer help or a coupon.' end, 'subscribers.html');
  end if;

  -- 3 trial → paid (properties added in the last 90 days)
  v_ct := coalesce((v_rev->'conversion_90'->>'trials')::int, 0); v_cp := coalesce((v_rev->'conversion_90'->>'paid')::int, 0);
  if v_ct < 3 then
    a := a || public._co_area('conversion', null, null, 'Needs at least 3 trials in the last 90 days.', null, 'admin.html');
  else
    v_g := round(v_cp * 100.0 / v_ct);
    a := a || public._co_area('conversion', case when v_g >= 30 then 'good' when v_g >= 15 then 'watch' else 'act' end, v_g || '% (' || v_cp || ' of ' || v_ct || ')',
               'Trials from the last 90 days that went on to pay (target: 30%+).',
               case when v_g < 30 then 'Call trials ending this week and help them set up.' end, 'admin.html');
  end if;

  -- 4 getting started: properties added 7–60 days ago with at least one booking
  select count(*), count(*) filter (where exists (select 1 from public.bookings b where b.property_id = p.id))
    into v_n, v_k from public.properties p join public.subscriptions su on su.property_id = p.id and not su.is_complimentary
   where p.created_at between now() - interval '60 days' and now() - interval '7 days';
  if v_n < 3 then
    a := a || public._co_area('activation', null, null, 'Needs at least 3 properties added 1–8 weeks ago.', null, 'admin.html');
  else
    v_g := round(v_k * 100.0 / v_n);
    a := a || public._co_area('activation', case when v_g >= 70 then 'good' when v_g >= 40 then 'watch' else 'act' end, v_g || '% (' || v_k || ' of ' || v_n || ')',
               'New properties (1–8 weeks old) that have added at least one booking (target: 70%+).',
               case when v_g < 70 then (v_n - v_k) || ' new properties have no bookings yet — offer a setup call.' end, 'admin.html');
  end if;

  -- 5 inactive paying customers: no booking added in 14 days
  if v_paying = 0 then
    a := a || public._co_area('inactive', null, null, 'No paying properties yet.', null, 'admin.html');
  else
    select count(*) into v_k from public.subscriptions su
     where su.paid_until > now() and not su.is_complimentary and not coalesce(su.is_suspended, false)
       and not exists (select 1 from public.bookings b where b.property_id = su.property_id and b.created_at > now() - interval '14 days');
    v_g := round(v_k * 100.0 / v_paying);
    a := a || public._co_area('inactive', case when v_g <= 10 then 'good' when v_g <= 25 then 'watch' else 'act' end, v_k || ' of ' || v_paying,
               'Paying properties that haven''t added a booking in 14 days (target: 10% or less). Quiet customers leave next.',
               case when v_g > 10 then 'Check on the ' || v_k || ' quiet properties before renewal time.' end, 'admin.html');
  end if;

  -- 6 money to collect: payments waiting for review > 2 days, properties past due (grace)
  select count(*) into v_pend from public.subscription_payments where status = 'pending' and submitted_at < now() - interval '2 days';
  select count(*) into v_grace from public.subscriptions su where public._access_state(su.property_id) = 'grace';
  a := a || public._co_area('collections', case when v_pend = 0 and v_grace = 0 then 'good' when v_pend <= 1 and v_grace <= 2 then 'watch' else 'act' end,
             case when v_pend + v_grace = 0 then 'All clear' else v_pend || ' to review · ' || v_grace || ' past due' end,
             'Payments owners sent that you haven''t checked for 2+ days, and properties past their paid date.',
             case when v_pend > 0 then 'Review ' || v_pend || ' payment' || case when v_pend = 1 then '' else 's' end || ' waiting more than 2 days.'
                  when v_grace > 0 then 'Remind ' || v_grace || ' propert' || case when v_grace = 1 then 'y' else 'ies' end || ' whose payment is due.' end, 'subscribers.html');

  -- 7 runway
  v_profit := (s->'run_rate'->>'profit_paise')::bigint; v_months := nullif(s->'runway'->>'months', '')::numeric; v_goal := (s->'runway'->>'goal_months')::int;
  if not exists (select 1 from public.company_costs) then
    a := a || public._co_area('runway', null, null, 'Add your monthly costs to see runway.', 'Add your monthly costs (salaries, servers, tools…).', 'company.html#costs');
  elsif v_profit >= 0 then
    a := a || public._co_area('runway', 'good', 'Self-funding', 'Income covers costs every month.', null, 'company.html');
  elsif v_months is null then
    a := a || public._co_area('runway', null, null, 'Spending more than earning — enter cash in bank to see how long it lasts.', 'Enter cash in bank to see your runway.', 'company.html#cash');
  else
    a := a || public._co_area('runway', case when v_months >= v_goal then 'good' when v_months >= 3 then 'watch' else 'act' end, v_months || ' months',
               'How long cash in bank lasts at today''s monthly loss (goal: ' || v_goal || ' months).',
               case when v_months < v_goal then 'Cut a cost or raise money — under ' || v_goal || ' months of cash left.' end, 'company.html');
  end if;

  -- 8 filings & renewals
  select count(*), count(*) filter (where due_on < v_today), count(*) filter (where due_on between v_today and v_today + 7)
    into v_ren, v_over, v_soon from public.company_renewals where done_on is null;
  if v_ren = 0 then
    a := a || public._co_area('filings', null, null, 'No filings or renewals added yet.', 'Add GST, ROC, domain and other due dates.', 'company.html#renewals');
  else
    a := a || public._co_area('filings', case when v_over > 0 then 'act' when v_soon > 0 then 'watch' else 'good' end,
               case when v_over > 0 then v_over || ' overdue' when v_soon > 0 then v_soon || ' due this week' else 'All on time' end,
               'GST, TDS, ROC, income tax, domain, trademark and other due dates you added.',
               case when v_over > 0 then 'File or renew the ' || v_over || ' overdue item' || case when v_over = 1 then '' else 's' end || ' — late fees add up.'
                    when v_soon > 0 then v_soon || ' due within 7 days — keep the documents ready.' end, 'company.html#renewals');
  end if;

  select round(avg((x->>'score')::int)) into v_score from jsonb_array_elements(a) x where x->>'status' is not null;
  if v_score is not null then
    insert into public.company_health_snapshots (week_start, score, areas) values (v_week, v_score, a)
    on conflict (week_start) do update set score = excluded.score, areas = excluded.areas, created_at = now();
  end if;
  select score into v_last from public.company_health_snapshots where week_start < v_week order by week_start desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('week', week_start, 'score', score) order by week_start), '[]'::jsonb) into v_hist
    from (select * from public.company_health_snapshots order by week_start desc limit 12) z;

  return jsonb_build_object('score', v_score,
    'verdict', case when v_score is null then null when v_score >= 75 then 'healthy' when v_score >= 50 then 'attention' else 'risk' end,
    'last_week', v_last, 'areas', a, 'history', v_hist,
    'counts', jsonb_build_object('good', (select count(*) from jsonb_array_elements(a) x where x->>'status' = 'good'),
                                 'watch', (select count(*) from jsonb_array_elements(a) x where x->>'status' = 'watch'),
                                 'act', (select count(*) from jsonb_array_elements(a) x where x->>'status' = 'act'),
                                 'nodata', (select count(*) from jsonb_array_elements(a) x where x->>'status' is null)));
end $$;

-- ---------------------------------------------------------------- permissions: signed-in callers; each function checks is_platform_admin()
do $$ declare f text; begin
  foreach f in array array['company_summary()', 'company_profile_save(jsonb)', 'company_founder_save(jsonb)', 'company_founder_delete(uuid)',
    'company_investment_save(jsonb)', 'company_investment_delete(uuid)', 'company_cost_save(jsonb)', 'company_cost_delete(uuid)',
    'company_income_save(jsonb)', 'company_income_delete(uuid)', 'company_renewal_save(jsonb)', 'company_renewal_done(uuid)',
    'company_renewal_delete(uuid)', 'company_badge()', 'company_health()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['_co_month0()', '_co_net(numeric)', '_co_month_costs(date)', '_co_paying_at(timestamptz)', '_co_next_due(date, text)',
    '_co_renewals()', '_co_area(text, text, text, text, text, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

select to_regprocedure('public.company_health()') is not null as company_installed;


-- =====================================================================
-- NammaStay · 041_smart_pricing.sql — Smart pricing: prices follow demand, inside the owner's limits
--
-- Every morning (and when the Smart pricing tab is opened) NammaStay looks at the next 60 nights for
-- each room: how full the night is, how fast beds are going compared with this property's usual pace,
-- how close the date is, weekends and festival / event dates. It then works out a small change:
--   • busy nights go up (+5 … +15 %), festival nights at least +10 %
--   • quiet nights a few days away get a small discount (−5 … −10 %); never Fri/Sat if the owner says so
--   • never more than the "biggest change in one day" step (default 10 %), never outside the owner's
--     lowest / highest price for each bed type, never on nights with the owner's own seasonal price,
--     never on nights the owner pinned by hand.
-- Modes: off · suggest (owner taps Apply) · auto (applied by itself + a notification).
--
-- HOW PRICES CHANGE: through the existing price rules (rate_rules). Smart pricing writes its own
-- "Smart pricing" season rules (tracked in smart_price_rules) — the live pricing code (_night_rate,
-- bookings, booking page, API, channel manager) is NOT changed and simply picks them up.
-- Bookings already made keep their price. Turning it off removes its rules: prices go back to normal.
--
-- ADD-ON ONLY — new tables and functions; existing tables and functions are not changed.
-- Owners and managers with "rooms & prices" permission. Not for PG / monthly tenants.
-- Safe to run more than once. Rollback: rollback_041_smart_pricing.sql
-- =====================================================================

do $$ begin
  if to_regprocedure('public._night_rate(uuid,uuid,integer,date)') is null or to_regclass('public.rate_rules') is null then
    raise exception 'Price rules (026) are missing — run the main setup first.';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.smart_price_settings (
  property_id         uuid primary key references public.properties(id) on delete cascade,
  mode                text not null default 'off' check (mode in ('off', 'suggest', 'auto')),
  max_step_pct        int  not null default 10 check (max_step_pct between 5 and 30),
  no_weekend_discount boolean not null default true,
  paused_until        date,
  last_run_at         timestamptz,
  updated_at          timestamptz not null default now(),
  updated_by          uuid
);

create table if not exists public.smart_price_limits (           -- per bed type = room + its normal price
  property_id uuid not null references public.properties(id) on delete cascade,
  room_id     uuid not null references public.rooms(id) on delete cascade,
  rate_paise  int  not null,
  min_paise   int  not null check (min_paise > 0),
  max_paise   int  not null,
  primary key (property_id, room_id, rate_paise),
  check (max_paise >= min_paise)
);

create table if not exists public.smart_price_dates (            -- festivals & local events
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 2 and 60),
  date_from   date not null,
  date_to     date not null,
  created_at  timestamptz not null default now(),
  check (date_to >= date_from and date_to - date_from <= 30)
);
create index if not exists smart_price_dates_prop on public.smart_price_dates (property_id, date_from);

create table if not exists public.smart_price_nights (           -- one row per room per night looked at
  property_id uuid not null references public.properties(id) on delete cascade,
  room_id     uuid not null references public.rooms(id) on delete cascade,
  night       date not null,
  auto_pct    int  not null default 0,        -- change in effect now (vs the owner's own price)
  auto_amt    int,                            -- the same as ₹ (paise) per night when the owner has no % rule that night
  owner_pct   int  not null default 0,        -- the owner's own weekend % rule that night (kept, combined)
  suggest_pct int,                            -- waiting for the owner (suggest mode)
  suggest_amt int,
  skip_pct    int,                            -- owner skipped this suggestion: don't suggest the same again
  locked      boolean not null default false, -- owner pinned this night: never changed automatically
  owner_rule  boolean not null default false, -- the owner's own seasonal / fixed price covers this night
  booked      int,
  cap         int,
  reason      text,
  applied_at  timestamptz,
  updated_at  timestamptz not null default now(),
  primary key (property_id, room_id, night)
);

create table if not exists public.smart_price_rules (            -- the rate_rules rows Smart pricing owns
  rule_id     uuid primary key references public.rate_rules(id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade
);
create index if not exists smart_price_rules_prop on public.smart_price_rules (property_id);

create table if not exists public.smart_price_runs (             -- "Recent changes" + undo
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  ran_at      timestamptz not null default now(),
  kind        text not null check (kind in ('auto', 'suggest', 'applied', 'off', 'undo', 'pinned')),
  up          int not null default 0,
  down        int not null default 0,
  suggested   int not null default 0,
  by_user     uuid,
  undo        jsonb not null default '[]',
  undone_at   timestamptz
);
create index if not exists smart_price_runs_prop on public.smart_price_runs (property_id, ran_at desc);

do $$ declare t text; begin
  foreach t in array array['smart_price_settings', 'smart_price_limits', 'smart_price_dates', 'smart_price_nights', 'smart_price_rules', 'smart_price_runs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);   -- only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- helpers (server only)
create or replace function public._sp_tz(p_property uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select nullif(timezone, '') from public.properties where id = p_property), 'Asia/Kolkata')
$$;

create or replace function public._sp_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone public._sp_tz(p_property))::date
$$;

create or replace function public._sp_check(p_property uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner', 'manager']::public.member_role[]);
  perform public._require_perm(p_property, 'manage_rooms');
end $$;

create or replace function public._sp_is_pg(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select to_regclass('public.pg_properties') is not null
     and exists (select 1 from public.pg_properties where property_id = p_property)
$$;

-- bed types: one per room + normal price, with the owner's limits (default 85 % … 150 % of the normal price)
create or replace function public._sp_groups(p_property uuid)
returns table (room_id uuid, room text, rate_paise int, label text, beds int, min_paise int, max_paise int, custom boolean, sort int)
language sql stable security definer set search_path = public, pg_temp as $$
  with g as (
    select b.room_id, r.name room, b.rate_paise, count(*)::int beds, min(r.sort) rsort,
           case when count(distinct b.position) = 1 then min(b.position::text) end pos
      from public.beds b join public.rooms r on r.id = b.room_id
     where b.property_id = p_property and b.is_active
     group by b.room_id, r.name, b.rate_paise)
  select g.room_id, g.room, g.rate_paise,
         g.room || case when (select count(*) from g g2 where g2.room_id = g.room_id) > 1
                        then ' · ' || coalesce(initcap(g.pos), to_char(g.rate_paise / 100, 'FM₹99,999')) else '' end,
         g.beds,
         coalesce(l.min_paise, (round(g.rate_paise * 0.85 / 1000.0) * 1000)::int),
         coalesce(l.max_paise, (round(g.rate_paise * 1.5 / 1000.0) * 1000)::int),
         l.room_id is not null,
         row_number() over (order by g.rsort, g.room, g.rate_paise desc)::int
    from g left join public.smart_price_limits l on l.property_id = p_property and l.room_id = g.room_id and l.rate_paise = g.rate_paise
$$;

-- Rebuild the "Smart pricing" price rules from the nights table (consecutive nights with the same change = one rule)
create or replace function public._sp_rebuild(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  delete from public.rate_rules where id in (select rule_id from public.smart_price_rules where property_id = p_property);
  with n as (
    select x.room_id, x.night,
           case when x.owner_pct = 0 then 'amount' else 'percent' end adj,
           case when x.owner_pct = 0 then coalesce(x.auto_amt, 0)
                else round((100 + x.owner_pct) * (100 + x.auto_pct) / 100.0 - 100)::int end val
      from public.smart_price_nights x
     where x.property_id = p_property and x.night >= public._sp_today(p_property) and x.auto_pct <> 0
       and not x.locked and not x.owner_rule
       and exists (select 1 from public.rooms r where r.id = x.room_id)),
  runs as (
    select room_id, adj, val, min(night) d0, max(night) d1
      from (select n.*, n.night - (row_number() over (partition by room_id, adj, val order by night))::int grp from n where val <> 0) z
     group by room_id, adj, val, grp),
  ins as (
    insert into public.rate_rules (property_id, name, kind, date_from, date_to, adjust, value, room_ids, priority, is_active)
    select p_property, 'Smart pricing', 'season', d0, d1, adj, val, array[room_id], -1, true   -- below the owner's own dated rules (priority 0+)
      from runs where adj = 'amount' or val between -90 and 300
    returning id)
  insert into public.smart_price_rules (rule_id, property_id) select id, p_property from ins;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- The heart: look at the next 60 nights and change / suggest prices
create or replace function public._sp_run(p_property uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  st public.smart_price_settings; tz text := public._sp_tz(p_property); v_today date := public._sp_today(p_property);
  v_beds int; v_hist int; v_usual numeric[]; r record; x record; cur public.smart_price_nights; o record; g record;
  v_occ numeric; v_L int; v_pace numeric; v_wk boolean; v_fest text; v_opct int; v_t int; v_why text;
  v_lo numeric; v_hi numeric; v_cur int; v_new int; v_amt int; v_alo int; v_ahi int; v_rep int;
  v_up int := 0; v_down int := 0; v_sug int := 0; v_undo jsonb := '[]'::jsonb; v_owner boolean;
  v_u text;                                                      -- 'beds' for hostels/PGs, 'rooms' for hotels, homestays, resorts
begin
  v_u := case when (select kind from public.properties where id = p_property)::text = 'hostel' then 'beds' else 'rooms' end;
  select * into st from public.smart_price_settings where property_id = p_property;
  if not found or st.mode = 'off' or public._sp_is_pg(p_property) then return jsonb_build_object('ran', false); end if;
  if st.paused_until is not null and st.paused_until >= v_today then return jsonb_build_object('ran', false, 'paused', true); end if;

  -- this property's usual pace: how full past nights already were 1 / 3 / 7 / 14 / 30 days before
  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  select count(*) into v_hist
    from public.bookings b, generate_series(greatest((b.check_in_at at time zone tz)::date, v_today - 56), least((b.check_out_at at time zone tz)::date - 1, v_today - 1), interval '1 day') h
   where b.property_id = p_property and b.status not in ('cancelled', 'no_show') and b.check_out_at > now() - interval '60 days' and b.check_in_at < now();
  select array_agg(u order by bk) into v_usual from (
    select bk, (select count(*) from public.bookings b,
                       generate_series(greatest((b.check_in_at at time zone tz)::date, v_today - 56), least((b.check_out_at at time zone tz)::date - 1, v_today - 1), interval '1 day') h
                 where b.property_id = p_property and b.status not in ('cancelled', 'no_show') and b.check_out_at > now() - interval '60 days' and b.check_in_at < now()
                   and (b.created_at at time zone tz)::date <= h::date - bk)::numeric / greatest(56 * v_beds, 1) u
      from unnest(array[1, 3, 7, 14, 30]) bk) z;

  for r in select distinct g2.room_id from public._sp_groups(p_property) g2 loop
    for x in
      select d::date night,
             (select count(*) from public.beds b where b.room_id = r.room_id and b.is_active)
             - (select count(distinct bb.bed_id) from public.bed_blocks bb join public.beds b on b.id = bb.bed_id
                 where b.room_id = r.room_id and b.is_active and (bb.starts_at at time zone tz)::date <= d::date
                   and ((bb.ends_at at time zone tz)::date > d::date or (bb.starts_at at time zone tz)::date = d::date)) cap,
             (select count(distinct bk.bed_id) from public.bookings bk join public.beds b on b.id = bk.bed_id
               where b.room_id = r.room_id and bk.status in ('pending', 'confirmed', 'checked_in')
                 and (bk.check_in_at at time zone tz)::date <= d::date and (bk.check_out_at at time zone tz)::date > d::date) booked
        from generate_series(v_today, v_today + 59, interval '1 day') d
    loop
      select * into cur from public.smart_price_nights where property_id = p_property and room_id = r.room_id and night = x.night;
      if found and cur.locked then continue; end if;
      v_cur := coalesce(cur.auto_pct, 0);

      -- the owner's own rule that night (Smart pricing's own rules left out)
      select rr.kind, rr.adjust, rr.value into o from public.rate_rules rr
       where rr.property_id = p_property and rr.is_active and (rr.room_ids is null or r.room_id = any (rr.room_ids))
         and not exists (select 1 from public.smart_price_rules s where s.rule_id = rr.id)
         and ((rr.kind = 'weekend' and extract(dow from x.night)::smallint = any (rr.weekdays))
           or (rr.kind = 'season' and x.night between rr.date_from and rr.date_to
               and (rr.weekdays is null or extract(dow from x.night)::smallint = any (rr.weekdays))))
       order by (rr.kind = 'season') desc, rr.priority desc, rr.created_at desc limit 1;
      v_owner := found and (o.kind = 'season' or o.adjust <> 'percent');
      v_opct := case when found and not v_owner then o.value else 0 end;

      v_occ := case when x.cap > 0 then x.booked::numeric / x.cap else 1 end;
      v_L := x.night - v_today;
      v_wk := extract(dow from x.night) in (5, 6);
      select string_agg(name, ', ') into v_fest from public.smart_price_dates where property_id = p_property and x.night between date_from and date_to;
      v_pace := case when v_hist >= 30 then v_occ / greatest(v_usual[case when v_L >= 30 then 5 when v_L >= 14 then 4 when v_L >= 7 then 3 when v_L >= 3 then 2 else 1 end], 0.05) end;

      v_t := 0; v_why := null;
      if x.cap <= 0 then v_why := 'No ' || v_u || ' to sell';
      elsif v_owner then v_why := 'Your own seasonal price';
      else
        if v_occ >= 0.85 then v_t := 10; v_why := 'Nearly full — ' || x.booked || ' of ' || x.cap || ' ' || v_u || ' booked';
        elsif v_occ >= 0.7 then v_t := 5; v_why := 'Filling well — ' || x.booked || ' of ' || x.cap || ' ' || v_u || ' booked'; end if;
        if v_pace is not null and v_L >= 3 and v_pace >= 1.5 and v_occ >= 0.4 then
          v_t := v_t + 5; v_why := coalesce(v_why || ', ', x.booked || ' of ' || x.cap || ' ' || v_u || ' booked, ') || 'going faster than usual'; end if;
        if v_fest is not null and v_L >= 1 then
          v_t := greatest(v_t, 10) + case when v_occ >= 0.7 then 5 else 0 end; v_why := v_fest || coalesce(' · ' || v_why, '');
        elsif v_occ < 0.5 and not (v_wk and st.no_weekend_discount) then
          if v_L <= 2 then v_t := -10; v_why := 'Only ' || x.booked || ' of ' || x.cap || ' ' || v_u || ' booked, ' || case v_L when 0 then 'tonight' when 1 then 'tomorrow' else 'in 2 days' end;
          elsif v_L <= 6 and v_occ < 0.35 then v_t := -5; v_why := 'Only ' || x.booked || ' of ' || x.cap || ' ' || v_u || ' booked, ' || v_L || ' days away';
          elsif v_pace is not null and v_pace <= 0.5 and v_L <= 14 and v_occ < 0.35 then v_t := -5; v_why := 'Filling slower than usual — ' || x.booked || ' of ' || x.cap || ' ' || v_u || ' booked';
          end if;
        end if;
        -- the owner's lowest / highest price for every bed type in this room
        if v_t <> 0 then
          select max((gg.min_paise::numeric * 10000 / (gg.rate_paise * (100 + v_opct))) - 100), min((gg.max_paise::numeric * 10000 / (gg.rate_paise * (100 + v_opct))) - 100)
            into v_lo, v_hi from public._sp_groups(p_property) gg where gg.room_id = r.room_id;
          if v_t > 0 then v_t := greatest(0, least(v_t, floor(v_hi)::int)); else v_t := least(0, greatest(v_t, ceil(v_lo)::int)); end if;
        end if;
        if x.booked >= x.cap then v_t := v_cur; v_why := 'Full — no ' || v_u || ' left to sell'; end if;   -- nothing to sell: leave the price
      end if;

      -- move at most max_step_pct a day
      v_new := case when v_owner or x.cap <= 0 then 0 else v_cur + greatest(-st.max_step_pct, least(st.max_step_pct, v_t - v_cur)) end;
      v_amt := null;
      if v_opct = 0 and v_new <> 0 then                                          -- as ₹, rounded to ₹10
        select max(gg.rate_paise), max(gg.min_paise - gg.rate_paise), min(gg.max_paise - gg.rate_paise)
          into v_rep, v_alo, v_ahi from public._sp_groups(p_property) gg where gg.room_id = r.room_id;
        v_amt := (round(v_rep * v_new / 100.0 / 1000.0) * 1000)::int;
        v_amt := greatest(v_alo, least(v_ahi, v_amt));
        if v_amt = 0 then v_new := 0; v_amt := null; end if;
      end if;

      insert into public.smart_price_nights as n (property_id, room_id, night, owner_pct, owner_rule, booked, cap, reason, updated_at)
      values (p_property, r.room_id, x.night, v_opct, v_owner, x.booked, x.cap, v_why, now())
      on conflict (property_id, room_id, night) do update set owner_pct = excluded.owner_pct, owner_rule = excluded.owner_rule,
        booked = excluded.booked, cap = excluded.cap, reason = excluded.reason, updated_at = now();

      if st.mode = 'auto' or v_owner then
        if v_new <> v_cur or (v_new <> 0 and v_amt is distinct from cur.auto_amt) then
          v_undo := v_undo || jsonb_build_object('room', r.room_id, 'night', x.night, 'pct', v_cur, 'amt', cur.auto_amt);
          update public.smart_price_nights set auto_pct = v_new, auto_amt = v_amt, applied_at = now(), suggest_pct = null, suggest_amt = null
           where property_id = p_property and room_id = r.room_id and night = x.night;
          if v_new > v_cur then v_up := v_up + 1; elsif v_new < v_cur then v_down := v_down + 1; end if;
        else
          update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property and room_id = r.room_id and night = x.night;
        end if;
      else   -- suggest
        if v_new <> v_cur and v_new is distinct from cur.skip_pct then
          update public.smart_price_nights set suggest_pct = v_new, suggest_amt = v_amt where property_id = p_property and room_id = r.room_id and night = x.night;
          v_sug := v_sug + 1;
        else
          update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property and room_id = r.room_id and night = x.night;
        end if;
      end if;
    end loop;
  end loop;

  delete from public.smart_price_nights where property_id = p_property and night < v_today - 120;   -- keep 4 months for "extra earned"
  update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property and night < v_today and suggest_pct is not null;
  perform public._sp_rebuild(p_property);
  update public.smart_price_settings set last_run_at = now() where property_id = p_property;

  if v_up + v_down > 0 or v_sug > 0 then
    insert into public.smart_price_runs (property_id, kind, up, down, suggested, by_user, undo)
    values (p_property, case when st.mode = 'auto' then 'auto' else 'suggest' end, v_up, v_down, v_sug, p_by, v_undo);
  end if;
  if st.mode = 'auto' and v_up + v_down > 0 then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'smart_price', 'Smart pricing: ' || v_up || case when v_up = 1 then ' night up, ' else ' nights up, ' end || v_down || case when v_down = 1 then ' night down' else ' nights down' end,
            'Prices changed by demand, inside your limits. See or undo: Settings → Smart pricing.');
  elsif st.mode = 'suggest' and v_sug > 0 and p_by is null then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'smart_price', v_sug || case when v_sug = 1 then ' price suggestion' else ' price suggestions' end || ' waiting',
            'Settings → Smart pricing: tap Apply or Skip.');
  end if;
  return jsonb_build_object('ran', true, 'up', v_up, 'down', v_down, 'suggested', v_sug);
end $$;

-- ---------------------------------------------------------------- what the Smart pricing tab shows
create or replace function public.sp_get(p_property uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare st public.smart_price_settings; v_today date; tz text; v_groups jsonb; v_nights jsonb; v_prices jsonb; v_sug jsonb; v_stats jsonb; v_runs jsonb; v_dates jsonb;
begin
  perform public._sp_check(p_property);
  if public._sp_is_pg(p_property) then return jsonb_build_object('is_pg', true); end if;
  insert into public.smart_price_settings (property_id) values (p_property) on conflict do nothing;
  select * into st from public.smart_price_settings where property_id = p_property;
  if st.mode <> 'off' and (st.last_run_at is null or st.last_run_at < now() - interval '20 hours') then
    perform public._sp_run(p_property, null);
    select * into st from public.smart_price_settings where property_id = p_property;
  end if;
  v_today := public._sp_today(p_property); tz := public._sp_tz(p_property);

  select coalesce(jsonb_agg(jsonb_build_object('room_id', g.room_id, 'room', g.room, 'rate_paise', g.rate_paise, 'label', g.label, 'beds', g.beds,
           'min_paise', g.min_paise, 'max_paise', g.max_paise, 'custom', g.custom) order by g.sort), '[]'::jsonb)
    into v_groups from public._sp_groups(p_property) g;

  select coalesce(jsonb_agg(jsonb_build_object('night', d::date, 'weekend', extract(dow from d) in (5, 6),
           'booked', (select count(distinct bk.bed_id) from public.bookings bk join public.beds b on b.id = bk.bed_id
                       where bk.property_id = p_property and b.is_active and bk.status in ('pending', 'confirmed', 'checked_in')
                         and (bk.check_in_at at time zone tz)::date <= d::date and (bk.check_out_at at time zone tz)::date > d::date),
           'cap', (select count(*) from public.beds b where b.property_id = p_property and b.is_active
                     and not exists (select 1 from public.bed_blocks bb where bb.bed_id = b.id and (bb.starts_at at time zone tz)::date <= d::date
                                       and ((bb.ends_at at time zone tz)::date > d::date or (bb.starts_at at time zone tz)::date = d::date))),
           'festival', (select string_agg(name, ', ') from public.smart_price_dates where property_id = p_property and d::date between date_from and date_to))
           order by d), '[]'::jsonb)
    into v_nights from generate_series(v_today, v_today + 59, interval '1 day') d;

  select coalesce(jsonb_agg(jsonb_build_object('room_id', g.room_id, 'rate_paise', g.rate_paise, 'label', g.label,
           'cells', (select jsonb_agg(jsonb_build_object('night', d::date, 'price_paise', public._night_rate(p_property, g.room_id, g.rate_paise, d::date),
                       'auto_pct', coalesce(n.auto_pct, 0), 'locked', coalesce(n.locked, false), 'owner_rule', coalesce(n.owner_rule, false),
                       'suggest', n.suggest_pct is not null) order by d)
                       from generate_series(v_today, v_today + 59, interval '1 day') d
                       left join public.smart_price_nights n on n.property_id = p_property and n.room_id = g.room_id and n.night = d::date))
           order by g.sort), '[]'::jsonb)
    into v_prices from public._sp_groups(p_property) g;

  select coalesce(jsonb_agg(jsonb_build_object('room_id', n.room_id, 'room', r.name, 'night', n.night, 'pct', n.suggest_pct, 'reason', n.reason,
           'from_paise', public._night_rate(p_property, n.room_id, rep.rate_paise, n.night),
           'to_paise', case when n.owner_pct = 0 then rep.rate_paise + coalesce(n.suggest_amt, 0)
                            else round(rep.rate_paise * (100 + n.owner_pct) * (100 + n.suggest_pct) / 10000.0)::int end,
           'rate_paise', rep.rate_paise) order by n.night, r.sort), '[]'::jsonb)
    into v_sug
    from public.smart_price_nights n join public.rooms r on r.id = n.room_id
    cross join lateral (select max(b.rate_paise) rate_paise from public.beds b where b.room_id = n.room_id and b.is_active) rep
   where n.property_id = p_property and n.suggest_pct is not null and n.night >= v_today and rep.rate_paise is not null;

  select jsonb_build_object(
      'extra_30_paise', coalesce(sum(case when n.auto_pct > 0 then
                          case when n.owner_pct = 0 then coalesce(n.auto_amt, 0) else round(bd.rate_paise * (100 + n.owner_pct) / 100.0 * n.auto_pct / 100.0) end end), 0)::bigint,
      'up_nights_30', count(*) filter (where n.auto_pct > 0),
      'discount_nights_30', count(*) filter (where n.auto_pct < 0))
    into v_stats
    from public.bookings b join public.beds bd on bd.id = b.bed_id
    cross join lateral generate_series((b.check_in_at at time zone tz)::date, (b.check_out_at at time zone tz)::date - 1, interval '1 day') h
    join public.smart_price_nights n on n.property_id = b.property_id and n.room_id = bd.room_id and n.night = h::date and n.auto_pct <> 0 and n.applied_at <= b.created_at
   where b.property_id = p_property and b.created_at > now() - interval '30 days' and b.status not in ('cancelled', 'no_show');
  v_stats := v_stats || jsonb_build_object(
      'up_now', (select count(distinct night) from public.smart_price_nights where property_id = p_property and night >= v_today and auto_pct > 0 and not locked and not owner_rule),
      'down_now', (select count(distinct night) from public.smart_price_nights where property_id = p_property and night >= v_today and auto_pct < 0 and not locked and not owner_rule));

  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'ran_at', x.ran_at, 'kind', x.kind, 'up', x.up, 'down', x.down, 'suggested', x.suggested,
           'can_undo', x.undone_at is null and jsonb_array_length(x.undo) > 0 and x.ran_at > now() - interval '7 days', 'undone', x.undone_at is not null) order by x.ran_at desc), '[]'::jsonb)
    into v_runs from (select * from public.smart_price_runs where property_id = p_property order by ran_at desc limit 8) x;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'date_from', date_from, 'date_to', date_to) order by date_from), '[]'::jsonb)
    into v_dates from public.smart_price_dates where property_id = p_property and date_to >= v_today;

  return jsonb_build_object('is_pg', false, 'today', v_today,
    'settings', jsonb_build_object('mode', st.mode, 'max_step_pct', st.max_step_pct, 'no_weekend_discount', st.no_weekend_discount,
                  'paused_until', case when st.paused_until >= v_today then st.paused_until end, 'last_run_at', st.last_run_at),
    'channel_manager', to_regclass('public.channex_room_map') is not null
                       and exists (select 1 from public.channex_room_map where property_id = p_property and cx_rate_plan_id is not null),
    'groups', v_groups, 'nights', v_nights, 'prices', v_prices, 'suggestions', v_sug, 'stats', v_stats, 'runs', v_runs, 'dates', v_dates);
end $$;

-- ---------------------------------------------------------------- owner actions
create or replace function public.sp_settings_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_mode text := coalesce(nullif(p->>'mode', ''), 'off'); v_step int := coalesce(nullif(p->>'max_step_pct', '')::int, 10);
        v_old text; v_today date := public._sp_today(p_property); v_undo jsonb;
begin
  perform public._sp_check(p_property);
  if public._sp_is_pg(p_property) then raise exception 'Smart pricing is for nightly stays, not monthly PG tenants.'; end if;
  if v_mode not in ('off', 'suggest', 'auto') then raise exception 'Choose Suggest only, Automatic or Off.'; end if;
  if v_step not in (5, 10, 15, 20) then raise exception 'Biggest change in one day: 5, 10, 15 or 20%%.'; end if;
  insert into public.smart_price_settings (property_id) values (p_property) on conflict do nothing;
  select mode into v_old from public.smart_price_settings where property_id = p_property;
  update public.smart_price_settings set mode = v_mode, max_step_pct = v_step,
         no_weekend_discount = coalesce((p->>'no_weekend_discount')::boolean, no_weekend_discount),
         paused_until = case when v_mode = 'off' then null else paused_until end,
         updated_at = now(), updated_by = auth.uid()
   where property_id = p_property;
  if v_mode = 'off' and v_old <> 'off' then          -- back to the owner's own prices
    select coalesce(jsonb_agg(jsonb_build_object('room', room_id, 'night', night, 'pct', auto_pct, 'amt', auto_amt)), '[]'::jsonb) into v_undo
      from public.smart_price_nights where property_id = p_property and night >= v_today and auto_pct <> 0;
    update public.smart_price_nights set auto_pct = 0, auto_amt = null, suggest_pct = null, suggest_amt = null, applied_at = now()
     where property_id = p_property and night >= v_today and (auto_pct <> 0 or suggest_pct is not null);
    perform public._sp_rebuild(p_property);
    insert into public.smart_price_runs (property_id, kind, by_user, undo) values (p_property, 'off', auth.uid(), v_undo);
  elsif v_mode <> 'off' then
    if v_mode = 'auto' and v_old = 'suggest' then
      update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property;
    end if;
    return public._sp_run(p_property, auth.uid());
  end if;
  return jsonb_build_object('ran', false);
end $$;

create or replace function public.sp_limits_save(p_property uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare x jsonb; g record;
begin
  perform public._sp_check(p_property);
  if jsonb_typeof(p) <> 'array' then raise exception 'Send the limits as a list.'; end if;
  for x in select * from jsonb_array_elements(p) loop
    select * into g from public._sp_groups(p_property) gg where gg.room_id = (x->>'room_id')::uuid and gg.rate_paise = (x->>'rate_paise')::int;
    if not found then raise exception 'That bed type no longer exists — reload the page.'; end if;
    if (x->>'min_paise')::int is null or (x->>'max_paise')::int is null then raise exception 'Enter the lowest and highest price for %.', g.label; end if;
    if (x->>'min_paise')::int > g.rate_paise then raise exception '%: the lowest price can’t be above the normal price (₹%).', g.label, g.rate_paise / 100; end if;
    if (x->>'max_paise')::int < g.rate_paise then raise exception '%: the highest price can’t be below the normal price (₹%).', g.label, g.rate_paise / 100; end if;
    if (x->>'min_paise')::int < g.rate_paise * 0.5 then raise exception '%: the lowest price can be at most 50%% below normal.', g.label; end if;
    if (x->>'max_paise')::int > g.rate_paise * 3 then raise exception '%: the highest price can be at most 3 times normal.', g.label; end if;
    insert into public.smart_price_limits (property_id, room_id, rate_paise, min_paise, max_paise)
    values (p_property, g.room_id, g.rate_paise, (x->>'min_paise')::int, (x->>'max_paise')::int)
    on conflict (property_id, room_id, rate_paise) do update set min_paise = excluded.min_paise, max_paise = excluded.max_paise;
  end loop;
end $$;

create or replace function public.sp_date_save(p_property uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_from date := nullif(p->>'date_from', '')::date; v_to date := coalesce(nullif(p->>'date_to', '')::date, nullif(p->>'date_from', '')::date);
begin
  perform public._sp_check(p_property);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Name the festival or event, e.g. "Diwali".'; end if;
  if v_from is null then raise exception 'Pick the first night.'; end if;
  if v_to < v_from then raise exception 'The last night is before the first night.'; end if;
  if v_to - v_from > 30 then raise exception 'Keep it to 31 nights or fewer.'; end if;
  if v_id is null then
    insert into public.smart_price_dates (property_id, name, date_from, date_to) values (p_property, btrim(p->>'name'), v_from, v_to) returning id into v_id;
  else
    update public.smart_price_dates set name = btrim(p->>'name'), date_from = v_from, date_to = v_to where id = v_id and property_id = p_property;
    if not found then raise exception 'Date not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.sp_date_delete(p_property uuid, p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._sp_check(p_property);
  delete from public.smart_price_dates where id = p_id and property_id = p_property;
end $$;

-- Apply suggestions: p = [{room_id, night}] or null for all
create or replace function public.sp_apply(p_property uuid, p jsonb) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_undo jsonb; v_up int; v_down int; v_n int;
begin
  perform public._sp_check(p_property);
  create temp table if not exists _sp_pick (room_id uuid, night date) on commit drop; truncate _sp_pick;
  insert into _sp_pick select n.room_id, n.night from public.smart_price_nights n
   where n.property_id = p_property and n.suggest_pct is not null and n.night >= public._sp_today(p_property)
     and (p is null or jsonb_typeof(p) <> 'array' or exists (select 1 from jsonb_array_elements(p) e where (e->>'room_id')::uuid = n.room_id and (e->>'night')::date = n.night));
  select coalesce(jsonb_agg(jsonb_build_object('room', n.room_id, 'night', n.night, 'pct', n.auto_pct, 'amt', n.auto_amt)), '[]'::jsonb),
         count(*) filter (where n.suggest_pct > n.auto_pct), count(*) filter (where n.suggest_pct < n.auto_pct), count(*)
    into v_undo, v_up, v_down, v_n
    from public.smart_price_nights n join _sp_pick k on k.room_id = n.room_id and k.night = n.night where n.property_id = p_property;
  if v_n = 0 then raise exception 'Nothing to apply — the suggestions may have changed. Reload the page.'; end if;
  update public.smart_price_nights n set auto_pct = n.suggest_pct, auto_amt = n.suggest_amt, suggest_pct = null, suggest_amt = null, skip_pct = null, applied_at = now()
    from _sp_pick k where n.property_id = p_property and k.room_id = n.room_id and k.night = n.night;
  perform public._sp_rebuild(p_property);
  insert into public.smart_price_runs (property_id, kind, up, down, by_user, undo) values (p_property, 'applied', v_up, v_down, auth.uid(), v_undo);
  return v_n;
end $$;

create or replace function public.sp_skip(p_property uuid, p jsonb) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  perform public._sp_check(p_property);
  update public.smart_price_nights n set skip_pct = n.suggest_pct, suggest_pct = null, suggest_amt = null
   where n.property_id = p_property and n.suggest_pct is not null
     and (p is null or jsonb_typeof(p) <> 'array' or exists (select 1 from jsonb_array_elements(p) e where (e->>'room_id')::uuid = n.room_id and (e->>'night')::date = n.night));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Pin a night to the owner's own price (Smart pricing leaves it alone) or hand it back
create or replace function public.sp_night_lock(p_property uuid, p_room uuid, p_night date, p_locked boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._sp_check(p_property);
  if not exists (select 1 from public.rooms where id = p_room and property_id = p_property) then raise exception 'Room not found.'; end if;
  if p_night < public._sp_today(p_property) then raise exception 'That night has passed.'; end if;
  insert into public.smart_price_nights (property_id, room_id, night, locked) values (p_property, p_room, p_night, p_locked)
  on conflict (property_id, room_id, night) do update set locked = excluded.locked,
    auto_pct = case when excluded.locked then 0 else smart_price_nights.auto_pct end,
    auto_amt = case when excluded.locked then null else smart_price_nights.auto_amt end,
    suggest_pct = null, suggest_amt = null, updated_at = now();
  perform public._sp_rebuild(p_property);
  insert into public.smart_price_runs (property_id, kind, by_user) values (p_property, 'pinned', auth.uid());
end $$;

create or replace function public.sp_run_now(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._sp_check(p_property);
  return public._sp_run(p_property, auth.uid());
end $$;

create or replace function public.sp_pause(p_property uuid, p_days int) returns date
language plpgsql security definer set search_path = public, pg_temp as $$
declare v date;
begin
  perform public._sp_check(p_property);
  if p_days is null or p_days < 0 or p_days > 60 then raise exception 'Pause for 0 to 60 days.'; end if;
  v := case when p_days = 0 then null else public._sp_today(p_property) + p_days - 1 end;
  update public.smart_price_settings set paused_until = v, updated_at = now(), updated_by = auth.uid() where property_id = p_property;
  return v;
end $$;

create or replace function public.sp_undo(p_property uuid, p_run uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.smart_price_runs; e jsonb; v_n int := 0;
begin
  perform public._sp_check(p_property);
  select * into x from public.smart_price_runs where id = p_run and property_id = p_property for update;
  if not found then raise exception 'Change not found.'; end if;
  if x.undone_at is not null then raise exception 'Already undone.'; end if;
  for e in select * from jsonb_array_elements(x.undo) loop
    if (e->>'night')::date >= public._sp_today(p_property) then
      update public.smart_price_nights set auto_pct = (e->>'pct')::int, auto_amt = nullif(e->>'amt', '')::int, suggest_pct = null, suggest_amt = null,
             skip_pct = coalesce(suggest_pct, skip_pct), applied_at = now()
       where property_id = p_property and room_id = (e->>'room')::uuid and night = (e->>'night')::date and not locked;
      v_n := v_n + 1;
    end if;
  end loop;
  if x.kind = 'off' then   -- undoing "turn off" = turn back on the way it was
    update public.smart_price_settings set mode = coalesce((select kind from public.smart_price_runs where property_id = p_property and kind in ('auto', 'suggest') order by ran_at desc limit 1), 'suggest')
     where property_id = p_property;
  end if;
  update public.smart_price_runs set undone_at = now() where id = p_run;
  perform public._sp_rebuild(p_property);
  insert into public.smart_price_runs (property_id, kind, by_user) values (p_property, 'undo', auth.uid());
  return v_n;
end $$;

-- Every morning (pg_cron): select cron.schedule('nammastay-smart-pricing', '30 0 * * *', $$select public.sp_run_all()$$);  -- 6:00 AM India
create or replace function public.sp_run_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; n int := 0;
begin
  for pid in select property_id from public.smart_price_settings where mode <> 'off' loop
    begin
      if (public._sp_run(pid, null)->>'ran')::boolean then n := n + 1; end if;
    exception when others then raise warning 'smart pricing % failed: %', pid, sqlerrm;
    end;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- permissions
do $$ declare f text; begin
  foreach f in array array['sp_get(uuid)', 'sp_settings_save(uuid, jsonb)', 'sp_limits_save(uuid, jsonb)', 'sp_date_save(uuid, jsonb)', 'sp_date_delete(uuid, uuid)',
    'sp_apply(uuid, jsonb)', 'sp_skip(uuid, jsonb)', 'sp_night_lock(uuid, uuid, date, boolean)', 'sp_run_now(uuid)', 'sp_pause(uuid, integer)', 'sp_undo(uuid, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['_sp_tz(uuid)', '_sp_today(uuid)', '_sp_check(uuid)', '_sp_is_pg(uuid)', '_sp_groups(uuid)', '_sp_rebuild(uuid)', '_sp_run(uuid, uuid)', 'sp_run_all()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

select to_regprocedure('public.sp_get(uuid)') is not null as smart_pricing_installed;

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


-- =====================================================================
-- NammaStay · 043_branches.sql — owners with more than one property (branches)
--   • branch_create        the owner adds a branch themselves (same login). Each branch is its own property with
--                          its own free trial and its own subscription, exactly like a property made at sign-up.
--                          Optionally copies from an existing branch: rooms, beds & prices · times, GST, UPI &
--                          billing details · house rules & guest guide · staff shifts · team access.
--   • branches_overview    one screen for the owner: today and this month for every branch, the next 14 nights,
--                          alerts, plan status.
--   • branch_team / branch_access_set   who works at which branch; give or remove access in one tap.
-- Adds NO tables and changes NO existing function. Safe to run again.
-- Run AFTER the main setup (works with or without 031 PG, 034 resort, 040–042).
-- =====================================================================

-- ---------------------------------------------------------------- helpers
-- Hostel / hotel / homestay, or 'pg' / 'resort' when that switch is on (the tables may not exist yet).
create or replace function public._br_mode(p_property uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_kind text; v_on boolean;
begin
  select kind into v_kind from public.properties where id = p_property;
  if to_regclass('public.pg_properties') is not null then
    execute 'select exists (select 1 from public.pg_properties where property_id = $1)' into v_on using p_property;
    if v_on then return 'pg'; end if;
  end if;
  if to_regclass('public.resort_properties') is not null then
    execute 'select exists (select 1 from public.resort_properties where property_id = $1)' into v_on using p_property;
    if v_on then return 'resort'; end if;
  end if;
  return v_kind;
end $$;

create or replace function public._br_assert_owner() returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  if not exists (select 1 from public.property_members where user_id = auth.uid() and role = 'owner') then
    raise exception 'Only the owner can manage branches.' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

-- A free invoice prefix for a new branch: initials of the name, never the same as another branch of this owner
-- (two branches under one GSTIN must not both print INV-0001).
create or replace function public._br_prefix(p_name text, p_owner uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_base text; v_try text; i int := 1;
begin
  select string_agg(left(w, 1), '') into v_base
    from regexp_split_to_table(upper(regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9 ]', ' ', 'g')), '\s+') w where w <> '';
  v_base := left(coalesce(nullif(v_base, ''), 'BR'), 6);
  if char_length(v_base) < 2 then v_base := left(upper(regexp_replace(p_name, '[^A-Za-z0-9]', '', 'g')) || 'BR', 3); end if;
  v_try := v_base;
  while exists (select 1 from public.properties p join public.property_members m on m.property_id = p.id
                 where m.user_id = p_owner and m.role = 'owner' and p.invoice_prefix = v_try) loop
    i := i + 1; v_try := left(v_base, 8) || i;
  end loop;
  return v_try;
end $$;

-- ---------------------------------------------------------------- overview
create or replace function public.branches_overview() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := public._br_assert_owner();
  r record; s public.subscriptions%rowtype;
  v_tz text; v_today date; v_m0 date; t0 timestamptz; t1 timestamptz; tm0 timestamptz;
  v_mode text; v_units int; v_state text; v_end timestamptz;
  v_rev bigint; v_exp bigint; v_sold bigint; v_dues bigint; v_n int; v_j jsonb; v_alerts jsonb; v_url text;
  v_out jsonb := '[]'::jsonb;
begin
  for r in select p.* from public.properties p
             join public.property_members m on m.property_id = p.id and m.user_id = v_uid and m.role = 'owner'
            order by p.created_at, p.name loop
    v_tz := r.timezone; v_today := (now() at time zone v_tz)::date; v_m0 := date_trunc('month', v_today)::date;
    t0 := public._day_start(v_tz, v_today); t1 := t0 + interval '1 day'; tm0 := public._day_start(v_tz, v_m0);
    v_mode := public._br_mode(r.id);
    select count(*) into v_units from public.beds where property_id = r.id and is_active;

    -- plan
    select * into s from public.subscriptions where property_id = r.id;
    v_state := public._access_state(r.id);
    v_end := case v_state when 'trial' then s.trial_ends_at when 'active' then s.paid_until
                          else greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at)) end;

    -- money this month (room payments + PG rent receipts) and expenses
    select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0) into v_rev
      from public.payments where property_id = r.id and received_at >= tm0 and received_at < t1;
    v_dues := 0;
    if v_mode = 'pg' and to_regclass('public.rent_payments') is not null then
      execute $q$select coalesce(sum(case kind when 'refund' then -amount_paise when 'payment' then amount_paise else 0 end), 0)
                   from public.rent_payments where property_id = $1 and received_at >= $2 and received_at < $3$q$
        into v_n using r.id, tm0, t1;
      v_rev := v_rev + v_n;
      execute $q$select coalesce(sum(amount_paise - paid_paise), 0) from public.rent_dues
                  where property_id = $1 and due_on <= $2 and amount_paise > paid_paise$q$ into v_n using r.id, v_today;
      v_dues := v_n;
    end if;
    select coalesce(sum(amount_paise), 0) into v_exp from public.expenses where property_id = r.id and spent_on between v_m0 and v_today;
    select coalesce(sum(occupied), 0) into v_sold from public.occupancy_series(r.id, v_m0, v_today);

    -- alerts from the pages the owner already has (each one only if installed)
    v_alerts := '{}'::jsonb;
    begin
      if to_regprocedure('public.hk_counts(uuid)') is not null then
        execute 'select public.hk_counts($1)' into v_j using r.id;
        v_alerts := v_alerts || jsonb_build_object('to_clean', coalesce((v_j->>'dirty')::int, 0) + coalesce((v_j->>'cleaning')::int, 0));
      end if;
    exception when others then null; end;
    begin
      if to_regprocedure('public.formc_due_count(uuid)') is not null then
        execute 'select public.formc_due_count($1)' into v_n using r.id;
        v_alerts := v_alerts || jsonb_build_object('formc_due', coalesce(v_n, 0));
      end if;
    exception when others then null; end;
    begin
      if to_regprocedure('public.staff_counts(uuid)') is not null then
        execute 'select public.staff_counts($1)' into v_n using r.id;
        v_alerts := v_alerts || jsonb_build_object('staff_todo', coalesce(v_n, 0));
      end if;
    exception when others then null; end;
    v_url := null;
    begin
      if to_regclass('public.booking_pages') is not null then
        execute 'select slug from public.booking_pages where property_id = $1 and enabled' into v_url using r.id;
      end if;
    exception when others then v_url := null; end;

    v_out := v_out || jsonb_build_object(
      'id', r.id, 'name', r.name, 'kind', r.kind, 'mode', v_mode, 'city', r.city, 'phone', r.phone,
      'created_at', r.created_at, 'today', v_today, 'setup_done', r.setup_done_at is not null or v_units > 0,
      'plan', jsonb_build_object('state', v_state, 'ends_at', v_end,
        'days_left', case when v_state in ('trial','active') then greatest(0, ceil(extract(epoch from (v_end - now())) / 86400))::int end),
      'units', v_units,
      'tonight', (select count(*) from public.bookings where property_id = r.id and status in ('pending','confirmed','checked_in')
                   and stay @> public._night(v_tz, v_today)),
      'arriving', (select count(*) from public.bookings where property_id = r.id and check_in_at >= t0 and check_in_at < t1
                    and status in ('pending','confirmed','checked_in')),
      'arriving_unpaid', (select count(*) from public.bookings where property_id = r.id and check_in_at >= t0 and check_in_at < t1
                    and status in ('pending','confirmed') and paid_paise < total_paise),
      'leaving', (select count(*) from public.bookings where property_id = r.id and check_out_at >= t0 and check_out_at < t1
                   and status in ('checked_in','checked_out')),
      'collected_today', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                           from public.payments where property_id = r.id and received_at >= t0 and received_at < t1),
      'cash_today', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                      from public.payments where property_id = r.id and received_at >= t0 and received_at < t1 and method = 'cash'),
      'dues', v_dues + (select coalesce(sum(balance_paise), 0) from public.bookings where property_id = r.id
                         and balance_paise > 0 and status in ('checked_in','checked_out')),
      'month', jsonb_build_object('from', v_m0, 'days', v_today - v_m0 + 1, 'revenue', v_rev, 'expenses', v_exp, 'profit', v_rev - v_exp,
        'nights_sold', v_sold,
        'occupancy', case when v_units = 0 then 0 else round(v_sold::numeric / (v_units * (v_today - v_m0 + 1)), 4) end,
        'bookings', (select count(*) from public.bookings where property_id = r.id and check_in_at >= tm0 and check_in_at < t1
                      and status not in ('cancelled','no_show')),
        'direct', (select count(*) from public.bookings where property_id = r.id and check_in_at >= tm0 and check_in_at < t1
                    and status not in ('cancelled','no_show') and source <> 'ota')),
      'nights', (select coalesce(jsonb_agg(jsonb_build_object('day', x.day, 'occupied', x.occupied) order by x.day), '[]'::jsonb)
                   from public.occupancy_series(r.id, v_today, v_today + 13) x),
      'alerts', v_alerts,
      'booking_slug', v_url);
  end loop;
  return jsonb_build_object('branches', v_out, 'team', public.branch_team(),
    'features', jsonb_build_object('pg', to_regclass('public.pg_properties') is not null, 'resort', to_regclass('public.resort_properties') is not null,
      'staff', to_regclass('public.staff_shifts') is not null, 'guide', to_regclass('public.property_guide') is not null));
end $$;

-- ---------------------------------------------------------------- team across branches
create or replace function public.branch_team() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_uid uuid := public._br_assert_owner();
begin
  return (select coalesce(jsonb_agg(t order by t->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('user_id', m.user_id,
             'name', coalesce(max(m.display_name), max(m.email), 'Team member'), 'email', max(m.email),
             'access', jsonb_agg(jsonb_build_object('property_id', m.property_id, 'role', m.role) order by p.created_at)) t
      from public.property_members m join public.properties p on p.id = m.property_id
     where m.property_id in (select public.my_property_ids(array['owner']::public.member_role[]))
       and m.user_id <> v_uid and m.role <> 'owner'
     group by m.user_id) q);
end $$;

-- Give someone who already works at one of your branches access to another one (or take it away).
create or replace function public.branch_access_set(p_user uuid, p_property uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_cur public.member_role; v_name text; v_email text; v_n int;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if p_user is null or p_user = v_uid then raise exception 'Choose a team member.'; end if;
  select count(*), max(display_name), max(email) into v_n, v_name, v_email from public.property_members
   where user_id = p_user and role <> 'owner'
     and property_id in (select public.my_property_ids(array['owner']::public.member_role[]));
  if v_n = 0 then
    raise exception 'This person doesn''t work at any of your branches. Add them first in Settings → Users & roles.';
  end if;
  select role into v_cur from public.property_members where property_id = p_property and user_id = p_user;
  if v_cur = 'owner' then raise exception 'An owner''s access can''t be changed here.'; end if;
  if coalesce(p_role, '') = '' then
    delete from public.property_members where property_id = p_property and user_id = p_user;
    return jsonb_build_object('removed', true);
  end if;
  if p_role not in ('manager','front_desk','accountant') then raise exception 'Choose manager, front desk or accountant.'; end if;
  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (p_property, p_user, p_role::public.member_role, v_name, v_email)
  on conflict (property_id, user_id) do update set role = excluded.role;
  return jsonb_build_object('role', p_role);
end $$;

-- ---------------------------------------------------------------- add a branch
create or replace function public.branch_create(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := public._br_assert_owner();
  v_src   uuid := nullif(p->>'copy_from', '')::uuid;
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_type  text := coalesce(nullif(p->>'kind', ''), 'hostel');
  v_kind  text;
  v_copy  jsonb := coalesce(p->'copy', '[]'::jsonb);
  v_email text; v_owner_name text; v_prefix text; v_prop uuid; v_room uuid; v_n int := 0; v_team int := 0;
  sp public.properties%rowtype; rm record; u record; v_map jsonb := '{}'::jsonb;
begin
  if char_length(v_name) < 2 then raise exception 'Enter the branch name.'; end if;
  if v_type not in ('hostel','hotel','homestay','pg','resort') then raise exception 'Choose the type of property.'; end if;
  if v_type = 'pg' and to_regclass('public.pg_properties') is null then raise exception 'PG / co-living isn''t switched on for your account yet.'; end if;
  if v_type = 'resort' and to_regclass('public.resort_properties') is null then raise exception 'Resorts aren''t switched on for your account yet.'; end if;
  v_kind := case v_type when 'pg' then 'hostel' when 'resort' then 'hotel' else v_type end;
  if jsonb_typeof(v_copy) <> 'array' then raise exception 'Bad copy list.'; end if;

  if (select count(*) from public.property_members where user_id = v_uid and role = 'owner') >= 25 then
    raise exception 'You already have 25 properties. Contact NammaStay support to add more.';
  end if;
  -- each branch gets a free trial, but only two branches can be on an unpaid trial at the same time
  if (select count(*) from public.property_members m join public.subscriptions s on s.property_id = m.property_id
       where m.user_id = v_uid and m.role = 'owner' and s.paid_until is null and not s.is_complimentary
         and public._access_state(m.property_id) = 'trial') >= 2 then
    raise exception 'Two of your branches are still on the free trial. Choose a plan for one of them in Settings → Billing, then add the next branch.';
  end if;
  if exists (select 1 from public.properties x join public.property_members m on m.property_id = x.id
              where m.user_id = v_uid and m.role = 'owner' and lower(x.name) = lower(v_name)) then
    raise exception 'You already have a branch called "%". Use a different name, e.g. add the area.', v_name;
  end if;
  if v_src is not null then
    perform public._assert_role(v_src, array['owner']::public.member_role[]);
    select * into sp from public.properties where id = v_src;
    if v_copy ? 'rooms' and public._br_mode(v_src) <> v_type then
      raise exception 'Rooms and prices can only be copied from a branch of the same type.';
    end if;
  elsif jsonb_array_length(v_copy) > 0 then
    raise exception 'Choose the branch to copy from.';
  end if;

  select email into v_email from auth.users where id = v_uid;
  select display_name into v_owner_name from public.property_members
   where user_id = v_uid and role = 'owner' and display_name is not null order by created_at limit 1;
  v_prefix := upper(btrim(coalesce(p->>'invoice_prefix', '')));
  if v_prefix = '' then v_prefix := public._br_prefix(v_name, v_uid); end if;
  if v_prefix !~ '^[A-Z0-9-]{1,10}$' then raise exception 'Invoice prefix: up to 10 capital letters, numbers or -.'; end if;
  if exists (select 1 from public.properties x join public.property_members m on m.property_id = x.id
              where m.user_id = v_uid and m.role = 'owner' and x.invoice_prefix = v_prefix) then
    raise exception 'Another branch already uses the invoice prefix %. Pick a different one so invoice numbers don''t repeat.', v_prefix;
  end if;

  insert into public.properties (name, kind, city, address, phone, email, invoice_prefix)
  values (left(v_name, 120), v_kind,
          left(nullif(btrim(p->>'city'), ''), 80), left(nullif(btrim(p->>'address'), ''), 300),
          left(coalesce(nullif(btrim(p->>'phone'), ''), sp.phone), 20), v_email, v_prefix)
  returning id into v_prop;                                       -- the existing trigger starts this branch's free trial
  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (v_prop, v_uid, 'owner', v_owner_name, v_email);
  if v_type = 'pg' then execute 'insert into public.pg_properties (property_id) values ($1) on conflict do nothing' using v_prop; end if;
  if v_type = 'resort' then execute 'insert into public.resort_properties (property_id) values ($1) on conflict do nothing' using v_prop; end if;

  if v_src is not null and v_copy ? 'details' then                 -- times, GST, UPI, billing, offers, role permissions
    update public.properties set checkin_time = sp.checkin_time, checkout_time = sp.checkout_time,
      id_doc_retention_days = sp.id_doc_retention_days, upi_id = sp.upi_id, legal_name = sp.legal_name, gstin = sp.gstin,
      gst_mode = sp.gst_mode, gst_rate = sp.gst_rate, extras_gst_rate = sp.extras_gst_rate, offers = sp.offers,
      role_permissions = sp.role_permissions, bill_name = sp.bill_name, bill_gstin = sp.bill_gstin,
      bill_address = sp.bill_address, bill_state = sp.bill_state, timezone = sp.timezone
     where id = v_prop;
  end if;

  if v_src is not null and v_copy ? 'rooms' then                   -- rooms, beds, prices, weekend/season prices, extras
    for rm in select * from public.rooms where property_id = v_src order by sort, name loop
      insert into public.rooms (property_id, name, description, sort) values (v_prop, rm.name, rm.description, rm.sort)
      returning id into v_room;
      v_map := v_map || jsonb_build_object(rm.id::text, v_room);
      insert into public.beds (property_id, room_id, label, position, rate_paise, is_active, sort, max_guests, base_guests, extra_guest_paise)
      select v_prop, v_room, b.label, b.position, b.rate_paise, b.is_active, b.sort, b.max_guests, b.base_guests, b.extra_guest_paise
        from public.beds b where b.room_id = rm.id;
      v_n := v_n + 1;
    end loop;
    insert into public.rate_rules (property_id, name, kind, weekdays, date_from, date_to, adjust, value, room_ids, min_nights, priority, is_active)
    select v_prop, rr.name, rr.kind, rr.weekdays, rr.date_from, rr.date_to, rr.adjust, rr.value,
           case when rr.room_ids is null then null
                else (select array_agg((v_map->>x::text)::uuid) from unnest(rr.room_ids) x where v_map ? x::text) end,
           rr.min_nights, rr.priority, rr.is_active
      from public.rate_rules rr
     where rr.property_id = v_src and rr.name <> 'Smart pricing'                     -- Smart pricing (041) makes its own
       and (rr.room_ids is null or exists (select 1 from unnest(rr.room_ids) x where v_map ? x::text));
    insert into public.extra_items (property_id, name, category, price_paise, unit, is_active, sort)
    select v_prop, name, category, price_paise, unit, is_active, sort from public.extra_items where property_id = v_src;
  end if;

  if v_src is not null and v_copy ? 'guide' and to_regclass('public.property_guide') is not null then   -- not Wi-Fi or directions
    execute $q$insert into public.property_guide (property_id, welcome, house_rules, host_name, host_phone, checkin_info, checkout_info, food_info)
               select $1, welcome, house_rules, host_name, host_phone, checkin_info, checkout_info, food_info
                 from public.property_guide where property_id = $2 on conflict (property_id) do nothing$q$ using v_prop, v_src;
  end if;

  if v_src is not null and v_copy ? 'shifts' and to_regclass('public.staff_shifts') is not null then     -- Staff (042)
    execute $q$insert into public.staff_shifts (property_id, name, starts, ends, sort)
               select $1, name, starts, ends, sort from public.staff_shifts where property_id = $2$q$ using v_prop, v_src;
    execute $q$insert into public.staff_settings (property_id, leave_days_year, late_after_min, managers_see_salary)
               select $1, leave_days_year, late_after_min, managers_see_salary from public.staff_settings where property_id = $2
               on conflict (property_id) do nothing$q$ using v_prop, v_src;
  end if;

  -- team: people who already work at one of your branches, with the role they have there
  for u in select distinct on (m.user_id) m.user_id, m.role, m.display_name, m.email
             from public.property_members m
            where jsonb_typeof(p->'team') = 'array' and m.user_id::text in (select jsonb_array_elements_text(p->'team'))
              and m.role <> 'owner' and m.user_id <> v_uid
              and m.property_id in (select public.my_property_ids(array['owner']::public.member_role[]))
            order by m.user_id, (m.property_id = v_src) desc, case m.role when 'manager' then 1 when 'front_desk' then 2 else 3 end loop
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (v_prop, u.user_id, u.role, u.display_name, u.email) on conflict do nothing;
    v_team := v_team + 1;
  end loop;

  return jsonb_build_object('property_id', v_prop, 'name', v_name, 'invoice_prefix', v_prefix, 'rooms_copied', v_n, 'team_added', v_team,
    'trial_ends_at', (select trial_ends_at from public.subscriptions where property_id = v_prop));
end $$;

-- ---------------------------------------------------------------- permissions
do $$ declare f text; begin
  foreach f in array array['branches_overview()', 'branch_team()', 'branch_access_set(uuid, uuid, text)', 'branch_create(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['_br_mode(uuid)', '_br_assert_owner()', '_br_prefix(text, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

select to_regprocedure('public.branch_create(jsonb)') is not null and to_regprocedure('public.branches_overview()') is not null as branches_installed;

-- NammaStay · 044 · Channex API key saved from the admin screen (no Supabase secrets needed)
-- Additive only: one new table + 4 new functions. Nothing existing is changed.
-- The key is never readable from the website: only the server function (service role) can read it.
-- Run once in Supabase → SQL Editor. Undo: rollback_044_channex_key.sql

create table if not exists public.cx_settings (
  id          boolean primary key default true check (id),        -- exactly one row
  api_key     text,
  base_url    text not null default 'https://staging.channex.io'
              check (base_url in ('https://staging.channex.io', 'https://app.channex.io')),
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
alter table public.cx_settings enable row level security;              -- no policies → no direct access for anyone
revoke all on public.cx_settings from public, anon, authenticated;

-- Admin screen: is a key saved? (never returns the key itself, only the last 4 characters)
create or replace function public.cx_key_status() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.cx_settings;
begin
  perform public._assert_platform_admin();
  select * into r from public.cx_settings where id;
  return jsonb_build_object(
    'set', coalesce(length(r.api_key), 0) > 0,
    'last4', case when length(r.api_key) >= 4 then right(r.api_key, 4) end,
    'base_url', coalesce(r.base_url, 'https://staging.channex.io'),
    'live', coalesce(r.base_url, '') = 'https://app.channex.io',
    'updated_at', r.updated_at);
end $$;

-- Admin screen: save the key and/or switch Test ↔ Live. p_key null = keep the saved key.
create or replace function public.cx_key_save(p_key text, p_live boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text := nullif(btrim(coalesce(p_key, '')), '');
        v_url text := case when p_live then 'https://app.channex.io' else 'https://staging.channex.io' end;
begin
  perform public._assert_platform_admin();
  if v_key is not null and (length(v_key) < 20 or length(v_key) > 300 or v_key ~ '\s') then
    raise exception 'That doesn''t look like a Channex API key. Copy it again from Channex → API keys.' using errcode = '22023';
  end if;
  insert into public.cx_settings (id, api_key, base_url, updated_at, updated_by)
  values (true, v_key, v_url, now(), auth.uid())
  on conflict (id) do update set api_key = coalesce(v_key, public.cx_settings.api_key),
    base_url = v_url, updated_at = now(), updated_by = auth.uid();
  return public.cx_key_status();
end $$;

-- Admin screen: remove the saved key (the server falls back to the CHANNEX_API_KEY secret, if any)
create or replace function public.cx_key_clear() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  update public.cx_settings set api_key = null, updated_at = now(), updated_by = auth.uid() where id;
  return public.cx_key_status();
end $$;

-- Server function only (service role): the saved key + address
create or replace function public._cx_key() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('api_key', api_key, 'base_url', base_url) from public.cx_settings where id
$$;

revoke all on function public.cx_key_status(), public.cx_key_save(text, boolean), public.cx_key_clear(), public._cx_key()
  from public, anon, authenticated;
grant execute on function public.cx_key_status(), public.cx_key_save(text, boolean), public.cx_key_clear() to authenticated;
grant execute on function public._cx_key() to service_role;
