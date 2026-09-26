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
