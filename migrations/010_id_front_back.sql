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
