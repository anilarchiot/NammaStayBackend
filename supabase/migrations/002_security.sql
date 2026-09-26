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
