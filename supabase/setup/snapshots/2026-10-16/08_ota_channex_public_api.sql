-- =====================================================================
-- NammaStay · ota channex public api
-- iCal OTA sync, Channex channel manager, public API
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
-- Name: _api_booking_json(public.bookings); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._api_booking_json(b public.bookings) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: _api_rupees(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._api_rupees(p integer) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    AS $$ select round(coalesce(p, 0) / 100.0, 2) $$;

--
-- Name: api_auth(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_auth(p_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: api_availability(uuid, date, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_availability(p_property uuid, p_from date, p_to date, p_room_type text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: api_booking_cancel(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_booking_cancel(p_property uuid, p_ref text, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: api_booking_create(uuid, uuid, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_booking_create(p_property uuid, p_key_id uuid, p jsonb, p_idem text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: api_booking_get(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_booking_get(p_property uuid, p_ref text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
  select public._api_booking_json(b) from public.bookings b
   where b.property_id = p_property
     and (b.code = upper(p_ref) or (p_ref ~* '^[0-9a-f-]{36}$' and b.id = p_ref::uuid))
$_$;

--
-- Name: api_bookings(uuid, date, date, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_bookings(p_property uuid, p_from date, p_to date, p_status text DEFAULT NULL::text, p_limit integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: api_key_create(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_key_create(p_property uuid, p_name text, p_bookings boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: api_key_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_key_list(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  return coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'prefix', k.prefix, 'scopes', k.scopes,
                     'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
                     'calls_24h', (select count(*) from public.api_requests r where r.key_id = k.id and r.at > now() - interval '24 hours'))
                     order by k.revoked_at nulls first, k.created_at desc)
                     from public.api_keys k where k.property_id = p_property), '[]'::jsonb);
end $$;

--
-- Name: api_key_revoke(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_key_revoke(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.api_keys where id = p_id;
  if v_prop is null then raise exception 'API key not found.'; end if;
  perform public._assert_role(v_prop, array['owner']::public.member_role[]);
  update public.api_keys set revoked_at = coalesce(revoked_at, now()) where id = p_id;
end $$;

--
-- Name: api_property(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_property(p_property uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'address', p.address, 'city', p.city,
           'phone', p.phone, 'email', p.email, 'timezone', p.timezone, 'currency', 'INR',
           'check_in_time', to_char(p.checkin_time, 'HH24:MI'), 'check_out_time', to_char(p.checkout_time, 'HH24:MI'),
           'unit', case when p.kind = 'hostel' then 'bed' else 'room' end)
    from public.properties p where p.id = p_property
$$;

--
-- Name: api_rooms(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.api_rooms(p_property uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'room_type_id', g->>'group_key', 'room_id', g->>'room_id', 'name', g->>'title',
           'description', (select r.description from public.rooms r where r.id = (g->>'room_id')::uuid),
           'unit', case when g->>'room_kind' = 'dorm' then 'bed' else 'room' end,
           'units', (g->>'count')::int, 'max_guests_per_unit', (g->>'occ_adults')::int,
           'base_price', public._api_rupees((g->>'rate_paise')::int)) order by g->>'sort', g->>'title'), '[]'::jsonb)
    from jsonb_array_elements(public.cx_groups(p_property)) g
$$;

--
-- Name: cx_ari(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_ari(p_property uuid, p_days integer DEFAULT 365) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: cx_groups(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_groups(p_property uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: cx_import(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_import(p_property uuid, p_rev jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: cx_links_due(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_links_due() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object('property_id', l.property_id, 'cx_property_id', l.cx_property_id,
           'push', l.last_push_at is null or l.dirty_at > l.last_push_at or l.last_push_at < now() - interval '1 day')), '[]'::jsonb)
    from public.channex_links l
   where l.enabled and l.cx_property_id is not null and public._access_state(l.property_id) not in ('expired','suspended')
$$;

--
-- Name: cx_mark(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_mark(p_property uuid, p_kind text, p_error text DEFAULT NULL::text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  update public.channex_links set
    last_push_at = case when p_kind = 'push' and p_error is null then now() else last_push_at end,
    last_pull_at = case when p_kind = 'pull' and p_error is null then now() else last_pull_at end,
    last_error = left(p_error, 500)
  where property_id = p_property
$$;

--
-- Name: cx_property_for(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_property_for(p_cx_property text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select property_id from public.channex_links where cx_property_id = p_cx_property and enabled limit 1
$$;

--
-- Name: cx_save_setup(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_save_setup(p_property uuid, p_cx_property text, p_maps jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: cx_set_enabled(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_set_enabled(p_property uuid, p_enabled boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  update public.channex_links set enabled = p_enabled, dirty_at = now() where property_id = p_property;
end $$;

--
-- Name: cx_setup_data(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_setup_data(p_property uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object('property', jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'email', p.email, 'phone', p.phone,
           'address', p.address, 'city', p.city, 'timezone', p.timezone),
         'link', (select to_jsonb(l) from public.channex_links l where l.property_id = p.id),
         'maps', (select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from public.channex_room_map m where m.property_id = p.id),
         'groups', public.cx_groups(p.id))
    from public.properties p where p.id = p_property
$$;

--
-- Name: cx_status(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cx_status(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: ota_apply(uuid, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_apply(p_feed uuid, p_events jsonb, p_error text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: ota_feeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ota_feeds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    bed_id uuid NOT NULL,
    channel text NOT NULL,
    import_url text NOT NULL,
    label text,
    last_synced_at timestamp with time zone,
    last_status text,
    last_error text,
    events_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ota_feeds_channel_check CHECK ((channel = ANY (ARRAY['airbnb'::text, 'booking'::text, 'agoda'::text, 'vrbo'::text, 'google'::text, 'other'::text]))),
    CONSTRAINT ota_feeds_import_url_check CHECK (((import_url ~ '^https://'::text) AND (char_length(import_url) <= 1000))),
    CONSTRAINT ota_feeds_label_check CHECK ((char_length(label) <= 60)),
    CONSTRAINT ota_feeds_last_error_check CHECK ((char_length(last_error) <= 300)),
    CONSTRAINT ota_feeds_last_status_check CHECK ((last_status = ANY (ARRAY['ok'::text, 'error'::text])))
);

--
-- Name: ota_due_feeds(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_due_feeds(p_limit integer DEFAULT 300) RETURNS SETOF public.ota_feeds
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select f.* from public.ota_feeds f join public.beds b on b.id = f.bed_id
   where b.is_active and public._access_state(f.property_id) not in ('expired','suspended')
   order by f.last_synced_at nulls first limit least(greatest(coalesce(p_limit, 300), 1), 1000)
$$;

--
-- Name: ota_export(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_export(p_token uuid, p_exclude text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: ota_feed_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_feed_delete(p_feed uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.ota_feeds where id = p_feed;
  if v_prop is null then raise exception 'Calendar link not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  perform public._require_perm(v_prop, 'manage_rooms');
  delete from public.ota_feeds where id = p_feed;                 -- its imported blocks go too
end $$;

--
-- Name: ota_feed_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_feed_save(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: ota_feeds_for_sync(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_feeds_for_sync(p_property uuid) RETURNS SETOF uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query select id from public.ota_feeds where property_id = p_property;
end $$;

--
-- Name: ota_new_token(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_new_token(p_bed uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid; v_tok uuid := gen_random_uuid();
begin
  select property_id into v_prop from public.beds where id = p_bed;
  if v_prop is null then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  update public.beds set ical_token = v_tok where id = p_bed;
  return v_tok;
end $$;

--
-- Name: ota_overview(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ota_overview(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: api_idempotency; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_idempotency (
    key_id uuid NOT NULL,
    idem_key text NOT NULL,
    response jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT api_idempotency_idem_key_check CHECK (((char_length(idem_key) >= 1) AND (char_length(idem_key) <= 100)))
);

--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    prefix text NOT NULL,
    key_hash text NOT NULL,
    scopes text[] DEFAULT '{read}'::text[] NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    CONSTRAINT api_keys_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 60))),
    CONSTRAINT api_keys_scopes_check CHECK (((scopes <@ ARRAY['read'::text, 'bookings'::text]) AND ('read'::text = ANY (scopes))))
);

--
-- Name: api_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_requests (
    key_id uuid NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: channex_bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channex_bookings (
    cx_booking_id text NOT NULL,
    property_id uuid NOT NULL,
    unique_id text,
    ota_name text,
    ota_code text,
    status text,
    revision_id text,
    booking_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    amount numeric(12,2),
    currency text,
    arrival date,
    departure date,
    guest_name text,
    problem text,
    raw jsonb,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channex_bookings_problem_check CHECK ((char_length(problem) <= 300))
);

--
-- Name: channex_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channex_links (
    property_id uuid NOT NULL,
    cx_property_id text,
    enabled boolean DEFAULT true NOT NULL,
    dirty_at timestamp with time zone DEFAULT now() NOT NULL,
    last_push_at timestamp with time zone,
    last_pull_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channex_links_last_error_check CHECK ((char_length(last_error) <= 500))
);

--
-- Name: channex_room_map; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channex_room_map (
    property_id uuid NOT NULL,
    group_key text NOT NULL,
    room_id uuid NOT NULL,
    rate_paise integer NOT NULL,
    title text NOT NULL,
    bed_ids uuid[] NOT NULL,
    cx_room_type_id text,
    cx_rate_plan_id text
);

--
-- Name: api_idempotency api_idempotency_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_idempotency
    ADD CONSTRAINT api_idempotency_pkey PRIMARY KEY (key_id, idem_key);

--
-- Name: api_keys api_keys_key_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash);

--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);

--
-- Name: channex_bookings channex_bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channex_bookings
    ADD CONSTRAINT channex_bookings_pkey PRIMARY KEY (cx_booking_id);

--
-- Name: channex_links channex_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channex_links
    ADD CONSTRAINT channex_links_pkey PRIMARY KEY (property_id);

--
-- Name: channex_room_map channex_room_map_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channex_room_map
    ADD CONSTRAINT channex_room_map_pkey PRIMARY KEY (property_id, group_key);

--
-- Name: ota_feeds ota_feeds_bed_id_import_url_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ota_feeds
    ADD CONSTRAINT ota_feeds_bed_id_import_url_key UNIQUE (bed_id, import_url);

--
-- Name: ota_feeds ota_feeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ota_feeds
    ADD CONSTRAINT ota_feeds_pkey PRIMARY KEY (id);

--
-- Name: api_keys_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_keys_property ON public.api_keys USING btree (property_id, created_at DESC);

--
-- Name: api_requests_key_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_requests_key_at ON public.api_requests USING btree (key_id, at DESC);

--
-- Name: channex_bookings_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX channex_bookings_prop ON public.channex_bookings USING btree (property_id, received_at DESC);

--
-- Name: ota_feeds_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ota_feeds_prop ON public.ota_feeds USING btree (property_id);

--
-- Name: api_idempotency api_idempotency_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_idempotency
    ADD CONSTRAINT api_idempotency_key_id_fkey FOREIGN KEY (key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

--
-- Name: api_keys api_keys_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: api_requests api_requests_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_requests
    ADD CONSTRAINT api_requests_key_id_fkey FOREIGN KEY (key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;

--
-- Name: bed_blocks bed_blocks_feed_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bed_blocks
    ADD CONSTRAINT bed_blocks_feed_id_fkey FOREIGN KEY (feed_id) REFERENCES public.ota_feeds(id) ON DELETE CASCADE;

--
-- Name: channex_bookings channex_bookings_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channex_bookings
    ADD CONSTRAINT channex_bookings_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: channex_links channex_links_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channex_links
    ADD CONSTRAINT channex_links_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: channex_room_map channex_room_map_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channex_room_map
    ADD CONSTRAINT channex_room_map_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: ota_feeds ota_feeds_bed_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ota_feeds
    ADD CONSTRAINT ota_feeds_bed_id_property_id_fkey FOREIGN KEY (bed_id, property_id) REFERENCES public.beds(id, property_id) ON DELETE CASCADE;

--
-- Name: api_idempotency; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.api_idempotency ENABLE ROW LEVEL SECURITY;

--
-- Name: api_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: api_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.api_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: channex_bookings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.channex_bookings ENABLE ROW LEVEL SECURITY;

--
-- Name: channex_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.channex_links ENABLE ROW LEVEL SECURITY;

--
-- Name: channex_room_map; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.channex_room_map ENABLE ROW LEVEL SECURITY;

--
-- Name: ota_feeds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ota_feeds ENABLE ROW LEVEL SECURITY;

--
-- Name: ota_feeds ota_feeds_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ota_feeds_select ON public.ota_feeds FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids)));

--
-- Name: FUNCTION _api_booking_json(b public.bookings); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._api_booking_json(b public.bookings) FROM PUBLIC;
GRANT ALL ON FUNCTION public._api_booking_json(b public.bookings) TO service_role;

--
-- Name: FUNCTION _api_rupees(p integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._api_rupees(p integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public._api_rupees(p integer) TO service_role;

--
-- Name: FUNCTION api_auth(p_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_auth(p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_auth(p_key text) TO service_role;

--
-- Name: FUNCTION api_availability(p_property uuid, p_from date, p_to date, p_room_type text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_availability(p_property uuid, p_from date, p_to date, p_room_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_availability(p_property uuid, p_from date, p_to date, p_room_type text) TO service_role;

--
-- Name: FUNCTION api_booking_cancel(p_property uuid, p_ref text, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_booking_cancel(p_property uuid, p_ref text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_booking_cancel(p_property uuid, p_ref text, p_reason text) TO service_role;

--
-- Name: FUNCTION api_booking_create(p_property uuid, p_key_id uuid, p jsonb, p_idem text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_booking_create(p_property uuid, p_key_id uuid, p jsonb, p_idem text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_booking_create(p_property uuid, p_key_id uuid, p jsonb, p_idem text) TO service_role;

--
-- Name: FUNCTION api_booking_get(p_property uuid, p_ref text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_booking_get(p_property uuid, p_ref text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_booking_get(p_property uuid, p_ref text) TO service_role;

--
-- Name: FUNCTION api_bookings(p_property uuid, p_from date, p_to date, p_status text, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_bookings(p_property uuid, p_from date, p_to date, p_status text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_bookings(p_property uuid, p_from date, p_to date, p_status text, p_limit integer) TO service_role;

--
-- Name: FUNCTION api_key_create(p_property uuid, p_name text, p_bookings boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_key_create(p_property uuid, p_name text, p_bookings boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_key_create(p_property uuid, p_name text, p_bookings boolean) TO authenticated;

--
-- Name: FUNCTION api_key_list(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_key_list(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_key_list(p_property uuid) TO authenticated;

--
-- Name: FUNCTION api_key_revoke(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_key_revoke(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_key_revoke(p_id uuid) TO authenticated;

--
-- Name: FUNCTION api_property(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_property(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_property(p_property uuid) TO service_role;

--
-- Name: FUNCTION api_rooms(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.api_rooms(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.api_rooms(p_property uuid) TO service_role;

--
-- Name: FUNCTION cx_ari(p_property uuid, p_days integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_ari(p_property uuid, p_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_ari(p_property uuid, p_days integer) TO service_role;

--
-- Name: FUNCTION cx_groups(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_groups(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_groups(p_property uuid) TO service_role;

--
-- Name: FUNCTION cx_import(p_property uuid, p_rev jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_import(p_property uuid, p_rev jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_import(p_property uuid, p_rev jsonb) TO service_role;

--
-- Name: FUNCTION cx_links_due(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_links_due() FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_links_due() TO service_role;

--
-- Name: FUNCTION cx_mark(p_property uuid, p_kind text, p_error text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_mark(p_property uuid, p_kind text, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_mark(p_property uuid, p_kind text, p_error text) TO service_role;

--
-- Name: FUNCTION cx_property_for(p_cx_property text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_property_for(p_cx_property text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_property_for(p_cx_property text) TO service_role;

--
-- Name: FUNCTION cx_save_setup(p_property uuid, p_cx_property text, p_maps jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_save_setup(p_property uuid, p_cx_property text, p_maps jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_save_setup(p_property uuid, p_cx_property text, p_maps jsonb) TO service_role;

--
-- Name: FUNCTION cx_set_enabled(p_property uuid, p_enabled boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_set_enabled(p_property uuid, p_enabled boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_set_enabled(p_property uuid, p_enabled boolean) TO authenticated;

--
-- Name: FUNCTION cx_setup_data(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_setup_data(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_setup_data(p_property uuid) TO service_role;

--
-- Name: FUNCTION cx_status(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cx_status(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cx_status(p_property uuid) TO authenticated;

--
-- Name: FUNCTION ota_apply(p_feed uuid, p_events jsonb, p_error text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_apply(p_feed uuid, p_events jsonb, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_apply(p_feed uuid, p_events jsonb, p_error text) TO service_role;

--
-- Name: TABLE ota_feeds; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.ota_feeds TO authenticated;

--
-- Name: FUNCTION ota_due_feeds(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_due_feeds(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_due_feeds(p_limit integer) TO service_role;

--
-- Name: FUNCTION ota_export(p_token uuid, p_exclude text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_export(p_token uuid, p_exclude text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_export(p_token uuid, p_exclude text) TO service_role;

--
-- Name: FUNCTION ota_feed_delete(p_feed uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_feed_delete(p_feed uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_feed_delete(p_feed uuid) TO authenticated;

--
-- Name: FUNCTION ota_feed_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_feed_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_feed_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION ota_feeds_for_sync(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_feeds_for_sync(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_feeds_for_sync(p_property uuid) TO authenticated;

--
-- Name: FUNCTION ota_new_token(p_bed uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_new_token(p_bed uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_new_token(p_bed uuid) TO authenticated;

--
-- Name: FUNCTION ota_overview(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ota_overview(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ota_overview(p_property uuid) TO authenticated;
