-- =====================================================================
-- NammaStay · resort
-- Resort: activities & spa, day-out visitors, stay packages, groups, extra beds
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
-- Name: day_visits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.day_visits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    code text NOT NULL,
    visit_date date NOT NULL,
    guest_name text NOT NULL,
    phone text,
    adults smallint DEFAULT 1 NOT NULL,
    children smallint DEFAULT 0 NOT NULL,
    package_id uuid,
    package_name text NOT NULL,
    lunch boolean DEFAULT false NOT NULL,
    package_paise integer DEFAULT 0 NOT NULL,
    extras_paise integer DEFAULT 0 NOT NULL,
    paid_paise integer DEFAULT 0 NOT NULL,
    status text DEFAULT 'booked'::text NOT NULL,
    note text,
    arrived_at timestamp with time zone,
    left_at timestamp with time zone,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT day_visits_adults_check CHECK (((adults >= 1) AND (adults <= 500))),
    CONSTRAINT day_visits_children_check CHECK (((children >= 0) AND (children <= 500))),
    CONSTRAINT day_visits_extras_paise_check CHECK ((extras_paise >= 0)),
    CONSTRAINT day_visits_guest_name_check CHECK (((char_length(btrim(guest_name)) >= 2) AND (char_length(btrim(guest_name)) <= 120))),
    CONSTRAINT day_visits_note_check CHECK ((char_length(note) <= 500)),
    CONSTRAINT day_visits_package_paise_check CHECK ((package_paise >= 0)),
    CONSTRAINT day_visits_paid_paise_check CHECK ((paid_paise >= 0)),
    CONSTRAINT day_visits_phone_check CHECK (((phone IS NULL) OR (phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT day_visits_status_check CHECK ((status = ANY (ARRAY['booked'::text, 'arrived'::text, 'left'::text, 'cancelled'::text, 'no_show'::text])))
);

--
-- Name: _dv_row(public.day_visits); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._dv_row(dv public.day_visits) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'other'::text NOT NULL,
    contact_name text,
    contact_phone text,
    event_date date,
    note text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT booking_groups_contact_name_check CHECK ((char_length(contact_name) <= 120)),
    CONSTRAINT booking_groups_contact_phone_check CHECK (((contact_phone IS NULL) OR (contact_phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT booking_groups_kind_check CHECK ((kind = ANY (ARRAY['wedding'::text, 'corporate'::text, 'family'::text, 'school'::text, 'tour'::text, 'other'::text]))),
    CONSTRAINT booking_groups_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 80))),
    CONSTRAINT booking_groups_note_check CHECK ((char_length(note) <= 1000))
);

--
-- Name: _grp_row(public.booking_groups); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._grp_row(g public.booking_groups) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: _rs_is_resort(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._rs_is_resort(p_property uuid) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if not exists (select 1 from public.resort_properties where property_id = p_property) then
    raise exception 'This is for resorts. Set the property type to Resort in Settings.';
  end if;
end $$;

--
-- Name: _rs_pay(public.day_visits, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._rs_pay(dv public.day_visits, p jsonb, p_kind text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: _rs_room_paise(public.bookings); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._rs_room_paise(b public.bookings) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
  select greatest(0, b.total_paise - coalesce(b.charges_paise, 0))
$$;

--
-- Name: _rs_rupees(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._rs_rupees(p integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select '₹' || to_char(p / 100.0, 'FM99,99,99,990')
$$;

--
-- Name: _rs_today(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._rs_today(p_property uuid) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (now() at time zone public._tz(p_property))::date
$$;

--
-- Name: _rs_view(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._rs_view(p_property uuid) RETURNS void
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[])
$$;

--
-- Name: stay_packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stay_packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    nights smallint DEFAULT 1 NOT NULL,
    price_paise integer NOT NULL,
    base_guests smallint DEFAULT 2 NOT NULL,
    extra_adult_paise integer DEFAULT 0 NOT NULL,
    child_paise integer DEFAULT 0 NOT NULL,
    meal_plan_id uuid,
    activity_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    includes text,
    is_active boolean DEFAULT true NOT NULL,
    sort smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stay_packages_base_guests_check CHECK (((base_guests >= 1) AND (base_guests <= 20))),
    CONSTRAINT stay_packages_child_paise_check CHECK (((child_paise >= 0) AND (child_paise <= 10000000))),
    CONSTRAINT stay_packages_extra_adult_paise_check CHECK (((extra_adult_paise >= 0) AND (extra_adult_paise <= 10000000))),
    CONSTRAINT stay_packages_includes_check CHECK ((char_length(includes) <= 500)),
    CONSTRAINT stay_packages_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 60))),
    CONSTRAINT stay_packages_nights_check CHECK (((nights >= 1) AND (nights <= 30))),
    CONSTRAINT stay_packages_price_paise_check CHECK (((price_paise >= 0) AND (price_paise <= 100000000)))
);

--
-- Name: activities_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activities_list(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'category', category, 'duration_min', duration_min,
      'price_paise', price_paise, 'child_paise', child_paise, 'capacity', capacity, 'slots', to_jsonb(slots), 'is_active', is_active)
      order by sort, created_at) from public.activities where property_id = p_property), '[]'::jsonb);
