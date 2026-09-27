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
