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
