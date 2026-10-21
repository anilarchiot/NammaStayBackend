-- =====================================================================
-- NammaStay · guests bookings calendar
-- Guests, bookings, calendar, dashboard, delete booking
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
-- Name: booking_code_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.booking_code_seq
    START WITH 1001
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bookings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    code text DEFAULT ('BK-'::text || nextval('public.booking_code_seq'::regclass)) NOT NULL,
    guest_id uuid NOT NULL,
    bed_id uuid NOT NULL,
    visitors smallint DEFAULT 1 NOT NULL,
    check_in_at timestamp with time zone NOT NULL,
    check_out_at timestamp with time zone NOT NULL,
    stay tstzrange GENERATED ALWAYS AS (tstzrange(check_in_at, check_out_at, '[)'::text)) STORED,
    nights smallint NOT NULL,
    rate_paise integer NOT NULL,
    total_paise integer NOT NULL,
    paid_paise integer DEFAULT 0 NOT NULL,
    balance_paise integer GENERATED ALWAYS AS ((total_paise - paid_paise)) STORED,
    status public.booking_status DEFAULT 'pending'::public.booking_status NOT NULL,
    source public.booking_source DEFAULT 'walk_in'::public.booking_source NOT NULL,
    note text,
    send_confirmation boolean DEFAULT false NOT NULL,
    self_checkin_token uuid DEFAULT gen_random_uuid() NOT NULL,
    self_checkin_at timestamp with time zone,
    self_checkin_count smallint DEFAULT 0 NOT NULL,
    arrived_at timestamp with time zone,
    departed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    children smallint DEFAULT 0 NOT NULL,
    extra_paise integer DEFAULT 0 NOT NULL,
    charges_paise integer DEFAULT 0 NOT NULL,
    discount_pct numeric(5,2) DEFAULT 0 NOT NULL,
    discount_paise integer DEFAULT 0 NOT NULL,
    CONSTRAINT bookings_charges_paise_check CHECK ((charges_paise >= 0)),
    CONSTRAINT bookings_check CHECK ((check_out_at > check_in_at)),
    CONSTRAINT bookings_check1 CHECK (((check_out_at - check_in_at) <= '367 days'::interval)),
    CONSTRAINT bookings_children_check CHECK (((children >= 0) AND (children <= 20))),
    CONSTRAINT bookings_discount_paise_check CHECK ((discount_paise >= 0)),
    CONSTRAINT bookings_discount_pct_check CHECK (((discount_pct >= (0)::numeric) AND (discount_pct <= (100)::numeric))),
    CONSTRAINT bookings_extra_paise_check CHECK ((extra_paise >= 0)),
    CONSTRAINT bookings_nights_check CHECK (((nights >= 1) AND (nights <= 366))),
    CONSTRAINT bookings_note_check CHECK ((char_length(note) <= 2000)),
    CONSTRAINT bookings_paid_paise_check CHECK ((paid_paise >= 0)),
    CONSTRAINT bookings_rate_paise_check CHECK ((rate_paise >= 0)),
    CONSTRAINT bookings_total_paise_check CHECK ((total_paise >= 0)),
    CONSTRAINT bookings_visitors_check CHECK (((visitors >= 1) AND (visitors <= 20)))
);

