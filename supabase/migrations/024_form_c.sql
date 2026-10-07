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
