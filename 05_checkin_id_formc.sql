-- =====================================================================
-- NammaStay · checkin id formc
-- Self check-in, ID photos & clean-up, more guests per booking, Form C
-- Exported 16 Oct 2026 from a complete install (updates 001–043), so every function is its latest version.
-- Order: run the files in number order on an EMPTY Supabase project (01 first). To add one feature to a
-- LIVE database, use the matching file from updates/ instead: those are safe to run on top of existing data.
-- =====================================================================
SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: _is_foreign(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._is_foreign(p_nationality text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $_$
  select coalesce(nullif(btrim(p_nationality), ''), 'India') !~* '^(india|indian)$'
$_$;

--
-- Name: booking_guest_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_guest_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.booking_guests where id = p_id;
  if v_prop is null then return; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  delete from public.booking_guests where id = p_id;          -- trigger queues the ID photos for clean-up
end $$;

--
-- Name: booking_guest_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_guest_save(p_booking uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: booking_guests_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_guests_list(p_booking uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: formc_due_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.formc_due_count(p_property uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select count(*)::int from public.bookings b join public.guests g on g.id = b.guest_id left join public.form_c c on c.booking_id = b.id
   where b.property_id = p_property and b.status = 'checked_in' and public._is_foreign(g.nationality) and c.arrival_at is null
     and p_property in (select public.my_property_ids(array['owner','manager','front_desk']::public.member_role[]))
$$;

--
-- Name: formc_list(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.formc_list(p_property uuid, p_days integer DEFAULT 30) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: formc_mark(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.formc_mark(p_booking uuid, p_kind text, p_ref text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: formc_save_details(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.formc_save_details(p_guest uuid, p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: id_docs_due_for_purge(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.id_docs_due_for_purge(p_limit integer DEFAULT 200) RETURNS TABLE(guest_id uuid, path text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: mark_id_doc_purged(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_id_doc_purged(p_guest uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  update public.guests set id_doc_path = null, id_doc_back_path = null where id = p_guest;
  update public.booking_guests set id_doc_path = null, id_doc_back_path = null where id = p_guest;
  delete from public.booking_guest_doc_trash where id = p_guest;
$$;

--
-- Name: selfcheckin_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.selfcheckin_get(p_token uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: selfcheckin_submit(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.selfcheckin_submit(p_token uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_guest_doc_trash; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_guest_doc_trash (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    path text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: booking_guests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_guests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    booking_id uuid NOT NULL,
    full_name text NOT NULL,
    phone text,
    gender text,
    age smallint,
    relation text,
    nationality text,
    id_type public.id_doc_type,
    id_number text,
    id_doc_path text,
    id_doc_back_path text,
    sort smallint DEFAULT 0 NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT booking_guests_age_check CHECK (((age IS NULL) OR ((age >= 0) AND (age <= 120)))),
    CONSTRAINT booking_guests_full_name_check CHECK (((char_length(btrim(full_name)) >= 2) AND (char_length(btrim(full_name)) <= 120))),
    CONSTRAINT booking_guests_gender_check CHECK (((gender IS NULL) OR (gender = ANY (ARRAY['male'::text, 'female'::text, 'other'::text])))),
    CONSTRAINT booking_guests_id_number_check CHECK ((char_length(id_number) <= 40)),
    CONSTRAINT booking_guests_nationality_check CHECK ((char_length(nationality) <= 60)),
    CONSTRAINT booking_guests_phone_check CHECK (((phone IS NULL) OR (phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT booking_guests_relation_check CHECK ((char_length(relation) <= 40))
);

--
-- Name: form_c; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.form_c (
    booking_id uuid NOT NULL,
    property_id uuid NOT NULL,
    arrival_ref text,
    arrival_at timestamp with time zone,
    arrival_by uuid,
    departure_ref text,
    departure_at timestamp with time zone,
    departure_by uuid,
    CONSTRAINT form_c_arrival_ref_check CHECK ((char_length(arrival_ref) <= 60)),
    CONSTRAINT form_c_departure_ref_check CHECK ((char_length(departure_ref) <= 60))
);

--
-- Name: guest_foreign; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guest_foreign (
    guest_id uuid NOT NULL,
    property_id uuid NOT NULL,
    gender text,
    passport_no text,
    passport_place text,
    passport_issued date,
    passport_expiry date,
    visa_no text,
    visa_type text,
    visa_subtype text,
    visa_place text,
    visa_issued date,
    visa_expiry date,
    arrived_india_on date,
    arrived_from text,
    next_destination text,
    purpose text,
    home_address text,
    contact_india text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT guest_foreign_arrived_from_check CHECK ((char_length(arrived_from) <= 80)),
    CONSTRAINT guest_foreign_contact_india_check CHECK ((char_length(contact_india) <= 40)),
    CONSTRAINT guest_foreign_gender_check CHECK ((gender = ANY (ARRAY['male'::text, 'female'::text, 'other'::text]))),
    CONSTRAINT guest_foreign_home_address_check CHECK ((char_length(home_address) <= 300)),
    CONSTRAINT guest_foreign_next_destination_check CHECK ((char_length(next_destination) <= 120)),
    CONSTRAINT guest_foreign_passport_no_check CHECK ((char_length(passport_no) <= 30)),
    CONSTRAINT guest_foreign_passport_place_check CHECK ((char_length(passport_place) <= 80)),
    CONSTRAINT guest_foreign_purpose_check CHECK ((char_length(purpose) <= 60)),
    CONSTRAINT guest_foreign_visa_no_check CHECK ((char_length(visa_no) <= 40)),
    CONSTRAINT guest_foreign_visa_place_check CHECK ((char_length(visa_place) <= 80)),
    CONSTRAINT guest_foreign_visa_subtype_check CHECK ((char_length(visa_subtype) <= 60)),
    CONSTRAINT guest_foreign_visa_type_check CHECK ((char_length(visa_type) <= 40))
);

--
-- Name: booking_guest_doc_trash booking_guest_doc_trash_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_guest_doc_trash
    ADD CONSTRAINT booking_guest_doc_trash_pkey PRIMARY KEY (id);

--
-- Name: booking_guests booking_guests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_guests
    ADD CONSTRAINT booking_guests_pkey PRIMARY KEY (id);

--
-- Name: form_c form_c_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_c
    ADD CONSTRAINT form_c_pkey PRIMARY KEY (booking_id);

--
-- Name: guest_foreign guest_foreign_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_foreign
    ADD CONSTRAINT guest_foreign_pkey PRIMARY KEY (guest_id);

--
-- Name: booking_guests_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_guests_booking ON public.booking_guests USING btree (booking_id, sort, created_at);

--
-- Name: booking_guests_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_guests_property ON public.booking_guests USING btree (property_id);

--
-- Name: booking_guests booking_guests_trash; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER booking_guests_trash AFTER DELETE ON public.booking_guests FOR EACH ROW EXECUTE FUNCTION public._booking_guest_trash();

--
-- Name: booking_guests booking_guests_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_guests
    ADD CONSTRAINT booking_guests_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: form_c form_c_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.form_c
    ADD CONSTRAINT form_c_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: guest_foreign guest_foreign_guest_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_foreign
    ADD CONSTRAINT guest_foreign_guest_id_property_id_fkey FOREIGN KEY (guest_id, property_id) REFERENCES public.guests(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_guest_doc_trash; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_guest_doc_trash ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_guests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_guests ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_guests booking_guests_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_guests_select ON public.booking_guests FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: form_c; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.form_c ENABLE ROW LEVEL SECURITY;

--
-- Name: form_c form_c_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY form_c_select ON public.form_c FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids)));

--
-- Name: guest_foreign; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guest_foreign ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_foreign guest_foreign_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_foreign_select ON public.guest_foreign FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids)));

--
-- Name: FUNCTION _is_foreign(p_nationality text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._is_foreign(p_nationality text) FROM PUBLIC;

--
-- Name: FUNCTION booking_guest_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_guest_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_guest_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION booking_guest_save(p_booking uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_guest_save(p_booking uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_guest_save(p_booking uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION booking_guests_list(p_booking uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_guests_list(p_booking uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_guests_list(p_booking uuid) TO authenticated;

--
-- Name: FUNCTION formc_due_count(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.formc_due_count(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.formc_due_count(p_property uuid) TO authenticated;

--
-- Name: FUNCTION formc_list(p_property uuid, p_days integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.formc_list(p_property uuid, p_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.formc_list(p_property uuid, p_days integer) TO authenticated;

--
-- Name: FUNCTION formc_mark(p_booking uuid, p_kind text, p_ref text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.formc_mark(p_booking uuid, p_kind text, p_ref text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.formc_mark(p_booking uuid, p_kind text, p_ref text) TO authenticated;

--
-- Name: FUNCTION formc_save_details(p_guest uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.formc_save_details(p_guest uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.formc_save_details(p_guest uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION id_docs_due_for_purge(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.id_docs_due_for_purge(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.id_docs_due_for_purge(p_limit integer) TO service_role;

--
-- Name: FUNCTION mark_id_doc_purged(p_guest uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.mark_id_doc_purged(p_guest uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_id_doc_purged(p_guest uuid) TO service_role;

--
-- Name: FUNCTION selfcheckin_get(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.selfcheckin_get(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.selfcheckin_get(p_token uuid) TO anon;
GRANT ALL ON FUNCTION public.selfcheckin_get(p_token uuid) TO authenticated;

--
-- Name: FUNCTION selfcheckin_submit(p_token uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.selfcheckin_submit(p_token uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.selfcheckin_submit(p_token uuid, p jsonb) TO anon;
GRANT ALL ON FUNCTION public.selfcheckin_submit(p_token uuid, p jsonb) TO authenticated;

--
-- Name: TABLE booking_guests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.booking_guests TO authenticated;

--
-- Name: TABLE form_c; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.form_c TO authenticated;

--
-- Name: TABLE guest_foreign; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.guest_foreign TO authenticated;

-- ---------------------------------------------------------------- storage, realtime & default rows
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values ('guest-ids', 'guest-ids', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf']) on conflict (id) do nothing;

drop policy if exists "guest-ids: guest self check-in upload" on storage.objects;
create policy "guest-ids: guest self check-in upload" on storage.objects for insert to anon
  with check (((bucket_id = 'guest-ids'::text) AND public.checkin_upload_allowed(name)));

drop policy if exists "guest-ids: staff delete" on storage.objects;
create policy "guest-ids: staff delete" on storage.objects for delete to authenticated
  using (((bucket_id = 'guest-ids'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));

drop policy if exists "guest-ids: staff read" on storage.objects;
create policy "guest-ids: staff read" on storage.objects for select to authenticated
  using (((bucket_id = 'guest-ids'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));

drop policy if exists "guest-ids: staff upload" on storage.objects;
create policy "guest-ids: staff upload" on storage.objects for insert to authenticated
  with check (((bucket_id = 'guest-ids'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));