--
-- Name: _check_dob(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._check_dob(p_dob date) RETURNS void
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if p_dob is null then return; end if;
  if p_dob > current_date then raise exception 'Date of birth can''t be in the future.'; end if;
  if p_dob < current_date - interval '120 years' then raise exception 'Please check the date of birth.'; end if;
end $$;

--
-- Name: _clean_phone(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._clean_phone(p text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare d text;
begin
  if p is null or btrim(p) = '' then return null; end if;
  d := regexp_replace(p, '[^0-9]', '', 'g');
  if btrim(p) like '+%' then return '+' || d; end if;
  if length(d) = 10 then return '+91' || d; end if;
  if length(d) = 12 and d like '91%' then return '+' || d; end if;
  return d;
end $$;

--
-- Name: _mask_id(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._mask_id(p_type text, p_num text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_action(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_action(p_booking uuid, p_action text, p_force boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_detail(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_detail(p_booking uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_status_counts(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_status_counts(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status, count(*) n from public.bookings
           where property_id = p_property and check_out_at >= now() - interval '30 days'
           group by status) s;
  return v || jsonb_build_object('all', (select coalesce(sum(value::int), 0) from jsonb_each_text(v)));
end $$;

--
-- Name: calendar_range(uuid, date, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calendar_range(p_property uuid, p_from date, p_days integer DEFAULT 9) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: create_booking(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_booking(p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: dashboard_summary(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dashboard_summary(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: delete_booking(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_booking(p_booking uuid, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: delete_guest(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_guest(p_guest uuid, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: guest_profile(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guest_profile(p_guest uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: list_bookings(uuid, text, text, timestamp with time zone, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_bookings(p_property uuid, p_status text DEFAULT NULL::text, p_q text DEFAULT NULL::text, p_cursor_check_in timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 30) RETURNS TABLE(id uuid, code text, guest_id uuid, guest_name text, guest_phone text, room_name text, bed_label text, check_in_at timestamp with time zone, check_out_at timestamp with time zone, total_paise integer, paid_paise integer, balance_paise integer, status public.booking_status, source public.booking_source)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: list_deleted_bookings(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_deleted_bookings(p_property uuid, p_limit integer DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: occupancy_series(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.occupancy_series(p_property uuid, p_from date, p_to date) RETURNS TABLE(day date, occupied integer, total integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: search_guests(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_guests(p_property uuid, p_q text) RETURNS TABLE(id uuid, full_name text, phone text, email text, nationality text, last_check_in timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: set_booking_discount(uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_booking_discount(p_booking uuid, p_pct numeric) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: update_booking(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_booking(p_booking uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: update_guest(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_guest(p_guest uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: guests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    full_name text NOT NULL,
    phone text,
    email text,
    dob date,
    nationality text,
    id_type public.id_doc_type,
    id_number text,
    id_doc_path text,
    notes text,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    consent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    id_doc_back_path text,
    CONSTRAINT guests_dob_check CHECK (((dob IS NULL) OR (dob > '1900-01-01'::date))),
    CONSTRAINT guests_email_check CHECK (((email IS NULL) OR (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text))),
    CONSTRAINT guests_full_name_check CHECK (((char_length(btrim(full_name)) >= 2) AND (char_length(btrim(full_name)) <= 120))),
    CONSTRAINT guests_id_number_check CHECK ((char_length(id_number) <= 40)),
    CONSTRAINT guests_nationality_check CHECK ((char_length(nationality) <= 60)),
    CONSTRAINT guests_notes_check CHECK ((char_length(notes) <= 2000)),
    CONSTRAINT guests_phone_check CHECK (((phone IS NULL) OR (phone ~ '^\+?[0-9]{8,15}$'::text)))
);

--
-- Name: bookings bookings_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_code_key UNIQUE (code);

--
-- Name: bookings bookings_id_property_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_id_property_id_key UNIQUE (id, property_id);

--
-- Name: bookings bookings_no_double_booking; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_no_double_booking EXCLUDE USING gist (bed_id WITH =, stay WITH &&) WHERE ((status = ANY (ARRAY['pending'::public.booking_status, 'confirmed'::public.booking_status, 'checked_in'::public.booking_status])));

--
-- Name: bookings bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);

--
-- Name: bookings bookings_self_checkin_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_self_checkin_token_key UNIQUE (self_checkin_token);

--
-- Name: guests guests_id_property_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests
    ADD CONSTRAINT guests_id_property_id_key UNIQUE (id, property_id);

--
-- Name: guests guests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests
    ADD CONSTRAINT guests_pkey PRIMARY KEY (id);

--
-- Name: bookings_checkout; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookings_checkout ON public.bookings USING btree (property_id, check_out_at);

--
-- Name: bookings_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookings_due ON public.bookings USING btree (property_id) WHERE ((balance_paise > 0) AND (status = ANY (ARRAY['checked_in'::public.booking_status, 'checked_out'::public.booking_status])));

--
-- Name: bookings_guest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookings_guest ON public.bookings USING btree (guest_id, check_in_at DESC);

--
-- Name: bookings_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookings_list ON public.bookings USING btree (property_id, check_in_at DESC, id DESC);

--
-- Name: bookings_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookings_status ON public.bookings USING btree (property_id, status, check_in_at DESC);

--
-- Name: bookings_stay; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookings_stay ON public.bookings USING gist (property_id, stay);

--
-- Name: guests_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX guests_name_trgm ON public.guests USING gin (full_name extensions.gin_trgm_ops);

--
-- Name: guests_phone_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX guests_phone_trgm ON public.guests USING gin (phone extensions.gin_trgm_ops);

--
-- Name: guests_property_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX guests_property_created ON public.guests USING btree (property_id, created_at DESC);

--
-- Name: guests_property_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX guests_property_phone ON public.guests USING btree (property_id, phone);

--
-- Name: bookings bookings_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bookings_audit AFTER INSERT OR UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._bookings_audit();

--
-- Name: bookings bookings_hk_checkout; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bookings_hk_checkout AFTER UPDATE OF status ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._hk_on_checkout();

--
-- Name: bookings bookings_rate_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bookings_rate_rules BEFORE INSERT OR UPDATE OF check_in_at, check_out_at, bed_id ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._apply_rate_rules();

--
-- Name: bookings bookings_require_access; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bookings_require_access BEFORE INSERT ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._require_access();

--
-- Name: bookings bookings_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bookings_touch BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

--
-- Name: bookings cx_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cx_touch AFTER INSERT OR DELETE OR UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._cx_touch();

--
-- Name: guests guests_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guests_touch BEFORE UPDATE ON public.guests FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

--
-- Name: bookings perm_bookings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perm_bookings BEFORE DELETE OR UPDATE OF status ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._perm_bookings();

--
-- Name: guests perm_guests; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perm_guests BEFORE DELETE ON public.guests FOR EACH ROW EXECUTE FUNCTION public._perm_guests();

--
-- Name: bookings zz_pg_tenant_booking; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_pg_tenant_booking BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION public._pg_keep_tenant_booking();

--
-- Name: bookings bookings_bed_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_bed_id_property_id_fkey FOREIGN KEY (bed_id, property_id) REFERENCES public.beds(id, property_id) ON DELETE RESTRICT;

--
-- Name: bookings bookings_guest_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_guest_id_property_id_fkey FOREIGN KEY (guest_id, property_id) REFERENCES public.guests(id, property_id) ON DELETE RESTRICT;

--
-- Name: bookings bookings_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: guests guests_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests
    ADD CONSTRAINT guests_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: bookings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

--
-- Name: bookings bookings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bookings_select ON public.bookings FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: guests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guests ENABLE ROW LEVEL SECURITY;

--
-- Name: guests guests_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guests_select ON public.guests FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids)));

--
-- Name: guests guests_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guests_update ON public.guests FOR UPDATE TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids))) WITH CHECK ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids)));

--
-- Name: TABLE bookings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.bookings TO authenticated;

--
-- Name: FUNCTION _check_dob(p_dob date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._check_dob(p_dob date) FROM PUBLIC;

--
-- Name: FUNCTION _clean_phone(p text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._clean_phone(p text) FROM PUBLIC;

--
-- Name: FUNCTION _mask_id(p_type text, p_num text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._mask_id(p_type text, p_num text) FROM PUBLIC;

--
-- Name: FUNCTION booking_action(p_booking uuid, p_action text, p_force boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_action(p_booking uuid, p_action text, p_force boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_action(p_booking uuid, p_action text, p_force boolean) TO authenticated;

--
-- Name: FUNCTION booking_detail(p_booking uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_detail(p_booking uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_detail(p_booking uuid) TO authenticated;

--
-- Name: FUNCTION booking_status_counts(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_status_counts(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_status_counts(p_property uuid) TO authenticated;

--
-- Name: FUNCTION calendar_range(p_property uuid, p_from date, p_days integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.calendar_range(p_property uuid, p_from date, p_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.calendar_range(p_property uuid, p_from date, p_days integer) TO authenticated;

--
-- Name: FUNCTION create_booking(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_booking(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_booking(p jsonb) TO authenticated;

--
-- Name: FUNCTION dashboard_summary(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dashboard_summary(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dashboard_summary(p_property uuid) TO authenticated;

--
-- Name: FUNCTION delete_booking(p_booking uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_booking(p_booking uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_booking(p_booking uuid, p_reason text) TO authenticated;

--
-- Name: FUNCTION delete_guest(p_guest uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_guest(p_guest uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_guest(p_guest uuid, p_reason text) TO authenticated;

--
-- Name: FUNCTION guest_profile(p_guest uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guest_profile(p_guest uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.guest_profile(p_guest uuid) TO authenticated;

--
-- Name: FUNCTION list_bookings(p_property uuid, p_status text, p_q text, p_cursor_check_in timestamp with time zone, p_cursor_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_bookings(p_property uuid, p_status text, p_q text, p_cursor_check_in timestamp with time zone, p_cursor_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_bookings(p_property uuid, p_status text, p_q text, p_cursor_check_in timestamp with time zone, p_cursor_id uuid, p_limit integer) TO authenticated;

--
-- Name: FUNCTION list_deleted_bookings(p_property uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_deleted_bookings(p_property uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_deleted_bookings(p_property uuid, p_limit integer) TO authenticated;

--
-- Name: FUNCTION occupancy_series(p_property uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.occupancy_series(p_property uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.occupancy_series(p_property uuid, p_from date, p_to date) TO authenticated;

--
-- Name: FUNCTION search_guests(p_property uuid, p_q text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.search_guests(p_property uuid, p_q text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_guests(p_property uuid, p_q text) TO authenticated;

--
-- Name: FUNCTION set_booking_discount(p_booking uuid, p_pct numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_booking_discount(p_booking uuid, p_pct numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_booking_discount(p_booking uuid, p_pct numeric) TO authenticated;

--
-- Name: FUNCTION update_booking(p_booking uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_booking(p_booking uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_booking(p_booking uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION update_guest(p_guest uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_guest(p_guest uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_guest(p_guest uuid, p jsonb) TO authenticated;

--
-- Name: TABLE guests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.guests TO authenticated;

--
-- Name: COLUMN guests.full_name; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(full_name) ON TABLE public.guests TO authenticated;

--
-- Name: COLUMN guests.phone; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(phone) ON TABLE public.guests TO authenticated;

--
-- Name: COLUMN guests.email; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(email) ON TABLE public.guests TO authenticated;

--
-- Name: COLUMN guests.dob; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(dob) ON TABLE public.guests TO authenticated;

--
-- Name: COLUMN guests.nationality; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(nationality) ON TABLE public.guests TO authenticated;

--
-- Name: COLUMN guests.notes; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(notes) ON TABLE public.guests TO authenticated;

--
-- Name: COLUMN guests.tags; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(tags) ON TABLE public.guests TO authenticated;
