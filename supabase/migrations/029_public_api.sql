-- 029_public_api.sql — NammaStay public API (per-property API keys)
--
-- Owners create API keys in Settings → API keys. Other software (your own website's booking
-- engine, a partner, a script) calls the `api` Edge Function with the key:
--   GET  /api/v1/property            property details
--   GET  /api/v1/rooms               room types (room + price group), units, base price
--   GET  /api/v1/availability        free units, nightly price, minimum stay per night
--   GET  /api/v1/bookings            bookings in a date range            (scope: bookings)
--   GET  /api/v1/bookings/{id|code}  one booking                         (scope: bookings)
--   POST /api/v1/bookings            create a booking                    (scope: bookings)
--   POST /api/v1/bookings/{id}/cancel                                    (scope: bookings)
--
-- Keys are stored only as a SHA-256 hash; the full key is shown once when created.
-- Every server function below is callable only by the Edge Function (service role).
-- Safe to run more than once.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables
create table if not exists public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 2 and 60),
  prefix       text not null,                                   -- "ns_live_1a2b3c" — shown in the list
  key_hash     text not null unique,                            -- sha256(full key), hex
  scopes       text[] not null default '{read}' check (scopes <@ array['read','bookings']::text[] and 'read' = any (scopes)),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
create index if not exists api_keys_property on public.api_keys (property_id, created_at desc);

create table if not exists public.api_requests (                -- rate limit window (rows older than a day are removed)
  key_id uuid not null references public.api_keys(id) on delete cascade,
  at     timestamptz not null default now()
);
create index if not exists api_requests_key_at on public.api_requests (key_id, at desc);

create table if not exists public.api_idempotency (             -- "Idempotency-Key" header on POST /bookings
  key_id     uuid not null references public.api_keys(id) on delete cascade,
  idem_key   text not null check (char_length(idem_key) between 1 and 100),
  response   jsonb not null,
  created_at timestamptz not null default now(),
  primary key (key_id, idem_key)
);

alter table public.api_keys        enable row level security;
alter table public.api_requests    enable row level security;
alter table public.api_idempotency enable row level security;
revoke all on public.api_keys, public.api_requests, public.api_idempotency from anon, authenticated;

-- ---------------------------------------------------------------- owner screens (Settings → API keys)
create or replace function public.api_key_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  return coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'prefix', k.prefix, 'scopes', k.scopes,
                     'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at,
                     'calls_24h', (select count(*) from public.api_requests r where r.key_id = k.id and r.at > now() - interval '24 hours'))
                     order by k.revoked_at nulls first, k.created_at desc)
                     from public.api_keys k where k.property_id = p_property), '[]'::jsonb);
end $$;

-- Returns the full key ONCE. Scopes: 'read' (always) and optionally 'bookings'.
create or replace function public.api_key_create(p_property uuid, p_name text, p_bookings boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.api_key_revoke(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.api_keys where id = p_id;
  if v_prop is null then raise exception 'API key not found.'; end if;
  perform public._assert_role(v_prop, array['owner']::public.member_role[]);
  update public.api_keys set revoked_at = coalesce(revoked_at, now()) where id = p_id;
end $$;

revoke execute on function public.api_key_list(uuid), public.api_key_create(uuid, text, boolean), public.api_key_revoke(uuid) from public, anon;
grant  execute on function public.api_key_list(uuid), public.api_key_create(uuid, text, boolean), public.api_key_revoke(uuid) to authenticated;

-- ---------------------------------------------------------------- server: authenticate a call
-- Returns {key_id, property_id, scopes} or {error, status}. 120 calls a minute per key.
create or replace function public.api_auth(p_key text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

-- ---------------------------------------------------------------- server: data
create or replace function public._api_rupees(p int) returns numeric language sql immutable as $$ select round(coalesce(p, 0) / 100.0, 2) $$;

create or replace function public.api_property(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'address', p.address, 'city', p.city,
           'phone', p.phone, 'email', p.email, 'timezone', p.timezone, 'currency', 'INR',
           'check_in_time', to_char(p.checkin_time, 'HH24:MI'), 'check_out_time', to_char(p.checkout_time, 'HH24:MI'),
           'unit', case when p.kind = 'hostel' then 'bed' else 'room' end)
    from public.properties p where p.id = p_property
$$;

-- Room types = a room + one price (a 6-bed dorm with ₹700 lower and ₹600 upper beds = 2 room types)
create or replace function public.api_rooms(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'room_type_id', g->>'group_key', 'room_id', g->>'room_id', 'name', g->>'title',
           'description', (select r.description from public.rooms r where r.id = (g->>'room_id')::uuid),
           'unit', case when g->>'room_kind' = 'dorm' then 'bed' else 'room' end,
           'units', (g->>'count')::int, 'max_guests_per_unit', (g->>'occ_adults')::int,
           'base_price', public._api_rupees((g->>'rate_paise')::int)) order by g->>'sort', g->>'title'), '[]'::jsonb)
    from jsonb_array_elements(public.cx_groups(p_property)) g
$$;

-- p_from / p_to: dates (check-in day .. check-out day, max 92 nights)
create or replace function public.api_availability(p_property uuid, p_from date, p_to date, p_room_type text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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

create or replace function public._api_booking_json(b public.bookings) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
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

create or replace function public.api_bookings(p_property uuid, p_from date, p_to date, p_status text default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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

create or replace function public.api_booking_get(p_property uuid, p_ref text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select public._api_booking_json(b) from public.bookings b
   where b.property_id = p_property
     and (b.code = upper(p_ref) or (p_ref ~* '^[0-9a-f-]{36}$' and b.id = p_ref::uuid))
$$;

-- p: { room_type_id, check_in, check_out, guests?, units?, guest: {name, phone?, email?, nationality?}, note?, status? ('confirmed'|'pending') }
create or replace function public.api_booking_create(p_property uuid, p_key_id uuid, p jsonb, p_idem text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

create or replace function public.api_booking_cancel(p_property uuid, p_ref text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

-- only the Edge Function (service role) may call the server functions
do $$ declare f text; begin
  foreach f in array array['api_auth(text)', 'api_property(uuid)', 'api_rooms(uuid)', 'api_availability(uuid, date, date, text)',
                           '_api_booking_json(public.bookings)', 'api_bookings(uuid, date, date, text, int)', 'api_booking_get(uuid, text)',
                           'api_booking_create(uuid, uuid, jsonb, text)', 'api_booking_cancel(uuid, text, text)', '_api_rupees(int)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
