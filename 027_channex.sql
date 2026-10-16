-- =====================================================================
-- NammaStay · 027_channex.sql — two-way channel manager (Channex)
--   NammaStay → OTAs : availability (free beds/rooms per night), prices
--                      (incl. seasonal & weekend rules) and minimum stays
--   OTAs → NammaStay : bookings (new / modified / cancelled) with guest
--                      name, phone, email, amount and OTA reference
-- Through Channex (white-label channel manager API): Booking.com, Agoda,
-- Expedia, Airbnb, MakeMyTrip/Goibibo, Hostelworld, Yatra, Trip.com…
-- Each NammaStay room + price group (e.g. "6-Bed Dorm · ₹700" = 3 beds)
-- becomes one Channex room type (dorm for hostels) with one rate plan.
-- The `channex` edge function does the talking (secrets CHANNEX_API_KEY,
-- CHANNEX_URL = https://staging.channex.io while testing).
-- Run AFTER 026_pricing_housekeeping.sql.
-- =====================================================================

create table if not exists public.channex_links (
  property_id     uuid primary key references public.properties(id) on delete cascade,
  cx_property_id  text,
  enabled         boolean not null default true,
  dirty_at        timestamptz not null default now(),
  last_push_at    timestamptz,
  last_pull_at    timestamptz,
  last_error      text check (char_length(last_error) <= 500),
  created_at      timestamptz not null default now()
);
create table if not exists public.channex_room_map (
  property_id      uuid not null references public.properties(id) on delete cascade,
  group_key        text not null,                  -- room_id:rate_paise
  room_id          uuid not null,
  rate_paise       int  not null,
  title            text not null,
  bed_ids          uuid[] not null,
  cx_room_type_id  text,
  cx_rate_plan_id  text,
  primary key (property_id, group_key)
);
create table if not exists public.channex_bookings (
  cx_booking_id   text primary key,
  property_id     uuid not null references public.properties(id) on delete cascade,
  unique_id       text,
  ota_name        text,
  ota_code        text,
  status          text,
  revision_id     text,
  booking_ids     uuid[] not null default '{}',
  amount          numeric(12,2),
  currency        text,
  arrival         date,
  departure       date,
  guest_name      text,
  problem         text check (char_length(problem) <= 300),
  raw             jsonb,
  received_at     timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists channex_bookings_prop on public.channex_bookings (property_id, received_at desc);

alter table public.channex_links enable row level security;
alter table public.channex_room_map enable row level security;
alter table public.channex_bookings enable row level security;
revoke all on public.channex_links, public.channex_room_map, public.channex_bookings from anon, authenticated;

-- ---------------------------------------------------------------- price rules must not touch OTA prices
create or replace function public._apply_rate_rules() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare s record; base int;
begin
  if coalesce(current_setting('nammastay.skip_rate_rules', true), '') = '1' then return new; end if;   -- OTA bookings keep the OTA price
  if new.status not in ('pending','confirmed','checked_in') then return new; end if;
  if not exists (select 1 from public.rate_rules where property_id = new.property_id and is_active) then return new; end if;
  if tg_op = 'UPDATE' then
    if (new.check_in_at, new.check_out_at, new.bed_id) is not distinct from (old.check_in_at, old.check_out_at, old.bed_id) then return new; end if;
    if old.source = 'ota' then return new; end if;
  end if;
  select rate_paise into base from public.beds where id = new.bed_id;
  select * into s from public._stay_rate(new.bed_id, new.check_in_at, new.check_out_at, base);
  if tg_op = 'INSERT' and s.min_nights > 0 and new.nights < s.min_nights then
    raise exception 'Minimum stay is % nights for these dates (%).', s.min_nights, s.rule_names;
  end if;
  if s.rate_paise is distinct from new.rate_paise then
    new.rate_paise := s.rate_paise;
    new.discount_paise := round(new.nights * (new.rate_paise + coalesce(new.extra_paise, 0)) * coalesce(new.discount_pct, 0) / 100.0);
    new.total_paise := new.nights * (new.rate_paise + coalesce(new.extra_paise, 0)) - new.discount_paise + coalesce(new.charges_paise, 0);
    if tg_op = 'UPDATE' and new.total_paise < new.paid_paise then
      raise exception 'With the price rules for these dates the stay would cost less than what was already paid. Refund the difference first.';
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- "something changed — push to Channex"
create or replace function public._cx_touch() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.channex_links set dirty_at = now()
   where property_id = coalesce(new.property_id, old.property_id) and enabled;
  return coalesce(new, old);
end $$;
do $$ declare t text; begin
  foreach t in array array['bookings','bed_blocks','rate_rules','beds'] loop
    execute format('drop trigger if exists cx_touch on public.%I', t);
    execute format('create trigger cx_touch after insert or update or delete on public.%I for each row execute function public._cx_touch()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- groups (room + price) → Channex room types
create or replace function public.cx_groups(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
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

-- Availability, price and minimum stay per mapped group and night (for pushing to Channex)
create or replace function public.cx_ari(p_property uuid, p_days int default 365) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------- OTA booking → NammaStay
-- p_rev: a Channex booking revision (attributes). Idempotent per revision.
create or replace function public.cx_import(p_property uuid, p_rev jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

-- ---------------------------------------------------------------- server helpers (edge function, service role)
create or replace function public.cx_setup_data(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('property', jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'email', p.email, 'phone', p.phone,
           'address', p.address, 'city', p.city, 'timezone', p.timezone),
         'link', (select to_jsonb(l) from public.channex_links l where l.property_id = p.id),
         'maps', (select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from public.channex_room_map m where m.property_id = p.id),
         'groups', public.cx_groups(p.id))
    from public.properties p where p.id = p_property
$$;

create or replace function public.cx_save_setup(p_property uuid, p_cx_property text, p_maps jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.cx_mark(p_property uuid, p_kind text, p_error text default null) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.channex_links set
    last_push_at = case when p_kind = 'push' and p_error is null then now() else last_push_at end,
    last_pull_at = case when p_kind = 'pull' and p_error is null then now() else last_pull_at end,
    last_error = left(p_error, 500)
  where property_id = p_property
$$;

create or replace function public.cx_links_due() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('property_id', l.property_id, 'cx_property_id', l.cx_property_id,
           'push', l.last_push_at is null or l.dirty_at > l.last_push_at or l.last_push_at < now() - interval '1 day')), '[]'::jsonb)
    from public.channex_links l
   where l.enabled and l.cx_property_id is not null and public._access_state(l.property_id) not in ('expired','suspended')
$$;

create or replace function public.cx_property_for(p_cx_property text) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select property_id from public.channex_links where cx_property_id = p_cx_property and enabled limit 1
$$;

-- ---------------------------------------------------------------- staff (owner / manager)
create or replace function public.cx_status(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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

create or replace function public.cx_set_enabled(p_property uuid, p_enabled boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  update public.channex_links set enabled = p_enabled, dirty_at = now() where property_id = p_property;
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public._cx_touch(), public.cx_groups(uuid), public.cx_ari(uuid, int), public.cx_import(uuid, jsonb), public.cx_setup_data(uuid),
  public.cx_save_setup(uuid, text, jsonb), public.cx_mark(uuid, text, text), public.cx_links_due(), public.cx_property_for(text),
  public.cx_status(uuid), public.cx_set_enabled(uuid, boolean) from public, anon, authenticated;
grant execute on function public.cx_status(uuid), public.cx_set_enabled(uuid, boolean) to authenticated;
grant execute on function public.cx_groups(uuid), public.cx_ari(uuid, int), public.cx_import(uuid, jsonb), public.cx_setup_data(uuid),
  public.cx_save_setup(uuid, text, jsonb), public.cx_mark(uuid, text, text), public.cx_links_due(), public.cx_property_for(text) to service_role;