end $$;

--
-- Name: activity_book(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activity_book(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: activity_booking_status(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activity_booking_status(p_id uuid, p_status text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: activity_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activity_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: activity_guests(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activity_guests(p_property uuid, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: activity_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activity_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: activity_schedule(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activity_schedule(p_property uuid, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_extra_beds_set(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_extra_beds_set(p_booking uuid, p_beds integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_package_set(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_package_set(p_booking uuid, p_package uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: booking_resort_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_resort_get(p_booking uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: day_visit_pay(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.day_visit_pay(p_id uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare dv public.day_visits;
begin
  select * into dv from public.day_visits where id = p_id for update;
  if dv.id is null then raise exception 'Day visit not found.'; end if;
  perform public._assert_role(dv.property_id, case when coalesce(p->>'kind', 'payment') = 'refund'
    then array['owner','manager']::public.member_role[] else array['owner','manager','front_desk','accountant']::public.member_role[] end);
  if coalesce(p->>'kind', 'payment') = 'payment' and dv.status in ('cancelled','no_show') then raise exception 'This day visit was cancelled.'; end if;
  return public._rs_pay(dv, p, case when p->>'kind' = 'refund' then 'refund' else 'payment' end);
end $$;

--
-- Name: day_visit_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.day_visit_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: day_visit_status(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.day_visit_status(p_id uuid, p_status text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: day_visits_list(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.day_visits_list(p_property uuid, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: dayout_package_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dayout_package_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.dayout_packages where id = p_id;
  if v_prop is null then raise exception 'Day package not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.dayout_packages where id = p_id;                 -- visits keep the package name and price
end $$;

--
-- Name: dayout_package_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dayout_package_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: dayout_packages_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dayout_packages_list(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'includes', includes, 'lunch', lunch, 'adult_paise', adult_paise,
      'child_paise', child_paise, 'capacity', capacity, 'is_active', is_active) order by sort, created_at)
    from public.dayout_packages where property_id = p_property), '[]'::jsonb);
end $$;

--
-- Name: group_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.group_delete(p_group uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.booking_groups where id = p_group;
  if v_prop is null then raise exception 'Group not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.booking_groups where id = p_group;               -- the bookings themselves stay
end $$;

--
-- Name: group_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.group_get(p_group uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: group_pay(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.group_pay(p_group uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: group_remove_booking(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.group_remove_booking(p_booking uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.booking_group_members where booking_id = p_booking;
  if v_prop is null then return; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  delete from public.booking_group_members where booking_id = p_booking;
end $$;

--
-- Name: group_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.group_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: groups_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.groups_list(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(public._grp_row(g) order by g.created_at desc) from public.booking_groups g where g.property_id = p_property), '[]'::jsonb);
end $$;

--
-- Name: resort_income(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resort_income(p_property uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: resort_mode(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resort_mode(p_property uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select exists (select 1 from public.resort_properties where property_id = p_property)
     and exists (select 1 from public.property_members where property_id = p_property and user_id = auth.uid())
$$;

--
-- Name: resort_set_mode(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resort_set_mode(p_property uuid, p_on boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: resort_settings_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resort_settings_get(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_build_object('extra_bed_paise', extra_bed_paise, 'extra_bed_max', extra_bed_max)
                     from public.resort_settings where property_id = p_property), jsonb_build_object('extra_bed_paise', 0, 'extra_bed_max', 1));
end $$;

--
-- Name: resort_settings_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resort_settings_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_price int := coalesce(nullif(p->>'extra_bed_paise', '')::int, 0); v_max int := coalesce(nullif(p->>'extra_bed_max', '')::int, 1);
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if v_price < 0 or v_price > 10000000 then raise exception 'Enter an extra-bed price between ₹0 and ₹1,00,000.'; end if;
  if v_max < 0 or v_max > 6 then raise exception 'Up to 6 extra beds per room.'; end if;
  insert into public.resort_settings (property_id, extra_bed_paise, extra_bed_max) values (p_property, v_price, v_max)
  on conflict (property_id) do update set extra_bed_paise = excluded.extra_bed_paise, extra_bed_max = excluded.extra_bed_max, updated_at = now();
  return jsonb_build_object('extra_bed_paise', v_price, 'extra_bed_max', v_max);
end $$;

--
-- Name: resort_today(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resort_today(p_property uuid, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: stay_package_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stay_package_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.stay_packages where id = p_id;
  if v_prop is null then raise exception 'Package not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.stay_packages where id = p_id;                   -- bookings keep their package line
end $$;

--
-- Name: stay_package_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stay_package_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: stay_packages_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stay_packages_list(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._rs_view(p_property);
  return coalesce((select jsonb_agg(jsonb_build_object('id', sp.id, 'name', sp.name, 'nights', sp.nights, 'price_paise', sp.price_paise,
      'base_guests', sp.base_guests, 'extra_adult_paise', sp.extra_adult_paise, 'child_paise', sp.child_paise, 'meal_plan_id', sp.meal_plan_id,
      'meal_plan', (select name from public.meal_plans where id = sp.meal_plan_id), 'activity_ids', to_jsonb(sp.activity_ids),
      'activities', (select coalesce(jsonb_agg(a.name order by a.sort), '[]'::jsonb) from public.activities a where a.id = any (sp.activity_ids)),
      'includes', sp.includes, 'is_active', sp.is_active) order by sp.sort, sp.created_at)
    from public.stay_packages sp where sp.property_id = p_property), '[]'::jsonb);
end $$;

--
-- Name: activities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    category text DEFAULT 'leisure'::text NOT NULL,
    duration_min smallint DEFAULT 60 NOT NULL,
    price_paise integer DEFAULT 0 NOT NULL,
    child_paise integer DEFAULT 0 NOT NULL,
    capacity smallint DEFAULT 0 NOT NULL,
    slots text[] DEFAULT '{}'::text[] NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT activities_capacity_check CHECK (((capacity >= 0) AND (capacity <= 500))),
    CONSTRAINT activities_category_check CHECK ((category = ANY (ARRAY['spa'::text, 'adventure'::text, 'leisure'::text, 'kids'::text, 'food'::text, 'other'::text]))),
    CONSTRAINT activities_child_paise_check CHECK (((child_paise >= 0) AND (child_paise <= 10000000))),
    CONSTRAINT activities_duration_min_check CHECK (((duration_min >= 5) AND (duration_min <= 1440))),
    CONSTRAINT activities_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 60))),
    CONSTRAINT activities_price_paise_check CHECK (((price_paise >= 0) AND (price_paise <= 10000000)))
);

--
-- Name: activity_bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_bookings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    activity_id uuid,
    activity_name text NOT NULL,
    day date NOT NULL,
    slot text NOT NULL,
    booking_id uuid,
    day_visit_id uuid,
    guest_name text NOT NULL,
    persons smallint DEFAULT 1 NOT NULL,
    children smallint DEFAULT 0 NOT NULL,
    amount_paise integer DEFAULT 0 NOT NULL,
    included boolean DEFAULT false NOT NULL,
    status text DEFAULT 'booked'::text NOT NULL,
    charge_id uuid,
    note text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT activity_bookings_amount_paise_check CHECK ((amount_paise >= 0)),
    CONSTRAINT activity_bookings_check CHECK (((booking_id IS NOT NULL) OR (day_visit_id IS NOT NULL))),
    CONSTRAINT activity_bookings_check1 CHECK (((persons + children) >= 1)),
    CONSTRAINT activity_bookings_children_check CHECK (((children >= 0) AND (children <= 500))),
    CONSTRAINT activity_bookings_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT activity_bookings_persons_check CHECK (((persons >= 0) AND (persons <= 500))),
    CONSTRAINT activity_bookings_slot_check CHECK ((slot ~ '^[0-2][0-9]:[0-5][0-9]$'::text)),
    CONSTRAINT activity_bookings_status_check CHECK ((status = ANY (ARRAY['booked'::text, 'done'::text, 'cancelled'::text, 'no_show'::text])))
);

--
-- Name: booking_extra_beds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_extra_beds (
    booking_id uuid NOT NULL,
    property_id uuid NOT NULL,
    beds smallint NOT NULL,
    price_paise integer NOT NULL,
    nights smallint NOT NULL,
    charge_id uuid,
    CONSTRAINT booking_extra_beds_beds_check CHECK (((beds >= 1) AND (beds <= 6)))
);

--
-- Name: booking_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_group_members (
    booking_id uuid NOT NULL,
    group_id uuid NOT NULL,
    property_id uuid NOT NULL
);

--
-- Name: booking_packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_packages (
    booking_id uuid NOT NULL,
    property_id uuid NOT NULL,
    package_id uuid,
    package_name text NOT NULL,
    price_paise integer NOT NULL,
    room_paise integer NOT NULL,
    charge_id uuid,
    activity_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: day_visit_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.day_visit_seq
    START WITH 1001
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: dayout_packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dayout_packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    includes text,
    lunch boolean DEFAULT false NOT NULL,
    adult_paise integer DEFAULT 0 NOT NULL,
    child_paise integer DEFAULT 0 NOT NULL,
    capacity smallint DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT dayout_packages_adult_paise_check CHECK (((adult_paise >= 0) AND (adult_paise <= 10000000))),
    CONSTRAINT dayout_packages_capacity_check CHECK (((capacity >= 0) AND (capacity <= 2000))),
    CONSTRAINT dayout_packages_child_paise_check CHECK (((child_paise >= 0) AND (child_paise <= 10000000))),
    CONSTRAINT dayout_packages_includes_check CHECK ((char_length(includes) <= 300)),
    CONSTRAINT dayout_packages_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 60)))
);

--
-- Name: resort_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resort_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    day_visit_id uuid NOT NULL,
    code text NOT NULL,
    kind text DEFAULT 'payment'::text NOT NULL,
    method text NOT NULL,
    amount_paise integer NOT NULL,
    reference text,
    note text,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    received_by uuid DEFAULT auth.uid(),
    CONSTRAINT resort_payments_amount_paise_check CHECK ((amount_paise > 0)),
    CONSTRAINT resort_payments_kind_check CHECK ((kind = ANY (ARRAY['payment'::text, 'refund'::text]))),
    CONSTRAINT resort_payments_method_check CHECK ((method = ANY (ARRAY['upi'::text, 'cash'::text, 'card'::text, 'bank'::text]))),
    CONSTRAINT resort_payments_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT resort_payments_reference_check CHECK ((char_length(reference) <= 60))
);

--
-- Name: resort_properties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resort_properties (
    property_id uuid NOT NULL,
    enabled_at timestamp with time zone DEFAULT now() NOT NULL,
    enabled_by uuid DEFAULT auth.uid()
);

--
-- Name: resort_receipt_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resort_receipt_seq
    START WITH 1001
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: resort_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resort_settings (
    property_id uuid NOT NULL,
    extra_bed_paise integer DEFAULT 0 NOT NULL,
    extra_bed_max smallint DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT resort_settings_extra_bed_max_check CHECK (((extra_bed_max >= 0) AND (extra_bed_max <= 6))),
    CONSTRAINT resort_settings_extra_bed_paise_check CHECK (((extra_bed_paise >= 0) AND (extra_bed_paise <= 10000000)))
);

--
-- Name: activities activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_pkey PRIMARY KEY (id);

--
-- Name: activity_bookings activity_bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_bookings
    ADD CONSTRAINT activity_bookings_pkey PRIMARY KEY (id);

--
-- Name: booking_extra_beds booking_extra_beds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_extra_beds
    ADD CONSTRAINT booking_extra_beds_pkey PRIMARY KEY (booking_id);

--
-- Name: booking_group_members booking_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_group_members
    ADD CONSTRAINT booking_group_members_pkey PRIMARY KEY (booking_id);

--
-- Name: booking_groups booking_groups_id_property_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_groups
    ADD CONSTRAINT booking_groups_id_property_id_key UNIQUE (id, property_id);

--
-- Name: booking_groups booking_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_groups
    ADD CONSTRAINT booking_groups_pkey PRIMARY KEY (id);

--
-- Name: booking_packages booking_packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_packages
    ADD CONSTRAINT booking_packages_pkey PRIMARY KEY (booking_id);

--
-- Name: day_visits day_visits_id_property_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.day_visits
    ADD CONSTRAINT day_visits_id_property_id_key UNIQUE (id, property_id);

--
-- Name: day_visits day_visits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.day_visits
    ADD CONSTRAINT day_visits_pkey PRIMARY KEY (id);

--
-- Name: day_visits day_visits_property_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.day_visits
    ADD CONSTRAINT day_visits_property_id_code_key UNIQUE (property_id, code);

--
-- Name: dayout_packages dayout_packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dayout_packages
    ADD CONSTRAINT dayout_packages_pkey PRIMARY KEY (id);

--
-- Name: resort_payments resort_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resort_payments
    ADD CONSTRAINT resort_payments_pkey PRIMARY KEY (id);

--
-- Name: resort_properties resort_properties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resort_properties
    ADD CONSTRAINT resort_properties_pkey PRIMARY KEY (property_id);

--
-- Name: resort_settings resort_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resort_settings
    ADD CONSTRAINT resort_settings_pkey PRIMARY KEY (property_id);

--
-- Name: stay_packages stay_packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stay_packages
    ADD CONSTRAINT stay_packages_pkey PRIMARY KEY (id);

--
-- Name: activities_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activities_property ON public.activities USING btree (property_id, sort);

--
-- Name: activity_bookings_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_bookings_booking ON public.activity_bookings USING btree (booking_id);

--
-- Name: activity_bookings_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX activity_bookings_day ON public.activity_bookings USING btree (property_id, day, slot);

--
-- Name: booking_group_members_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_group_members_group ON public.booking_group_members USING btree (group_id);

--
-- Name: booking_groups_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_groups_property ON public.booking_groups USING btree (property_id, created_at DESC);

--
-- Name: day_visits_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX day_visits_day ON public.day_visits USING btree (property_id, visit_date);

--
-- Name: dayout_packages_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dayout_packages_property ON public.dayout_packages USING btree (property_id, sort);

--
-- Name: resort_payments_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resort_payments_list ON public.resort_payments USING btree (property_id, received_at DESC);

--
-- Name: resort_payments_upi_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resort_payments_upi_ref ON public.resort_payments USING btree (property_id, reference) WHERE ((method = 'upi'::text) AND (kind = 'payment'::text) AND (reference IS NOT NULL));

--
-- Name: stay_packages_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stay_packages_property ON public.stay_packages USING btree (property_id, sort);

--
-- Name: activities activities_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: activity_bookings activity_bookings_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_bookings
    ADD CONSTRAINT activity_bookings_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE SET NULL;

--
-- Name: activity_bookings activity_bookings_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_bookings
    ADD CONSTRAINT activity_bookings_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: activity_bookings activity_bookings_day_visit_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_bookings
    ADD CONSTRAINT activity_bookings_day_visit_id_property_id_fkey FOREIGN KEY (day_visit_id, property_id) REFERENCES public.day_visits(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_extra_beds booking_extra_beds_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_extra_beds
    ADD CONSTRAINT booking_extra_beds_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_group_members booking_group_members_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_group_members
    ADD CONSTRAINT booking_group_members_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_group_members booking_group_members_group_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_group_members
    ADD CONSTRAINT booking_group_members_group_id_property_id_fkey FOREIGN KEY (group_id, property_id) REFERENCES public.booking_groups(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_groups booking_groups_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_groups
    ADD CONSTRAINT booking_groups_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: booking_packages booking_packages_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_packages
    ADD CONSTRAINT booking_packages_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_packages booking_packages_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_packages
    ADD CONSTRAINT booking_packages_package_id_fkey FOREIGN KEY (package_id) REFERENCES public.stay_packages(id) ON DELETE SET NULL;

--
-- Name: day_visits day_visits_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.day_visits
    ADD CONSTRAINT day_visits_package_id_fkey FOREIGN KEY (package_id) REFERENCES public.dayout_packages(id) ON DELETE SET NULL;

--
-- Name: day_visits day_visits_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.day_visits
    ADD CONSTRAINT day_visits_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: dayout_packages dayout_packages_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dayout_packages
    ADD CONSTRAINT dayout_packages_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: resort_payments resort_payments_day_visit_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resort_payments
    ADD CONSTRAINT resort_payments_day_visit_id_property_id_fkey FOREIGN KEY (day_visit_id, property_id) REFERENCES public.day_visits(id, property_id) ON DELETE CASCADE;

--
-- Name: resort_properties resort_properties_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resort_properties
    ADD CONSTRAINT resort_properties_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: resort_settings resort_settings_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resort_settings
    ADD CONSTRAINT resort_settings_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: stay_packages stay_packages_meal_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stay_packages
    ADD CONSTRAINT stay_packages_meal_plan_id_fkey FOREIGN KEY (meal_plan_id) REFERENCES public.meal_plans(id) ON DELETE SET NULL;

--
-- Name: stay_packages stay_packages_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stay_packages
    ADD CONSTRAINT stay_packages_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: activities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;

--
-- Name: activities activities_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY activities_select ON public.activities FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: activity_bookings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.activity_bookings ENABLE ROW LEVEL SECURITY;

--
-- Name: activity_bookings activity_bookings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY activity_bookings_select ON public.activity_bookings FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: booking_extra_beds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_extra_beds ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_extra_beds booking_extra_beds_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_extra_beds_select ON public.booking_extra_beds FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: booking_group_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_group_members ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_group_members booking_group_members_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_group_members_select ON public.booking_group_members FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: booking_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_groups booking_groups_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_groups_select ON public.booking_groups FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: booking_packages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_packages ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_packages booking_packages_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_packages_select ON public.booking_packages FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: day_visits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.day_visits ENABLE ROW LEVEL SECURITY;

--
-- Name: day_visits day_visits_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY day_visits_select ON public.day_visits FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: dayout_packages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.dayout_packages ENABLE ROW LEVEL SECURITY;

--
-- Name: dayout_packages dayout_packages_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY dayout_packages_select ON public.dayout_packages FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: resort_payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.resort_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: resort_payments resort_payments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY resort_payments_select ON public.resort_payments FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: resort_properties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.resort_properties ENABLE ROW LEVEL SECURITY;

--
-- Name: resort_properties resort_properties_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY resort_properties_select ON public.resort_properties FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: resort_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.resort_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: resort_settings resort_settings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY resort_settings_select ON public.resort_settings FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: stay_packages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.stay_packages ENABLE ROW LEVEL SECURITY;

--
-- Name: stay_packages stay_packages_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stay_packages_select ON public.stay_packages FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: TABLE day_visits; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.day_visits TO authenticated;

--
-- Name: FUNCTION _dv_row(dv public.day_visits); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._dv_row(dv public.day_visits) FROM PUBLIC;

--
-- Name: TABLE booking_groups; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.booking_groups TO authenticated;

--
-- Name: FUNCTION _grp_row(g public.booking_groups); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._grp_row(g public.booking_groups) FROM PUBLIC;

--
-- Name: FUNCTION _rs_is_resort(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._rs_is_resort(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _rs_pay(dv public.day_visits, p jsonb, p_kind text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._rs_pay(dv public.day_visits, p jsonb, p_kind text) FROM PUBLIC;

--
-- Name: FUNCTION _rs_room_paise(b public.bookings); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._rs_room_paise(b public.bookings) FROM PUBLIC;

--
-- Name: FUNCTION _rs_rupees(p integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._rs_rupees(p integer) FROM PUBLIC;

--
-- Name: FUNCTION _rs_today(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._rs_today(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _rs_view(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._rs_view(p_property uuid) FROM PUBLIC;

--
-- Name: TABLE stay_packages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.stay_packages TO authenticated;

--
-- Name: FUNCTION activities_list(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activities_list(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.activities_list(p_property uuid) TO authenticated;

--
-- Name: FUNCTION activity_book(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activity_book(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.activity_book(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION activity_booking_status(p_id uuid, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activity_booking_status(p_id uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.activity_booking_status(p_id uuid, p_status text) TO authenticated;

--
-- Name: FUNCTION activity_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activity_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.activity_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION activity_guests(p_property uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activity_guests(p_property uuid, p_day date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.activity_guests(p_property uuid, p_day date) TO authenticated;

--
-- Name: FUNCTION activity_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activity_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.activity_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION activity_schedule(p_property uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.activity_schedule(p_property uuid, p_day date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.activity_schedule(p_property uuid, p_day date) TO authenticated;

--
-- Name: FUNCTION booking_extra_beds_set(p_booking uuid, p_beds integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_extra_beds_set(p_booking uuid, p_beds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_extra_beds_set(p_booking uuid, p_beds integer) TO authenticated;

--
-- Name: FUNCTION booking_package_set(p_booking uuid, p_package uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_package_set(p_booking uuid, p_package uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_package_set(p_booking uuid, p_package uuid) TO authenticated;

--
-- Name: FUNCTION booking_resort_get(p_booking uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_resort_get(p_booking uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_resort_get(p_booking uuid) TO authenticated;

--
-- Name: FUNCTION day_visit_pay(p_id uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.day_visit_pay(p_id uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.day_visit_pay(p_id uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION day_visit_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.day_visit_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.day_visit_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION day_visit_status(p_id uuid, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.day_visit_status(p_id uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.day_visit_status(p_id uuid, p_status text) TO authenticated;

--
-- Name: FUNCTION day_visits_list(p_property uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.day_visits_list(p_property uuid, p_day date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.day_visits_list(p_property uuid, p_day date) TO authenticated;

--
-- Name: FUNCTION dayout_package_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dayout_package_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dayout_package_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION dayout_package_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dayout_package_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dayout_package_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION dayout_packages_list(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dayout_packages_list(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dayout_packages_list(p_property uuid) TO authenticated;

--
-- Name: FUNCTION group_delete(p_group uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.group_delete(p_group uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.group_delete(p_group uuid) TO authenticated;

--
-- Name: FUNCTION group_get(p_group uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.group_get(p_group uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.group_get(p_group uuid) TO authenticated;

--
-- Name: FUNCTION group_pay(p_group uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.group_pay(p_group uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.group_pay(p_group uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION group_remove_booking(p_booking uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.group_remove_booking(p_booking uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.group_remove_booking(p_booking uuid) TO authenticated;

--
-- Name: FUNCTION group_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.group_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.group_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION groups_list(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.groups_list(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.groups_list(p_property uuid) TO authenticated;

--
-- Name: FUNCTION resort_income(p_property uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resort_income(p_property uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resort_income(p_property uuid, p_from date, p_to date) TO authenticated;

--
-- Name: FUNCTION resort_mode(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resort_mode(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resort_mode(p_property uuid) TO authenticated;

--
-- Name: FUNCTION resort_set_mode(p_property uuid, p_on boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resort_set_mode(p_property uuid, p_on boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resort_set_mode(p_property uuid, p_on boolean) TO authenticated;

--
-- Name: FUNCTION resort_settings_get(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resort_settings_get(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resort_settings_get(p_property uuid) TO authenticated;

--
-- Name: FUNCTION resort_settings_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resort_settings_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resort_settings_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION resort_today(p_property uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resort_today(p_property uuid, p_day date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resort_today(p_property uuid, p_day date) TO authenticated;

--
-- Name: FUNCTION stay_package_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.stay_package_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.stay_package_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION stay_package_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.stay_package_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.stay_package_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION stay_packages_list(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.stay_packages_list(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.stay_packages_list(p_property uuid) TO authenticated;

--
-- Name: TABLE activities; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.activities TO authenticated;

--
-- Name: TABLE activity_bookings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.activity_bookings TO authenticated;

--
-- Name: TABLE booking_extra_beds; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.booking_extra_beds TO authenticated;

--
-- Name: TABLE booking_group_members; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.booking_group_members TO authenticated;

--
-- Name: TABLE booking_packages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.booking_packages TO authenticated;

--
-- Name: TABLE dayout_packages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.dayout_packages TO authenticated;

--
-- Name: TABLE resort_payments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.resort_payments TO authenticated;

--
-- Name: TABLE resort_properties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.resort_properties TO authenticated;

--
-- Name: TABLE resort_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.resort_settings TO authenticated;
