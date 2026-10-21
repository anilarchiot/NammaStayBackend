-- =====================================================================
-- NammaStay · 038_booking_page.sql — Book direct (zero commission)
--
-- Every property can switch on its own public booking page:
--     https://thenammastay.com/stay.html?p=<slug>
--
--   • Guests see photos, live availability (straight from the NammaStay calendar), prices
--     (price rules included), house rules, cancellation policy, reviews from verified stays
--   • Booking (default): guest picks dates + room/bed type → booked at once, pays at the property.
--     NammaStay takes no commission. Owner can choose "I confirm each booking myself" instead.
--   • Optional advance (owner's choice): beds are HELD as "pending" bookings for a few minutes →
--     guest pays the advance by UPI DIRECTLY to the property's own UPI ID (NammaStay never touches
--     the money) → guest enters the UTR → owner checks the bank app and taps Confirm → the advance
--     is recorded as a UPI payment and the bookings become confirmed.
--   • Unpaid holds (advance mode only) expire by themselves (default 30 minutes) and the beds free up.
--   • Reviews: only guests with a checked-out booking can review (link from the owner).
--
-- Owner: page settings. Owner + manager: requests and reviews. Guests (not signed in):
-- only the bp_* functions below, which show nothing private and are rate limited.
--
-- Needs (already on the live project): 026 price rules (_night_rate), 027 room types (cx_groups),
-- 007 subscriptions (_access_state). Uses 036 legal documents for the licence badge if installed.
--
-- ADD-ON ONLY — new tables, functions, one PUBLIC storage bucket for page photos ("stay-photos");
-- nothing existing is changed. Bookings made here are ordinary bookings (source "direct").
-- Safe to run more than once. Rollback: rollback_038_booking_page.sql
-- =====================================================================

do $$ begin
  if to_regprocedure('public.cx_groups(uuid)') is null or to_regprocedure('public._night_rate(uuid,uuid,integer,date)') is null
     or to_regprocedure('public._access_state(uuid)') is null then
    raise exception 'Run the earlier NammaStay migrations first (price rules, room types, subscriptions).';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.booking_pages (
  property_id      uuid primary key references public.properties(id) on delete cascade,
  slug             text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$' and slug !~ '--'),
  enabled          boolean not null default false,
  headline         text check (char_length(headline) <= 120),
  about            text check (char_length(about) <= 2000),
  amenities        text[] not null default '{}' check (cardinality(amenities) <= 30),
  house_rules      text check (char_length(house_rules) <= 1500),
  cancel_policy    text check (char_length(cancel_policy) <= 1000),
  advance_mode     text not null default 'none' check (advance_mode in ('percent','first_night','none')),
  advance_pct      int  not null default 30 check (advance_pct between 10 and 100),
  approve_first    boolean not null default false,           -- no advance: wait for the owner's OK instead of instant
  hold_minutes     int  not null default 30 check (hold_minutes between 15 and 180),
  max_nights       int  not null default 30 check (max_nights between 1 and 90),
  book_ahead_days  int  not null default 365 check (book_ahead_days between 14 and 730),
  whatsapp         text check (whatsapp is null or whatsapp ~ '^\+?[0-9]{8,15}$'),
  instagram        text check (instagram is null or instagram ~ '^[A-Za-z0-9._]{1,30}$'),
  map_url          text check (map_url is null or (map_url ~ '^https://' and char_length(map_url) <= 400)),
  show_address     boolean not null default true,
  show_licences    boolean not null default true,
  show_reviews     boolean not null default true,
  photos           jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 12),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create sequence if not exists public.booking_request_seq start 1001;

create table if not exists public.booking_requests (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  code          text not null unique default ('WEB-' || nextval('public.booking_request_seq')),
  token         uuid not null unique default gen_random_uuid(),     -- the guest's private status link
  status        text not null check (status in ('awaiting_payment','payment_claimed','awaiting_confirmation','confirmed','declined','expired','cancelled')),
  booking_ids   uuid[] not null default '{}',
  room_type     text not null,
  room_name     text not null,
  unit          text not null check (unit in ('bed','room')),
  units         int  not null check (units between 1 and 10),
  guests        int  not null check (guests between 1 and 40),
  check_in      date not null,
  check_out     date not null check (check_out > check_in),
  guest_name    text not null check (char_length(guest_name) between 2 and 120),
  guest_phone   text not null check (guest_phone ~ '^\+?[0-9]{8,15}$'),
  guest_email   text check (guest_email is null or guest_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  guest_note    text check (char_length(guest_note) <= 500),
  total_paise   int  not null check (total_paise >= 0),
  advance_paise int  not null default 0 check (advance_paise >= 0),
  utr           text check (utr is null or utr ~ '^[0-9A-Z]{6,35}$'),
  claimed_at    timestamptz,
  beds_lost     boolean not null default false,                       -- paid after the hold ran out and the beds were taken
  expires_at    timestamptz,
  decided_at    timestamptz,
  decided_by    uuid,
  owner_note    text check (char_length(owner_note) <= 500),
  client_key    text,                                                  -- hashed network address, for rate limits only
  created_at    timestamptz not null default now()
);
create index if not exists booking_requests_property on public.booking_requests (property_id, created_at desc);
create index if not exists booking_requests_open on public.booking_requests (property_id, expires_at)
  where status in ('awaiting_payment','awaiting_confirmation');
create index if not exists booking_requests_client on public.booking_requests (client_key, created_at desc);
create unique index if not exists booking_requests_utr on public.booking_requests (property_id, utr) where utr is not null;

create table if not exists public.stay_reviews (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  booking_id  uuid not null unique references public.bookings(id) on delete cascade,
  guest_name  text not null check (char_length(btrim(guest_name)) between 2 and 60),
  rating      int  not null check (rating between 1 and 5),
  body        text check (char_length(body) <= 1000),
  stayed_on   date not null,
  hidden      boolean not null default false,
  reply       text check (char_length(reply) <= 600),
  replied_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists stay_reviews_property on public.stay_reviews (property_id, created_at desc);

do $$ declare t text; begin
  foreach t in array array['booking_pages','booking_requests','stay_reviews'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);    -- only through the functions below
  end loop;
end $$;
revoke all on sequence public.booking_request_seq from anon, authenticated;

-- ---------------------------------------------------------------- page photos (PUBLIC bucket; owner + manager upload)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('stay-photos', 'stay-photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Path layout: {property_id}/{random}.{ext}
drop policy if exists "stay-photos: staff upload" on storage.objects;
create policy "stay-photos: staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'stay-photos' and exists (
    select 1 from public.my_property_ids(array['owner','manager']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "stay-photos: staff delete" on storage.objects;
create policy "stay-photos: staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'stay-photos' and exists (
    select 1 from public.my_property_ids(array['owner','manager']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));

-- ---------------------------------------------------------------- helpers (server only)
create or replace function public._bp_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata'))::date
$$;

-- Is the page taking bookings? (switched on, subscription running, not in PG mode)
create or replace function public._bp_open(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select bp.enabled from public.booking_pages bp where bp.property_id = p_property), false)
     and public._access_state(p_property) not in ('expired','suspended')
     and coalesce((select (to_jsonb(p)->>'is_pg')::boolean from public.properties p where p.id = p_property), false) = false
$$;

-- Hashed caller address (Supabase passes request headers); null when unknown
create or replace function public._bp_client_key() returns text
language plpgsql stable set search_path = public, pg_temp as $$
declare h json; ip text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  ip := coalesce(h->>'cf-connecting-ip', split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1), h->>'x-real-ip');
  return case when coalesce(btrim(ip), '') = '' then null else md5('nammastay-bp:' || btrim(ip)) end;
end $$;

-- Stay as a time range, property time
create or replace function public._bp_range(p public.properties, p_in date, p_out date) returns tstzrange
language sql stable set search_path = public, pg_temp as $$
  select tstzrange((p_in::timestamp + p.checkin_time) at time zone p.timezone, (p_out::timestamp + p.checkout_time) at time zone p.timezone, '[)')
$$;

-- Room / bed types the page sells (same grouping as the API and channel manager)
create or replace function public._bp_rooms(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', g->>'group_key', 'room_id', g->>'room_id', 'name', g->>'title',
      'description', (select r.description from public.rooms r where r.id = (g->>'room_id')::uuid),
      'unit', case when p.kind = 'hostel' and (g->>'occ_adults')::int <= 1 then 'bed' else 'room' end,
      'units', (g->>'count')::int, 'rate_paise', (g->>'rate_paise')::int,
      'max_guests', (select max(coalesce(bd.max_guests, 1)) from public.beds bd where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid)),
      'base_guests', (select max(coalesce(bd.base_guests, 1)) from public.beds bd where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid)),
      'extra_guest_paise', (select max(coalesce(bd.extra_guest_paise, 0)) from public.beds bd where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid)),
      'bed_ids', g->'bed_ids') order by g->>'sort', g->>'title'), '[]'::jsonb)
    from jsonb_array_elements(public.cx_groups(p_property)) g, public.properties p
   where p.id = p_property
$$;

-- Free units of one type for a range
create or replace function public._bp_free(p public.properties, p_beds jsonb, p_range tstzrange) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from jsonb_array_elements_text(p_beds) bid
   where not exists (select 1 from public.bookings k where k.bed_id = bid::uuid and k.status in ('pending','confirmed','checked_in') and k.stay && p_range)
     and not exists (select 1 from public.bed_blocks z where z.bed_id = bid::uuid and z.period && p_range)
$$;

create or replace function public._bp_min_stay(p_property uuid, p_room uuid, p_day date) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(1, coalesce((select max(r.min_nights) from public.rate_rules r
    where r.property_id = p_property and r.is_active and r.min_nights is not null
      and (r.room_ids is null or p_room = any (r.room_ids))
      and ((r.kind = 'season' and p_day between r.date_from and r.date_to)
        or (r.kind = 'weekend' and extract(dow from p_day)::smallint = any (r.weekdays)))), 1))
$$;

-- Free the beds of unpaid holds whose time ran out
create or replace function public._bp_expire(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  for r in select * from public.booking_requests
            where property_id = p_property and status in ('awaiting_payment','awaiting_confirmation') and expires_at < now()
            for update skip locked loop
    update public.bookings set status = 'cancelled', cancelled_at = now(),
           note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': ' ||
                  case when r.status = 'awaiting_payment' then 'advance not paid in time — beds released.' else 'not confirmed in time — beds released.' end), 2000)
     where id = any (r.booking_ids) and status = 'pending';
    update public.booking_requests set status = 'expired' where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- For a scheduled job (optional): expire everywhere
create or replace function public.bp_expire_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v int := 0; pid uuid;
begin
  for pid in select distinct property_id from public.booking_requests
              where status in ('awaiting_payment','awaiting_confirmation') and expires_at < now() loop
    v := v + public._bp_expire(pid);
  end loop;
  return v;
end $$;

create or replace function public._bp_page_by_slug(p_slug text) returns public.booking_pages
language sql stable security definer set search_path = public, pg_temp as $$
  select * from public.booking_pages where slug = lower(btrim(coalesce(p_slug, '')))
$$;

-- Licence documents on file (only if the My investment pack, 036, is installed)
create or replace function public._bp_licences(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  if to_regclass('public.legal_documents') is null then return '[]'::jsonb; end if;
  execute $q$select coalesce(jsonb_agg(distinct d.doc_type), '[]'::jsonb) from public.legal_documents d
             where d.property_id = $1 and d.doc_type in ('trade_licence','fire_noc','fssai','gst','police','tourism','building_approval','pollution')
               and (d.expires_on is null or d.expires_on >= $2)$q$
    into v using p_property, public._bp_today(p_property);
  return coalesce(v, '[]'::jsonb);
end $$;

-- What the guest's status page shows
create or replace function public._bp_request_json(r public.booking_requests) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('code', r.code, 'token', r.token, 'status', r.status, 'room_name', r.room_name, 'unit', r.unit,
           'units', r.units, 'guests', r.guests, 'check_in', r.check_in, 'check_out', r.check_out, 'nights', r.check_out - r.check_in,
           'guest_name', r.guest_name, 'total_paise', r.total_paise, 'advance_paise', r.advance_paise,
           'balance_paise', r.total_paise - r.advance_paise, 'utr', r.utr, 'expires_at', r.expires_at, 'beds_lost', r.beds_lost,
           'seconds_left', case when r.status = 'awaiting_payment' then greatest(0, extract(epoch from r.expires_at - now()))::int end,
           'property', jsonb_build_object('name', p.name, 'city', p.city, 'slug', bp.slug, 'upi_id', p.upi_id,
              'payee', left(coalesce(nullif(to_jsonb(p)->>'legal_name', ''), p.name), 50),
              'whatsapp', coalesce(bp.whatsapp, p.phone), 'checkin_time', to_char(p.checkin_time, 'HH24:MI'),
              'checkout_time', to_char(p.checkout_time, 'HH24:MI'), 'cancel_policy', bp.cancel_policy),
           'self_checkin_token', case when r.status = 'confirmed' then
              (select b.self_checkin_token from public.bookings b where b.id = r.booking_ids[1]) end)
    from public.properties p left join public.booking_pages bp on bp.property_id = p.id
   where p.id = r.property_id
$$;

-- ---------------------------------------------------------------- PUBLIC (guests, not signed in)
create or replace function public.bp_public(p_slug text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare bp public.booking_pages; p public.properties; v_open boolean; rv jsonb; rooms jsonb;
begin
  bp := public._bp_page_by_slug(p_slug);
  if bp.property_id is null then return jsonb_build_object('found', false); end if;
  select * into p from public.properties where id = bp.property_id;
  v_open := public._bp_open(p.id);
  if not bp.enabled then return jsonb_build_object('found', false); end if;
  perform public._bp_expire(p.id);
  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) into rv
    from (select jsonb_build_object('name', r.guest_name, 'rating', r.rating, 'body', r.body, 'stayed_on', to_char(r.stayed_on, 'Mon YYYY'),
                 'reply', r.reply) j, r.created_at
            from public.stay_reviews r where r.property_id = p.id and not r.hidden order by r.created_at desc limit 12) x;
  select coalesce(jsonb_agg(e - 'bed_ids' - 'room_id'), '[]'::jsonb) into rooms from jsonb_array_elements(public._bp_rooms(p.id)) e;
  return jsonb_build_object('found', true, 'open', v_open,
    'property', jsonb_build_object('name', p.name, 'kind', p.kind, 'city', p.city,
       'address', case when bp.show_address then p.address end, 'timezone', p.timezone,
       'checkin_time', to_char(p.checkin_time, 'HH24:MI'), 'checkout_time', to_char(p.checkout_time, 'HH24:MI'),
       'whatsapp', coalesce(bp.whatsapp, p.phone), 'instagram', bp.instagram, 'map_url', bp.map_url),
    'page', jsonb_build_object('slug', bp.slug, 'headline', bp.headline, 'about', bp.about, 'amenities', to_jsonb(bp.amenities),
       'house_rules', bp.house_rules, 'cancel_policy', bp.cancel_policy, 'photos', bp.photos,
       'advance_mode', case when bp.advance_mode <> 'none' and coalesce(p.upi_id, '') = '' then 'none' else bp.advance_mode end,
       'advance_pct', bp.advance_pct, 'approve_first', bp.approve_first or (bp.advance_mode <> 'none' and coalesce(p.upi_id, '') = ''),
       'hold_minutes', bp.hold_minutes, 'max_nights', bp.max_nights, 'book_ahead_days', bp.book_ahead_days),
    'today', public._bp_today(p.id),
    'rooms', rooms,
    'licences', case when bp.show_licences then public._bp_licences(p.id) else '[]'::jsonb end,
    'reviews', case when bp.show_reviews then jsonb_build_object(
        'count', (select count(*) from public.stay_reviews r where r.property_id = p.id and not r.hidden),
        'average', (select round(avg(r.rating)::numeric, 1) from public.stay_reviews r where r.property_id = p.id and not r.hidden),
        'items', rv) end);
end $$;

-- p_from .. p_to = check-in .. check-out (also used for the 2-week calendar strip)
create or replace function public.bp_availability(p_slug text, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare bp public.booking_pages; p public.properties; v_today date;
begin
  bp := public._bp_page_by_slug(p_slug);
  if bp.property_id is null or not bp.enabled then raise exception 'This booking page is not available.' using errcode = 'P0404'; end if;
  select * into p from public.properties where id = bp.property_id;
  v_today := public._bp_today(p.id);
  if p_from is null or p_to is null or p_to <= p_from then raise exception 'Choose a check-out date after check-in.'; end if;
  if p_from < v_today then raise exception 'Check-in can''t be in the past.'; end if;
  if p_to - p_from > 62 then raise exception 'Choose at most 62 nights.'; end if;
  if p_from > v_today + bp.book_ahead_days then raise exception 'Bookings open % days ahead.', bp.book_ahead_days; end if;
  perform public._bp_expire(p.id);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', g->>'id',
      'nights', (select jsonb_agg(jsonb_build_object('date', d::date,
            'free', public._bp_free(p, g->'bed_ids', public._bp_range(p, d::date, d::date + 1))
                    * (case when public._bp_open(p.id) then 1 else 0 end),
            'price_paise', public._night_rate(p.id, (g->>'room_id')::uuid, (g->>'rate_paise')::int, d::date),
            'min_stay', public._bp_min_stay(p.id, (g->>'room_id')::uuid, d::date)) order by d)
          from generate_series(p_from, p_to - 1, interval '1 day') d),
      'free_for_stay', public._bp_free(p, g->'bed_ids', public._bp_range(p, p_from, p_to)) * (case when public._bp_open(p.id) then 1 else 0 end),
      'stay_paise', (select sum(public._night_rate(p.id, (g->>'room_id')::uuid, (g->>'rate_paise')::int, d::date))
                       from generate_series(p_from, p_to - 1, interval '1 day') d)::int,
      'min_stay', (select max(public._bp_min_stay(p.id, (g->>'room_id')::uuid, d::date)) from generate_series(p_from, p_to - 1, interval '1 day') d)
    )), '[]'::jsonb)
    from jsonb_array_elements(public._bp_rooms(p.id)) g);
end $$;

-- p: { room_type, check_in, check_out, units, guests, name, phone, email?, note?, website? (left empty by people) }
create or replace function public.bp_request(p_slug text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  bp public.booking_pages; pr public.properties; g jsonb; v_today date; v_in date; v_out date; v_n int;
  v_units int; v_guests int; v_name text; v_phone text; v_mail text; v_note text; v_key text;
  v_guest uuid; v_bed uuid; v_bk uuid; v_ids uuid[] := '{}'; v_tries int; v_vis int; v_extra int;
  v_total int; v_adv int; v_status text; v_r public.booking_requests; v_code text; v_unit text; v_min int; v_maxg int;
begin
  bp := public._bp_page_by_slug(p_slug);
  if bp.property_id is null or not bp.enabled then raise exception 'This booking page is not available.' using errcode = 'P0404'; end if;
  if not public._bp_open(bp.property_id) then raise exception 'Online booking is paused right now — please message the host on WhatsApp.'; end if;
  if coalesce(p->>'website', '') <> '' then raise exception 'Please try again.'; end if;          -- form filled by a robot
  select * into pr from public.properties where id = bp.property_id;
  perform public._bp_expire(pr.id);
  v_today := public._bp_today(pr.id);

  select e into g from jsonb_array_elements(public._bp_rooms(pr.id)) e where e->>'id' = p->>'room_type';
  if g is null then raise exception 'Please choose a room or bed type.'; end if;
  begin v_in := (p->>'check_in')::date; v_out := (p->>'check_out')::date;
  exception when others then raise exception 'Choose your check-in and check-out dates.'; end;
  if v_in is null or v_out is null or v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;
  if v_in < v_today then raise exception 'Check-in can''t be in the past.'; end if;
  if v_in > v_today + bp.book_ahead_days then raise exception 'Bookings open % days ahead.', bp.book_ahead_days; end if;
  v_n := v_out - v_in;
  if v_n > bp.max_nights then raise exception 'You can book up to % nights online — message the host for longer stays.', bp.max_nights; end if;
  select max(public._bp_min_stay(pr.id, (g->>'room_id')::uuid, d::date)) into v_min from generate_series(v_in, v_out - 1, interval '1 day') d;
  if v_n < v_min then raise exception 'Minimum stay for these dates is % nights.', v_min; end if;

  v_unit := g->>'unit';
  v_units := coalesce(nullif(p->>'units', '')::int, 1);
  if v_units not between 1 and 10 then raise exception 'You can book 1 to 10 % at a time.', v_unit || 's'; end if;
  v_maxg := greatest(1, (g->>'max_guests')::int);
  v_guests := case when v_unit = 'bed' then v_units else coalesce(nullif(p->>'guests', '')::int, v_units) end;
  if v_guests < v_units then raise exception 'Each room needs at least one guest.'; end if;
  if v_guests > v_units * v_maxg then raise exception '% % fit up to % guests.', v_units, case when v_units = 1 then 'room' else 'rooms' end, v_units * v_maxg; end if;

  v_name := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  if char_length(v_name) < 2 or char_length(v_name) > 120 then raise exception 'Please enter your full name.'; end if;
  v_phone := public._clean_phone(p->>'phone');
  if v_phone is not null and v_phone ~ '^[6-9][0-9]{9}$' then v_phone := '+91' || v_phone; end if;
  if v_phone is null or v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please enter a WhatsApp number we can reach you on.'; end if;
  v_mail := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  if v_mail is not null and v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address looks wrong.'; end if;
  v_note := nullif(left(btrim(coalesce(p->>'note', '')), 500), '');

  -- limits against abuse
  v_key := public._bp_client_key();
  if v_key is not null and (select count(*) from public.booking_requests where client_key = v_key and created_at > now() - interval '1 hour') >= 6 then
    raise exception 'Too many booking attempts — please wait a while or message the host.';
  end if;
  if (select count(*) from public.booking_requests where property_id = pr.id and guest_phone = v_phone
        and status in ('awaiting_payment','awaiting_confirmation')) >= 2 then
    raise exception 'You already have a booking waiting — finish or cancel it first.';
  end if;
  if (select count(*) from public.booking_requests where property_id = pr.id and guest_phone = v_phone
        and created_at > now() - interval '24 hours' and status not in ('cancelled','expired','declined')) >= 3 then
    raise exception 'You have already booked here today — message the host on WhatsApp to add more.';
  end if;
  if (select count(*) from public.booking_requests where property_id = pr.id and status in ('awaiting_payment','awaiting_confirmation')) >= 25 then
    raise exception 'The page is busy — please try again in a few minutes.';
  end if;
  if public._bp_free(pr, g->'bed_ids', public._bp_range(pr, v_in, v_out)) < v_units then
    v_tries := public._bp_free(pr, g->'bed_ids', public._bp_range(pr, v_in, v_out));
    raise exception '%', case when v_tries = 0 then 'Sorry — fully booked for these dates.'
                              else format('Sorry — only %s %s free for these dates.', v_tries, v_unit || case when v_tries = 1 then '' else 's' end) end
      using errcode = 'P0409';
  end if;

  -- guest card (same phone at this property = same guest)
  select id into v_guest from public.guests where property_id = pr.id and phone = v_phone order by created_at limit 1;
  if v_guest is null then
    insert into public.guests (property_id, full_name, phone, email) values (pr.id, v_name, v_phone, v_mail) returning id into v_guest;
  elsif v_mail is not null then
    update public.guests set email = coalesce(email, v_mail) where id = v_guest;
  end if;

  v_code := 'WEB-' || nextval('public.booking_request_seq');
  v_status := case when bp.advance_mode <> 'none' and coalesce(pr.upi_id, '') <> '' then 'awaiting_payment'
                   when bp.approve_first or bp.advance_mode <> 'none' then 'awaiting_confirmation'
                   else 'confirmed' end;

  for i in 1 .. v_units loop
    v_vis := case when v_unit = 'bed' then 1 else v_guests / v_units + case when i <= v_guests % v_units then 1 else 0 end end;
    v_tries := 0;
    loop
      select bd.id, greatest(0, v_vis - coalesce(bd.base_guests, 1)) * coalesce(bd.extra_guest_paise, 0) into v_bed, v_extra
        from public.beds bd
       where bd.id in (select jsonb_array_elements_text(g->'bed_ids')::uuid) and bd.is_active and bd.id <> all (
               select k.bed_id from public.bookings k where k.id = any (v_ids))
         and coalesce(bd.max_guests, 1) >= v_vis
         and not exists (select 1 from public.bookings x where x.bed_id = bd.id and x.status in ('pending','confirmed','checked_in')
                           and x.stay && public._bp_range(pr, v_in, v_out))
         and not exists (select 1 from public.bed_blocks z where z.bed_id = bd.id and z.period && public._bp_range(pr, v_in, v_out))
       order by bd.sort, bd.label limit 1;
      if v_bed is null then raise exception 'Sorry — those were just booked. Please pick again.' using errcode = 'P0409'; end if;
      begin
        insert into public.bookings (property_id, guest_id, bed_id, visitors, extra_paise, check_in_at, check_out_at, nights,
                                     rate_paise, total_paise, status, source, note, send_confirmation, created_by)
        values (pr.id, v_guest, v_bed, v_vis, v_extra,
                (v_in::timestamp + pr.checkin_time) at time zone pr.timezone, (v_out::timestamp + pr.checkout_time) at time zone pr.timezone,
                v_n, (g->>'rate_paise')::int, v_n * ((g->>'rate_paise')::int + v_extra),
                case when v_status = 'confirmed' then 'confirmed' else 'pending' end::public.booking_status, 'direct',
                left(concat_ws(E'\n', 'Booking page ' || v_code || case v_status when 'awaiting_payment' then ' · waiting for UPI advance'
                                                                   when 'awaiting_confirmation' then ' · waiting for your OK' else '' end,
                               case when v_note is not null then 'Guest note: ' || v_note end), 2000),
                false, null)
        returning id into v_bk;
        v_ids := v_ids || v_bk;
        exit;
      exception when exclusion_violation then
        v_tries := v_tries + 1;
        if v_tries > 5 then raise exception 'Sorry — those were just booked. Please pick again.' using errcode = 'P0409'; end if;
      end;
    end loop;
  end loop;

  select sum(total_paise)::int into v_total from public.bookings where id = any (v_ids);    -- price rules already applied
  v_adv := case when v_status <> 'awaiting_payment' then 0
                when bp.advance_mode = 'percent' then least(v_total, (ceil(v_total * bp.advance_pct / 100.0 / 100.0) * 100)::int)
                else least(v_total, (select sum(public._night_rate(pr.id, b.room_id, b.rate_paise, v_in) + k.extra_paise)::int
                                       from public.bookings k join public.beds b on b.id = k.bed_id where k.id = any (v_ids))) end;
  if v_status = 'awaiting_payment' and v_adv = 0 then v_status := 'confirmed';
    update public.bookings set status = 'confirmed' where id = any (v_ids);
  end if;

  insert into public.booking_requests (property_id, code, status, booking_ids, room_type, room_name, unit, units, guests, check_in, check_out,
                                       guest_name, guest_phone, guest_email, guest_note, total_paise, advance_paise, expires_at, client_key,
                                       decided_at)
  values (pr.id, v_code, v_status, v_ids, g->>'id', g->>'name', v_unit, v_units, v_guests, v_in, v_out,
          v_name, v_phone, v_mail, v_note, v_total, v_adv,
          case v_status when 'awaiting_payment' then now() + make_interval(mins => bp.hold_minutes)
                        when 'awaiting_confirmation' then now() + interval '24 hours' end, v_key,
          case when v_status = 'confirmed' then now() end)
  returning * into v_r;

  if v_status = 'confirmed' then
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (pr.id, 'web_booking', 'Booking page: new booking ' || v_code,
            format('%s · %s %s · %s → %s · pays at the property', v_name, v_units, v_unit || case when v_units > 1 then 's' else '' end, to_char(v_in, 'DD Mon'), to_char(v_out, 'DD Mon')), v_ids[1]);
  end if;
  if v_status = 'awaiting_confirmation' then
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (pr.id, 'web_request', 'Booking page: ' || v_code || ' needs your OK',
            format('%s · %s %s · %s → %s', v_name, v_units, v_unit || case when v_units > 1 then 's' else '' end, to_char(v_in, 'DD Mon'), to_char(v_out, 'DD Mon')), v_ids[1]);
  end if;
  return public._bp_request_json(v_r);
end $$;

create or replace function public.bp_request_status(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests;
begin
  select property_id into r.property_id from public.booking_requests where token = p_token;
  if r.property_id is null then raise exception 'Booking not found — check the link.' using errcode = 'P0404'; end if;
  perform public._bp_expire(r.property_id);
  select * into r from public.booking_requests where token = p_token;
  return public._bp_request_json(r);
end $$;

-- Guest: "I've paid" + the UPI reference (UTR) from their payment app
create or replace function public.bp_claim_paid(p_token uuid, p_utr text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests; v_utr text;
begin
  select * into r from public.booking_requests where token = p_token for update;
  if not found then raise exception 'Booking not found — check the link.' using errcode = 'P0404'; end if;
  v_utr := upper(regexp_replace(coalesce(p_utr, ''), '[^0-9A-Za-z]', '', 'g'));
  if v_utr !~ '^[0-9A-Z]{6,35}$' then raise exception 'Enter the UPI reference (UTR) — usually 12 digits — from your payment app.'; end if;
  if r.status in ('payment_claimed','confirmed') and r.utr is not null then return public._bp_request_json(r); end if;
  if r.status not in ('awaiting_payment','expired') then raise exception 'This booking can''t take a payment now (%). Please message the host.', replace(r.status, '_', ' '); end if;
  if r.status = 'expired' and r.expires_at < now() - interval '24 hours' then
    raise exception 'This booking expired a while ago. If you paid, message the host with your UTR.';
  end if;
  if exists (select 1 from public.payments where property_id = r.property_id and method = 'upi' and reference = v_utr)
     or exists (select 1 from public.booking_requests where property_id = r.property_id and utr = v_utr and id <> r.id) then
    raise exception 'This UPI reference was already used for another booking. Check the number.';
  end if;
  if r.status = 'expired' then                                   -- paid a little late: try to get the beds back
    begin
      update public.bookings set status = 'pending', cancelled_at = null where id = any (r.booking_ids) and status = 'cancelled';
    exception when exclusion_violation then
      r.beds_lost := true;
    end;
  end if;
  update public.booking_requests set status = 'payment_claimed', utr = v_utr, claimed_at = now(), expires_at = null, beds_lost = r.beds_lost
   where id = r.id returning * into r;
  insert into public.notifications (property_id, kind, title, body, booking_id)
  values (r.property_id, 'web_paid', 'Booking page: ' || r.code || ' says advance paid',
          format('%s paid ₹%s · UTR %s — check your bank app and confirm.%s', r.guest_name, to_char(r.advance_paise / 100.0, 'FM99,99,99,990'), v_utr,
                 case when r.beds_lost then ' Beds were taken after the hold ran out — move or refund.' else '' end), r.booking_ids[1]);
  return public._bp_request_json(r);
end $$;

-- Guest cancels before paying
create or replace function public.bp_cancel_request(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests;
begin
  select * into r from public.booking_requests where token = p_token for update;
  if not found then raise exception 'Booking not found — check the link.' using errcode = 'P0404'; end if;
  if r.status not in ('awaiting_payment','awaiting_confirmation') then
    raise exception 'This booking can''t be cancelled here — please message the host.';
  end if;
  update public.bookings set status = 'cancelled', cancelled_at = now(),
         note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': cancelled by the guest before paying.'), 2000)
   where id = any (r.booking_ids) and status = 'pending';
  update public.booking_requests set status = 'cancelled', expires_at = null where id = r.id returning * into r;
  return public._bp_request_json(r);
end $$;

-- Reviews: the link carries the booking's own private token (the self check-in token)
create or replace function public.bp_review_get(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; p public.properties; g public.guests; rv public.stay_reviews;
begin
  select * into b from public.bookings where self_checkin_token = p_token;
  if not found then raise exception 'Review link not found.' using errcode = 'P0404'; end if;
  select * into p from public.properties where id = b.property_id;
  select * into g from public.guests where id = b.guest_id;
  select * into rv from public.stay_reviews where booking_id = b.id;
  return jsonb_build_object('property', p.name, 'slug', (select slug from public.booking_pages where property_id = p.id),
    'can_review', b.status = 'checked_out' and coalesce(b.departed_at, b.check_out_at) > now() - interval '90 days',
    'status', b.status, 'check_in', public._local_date(p.id, b.check_in_at), 'check_out', public._local_date(p.id, b.check_out_at),
    'first_name', split_part(g.full_name, ' ', 1),
    'review', case when rv.id is not null then jsonb_build_object('rating', rv.rating, 'body', rv.body, 'name', rv.guest_name) end);
end $$;

create or replace function public.bp_review_submit(p_token uuid, p_rating int, p_body text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; v_new boolean;
begin
  select * into b from public.bookings where self_checkin_token = p_token;
  if not found then raise exception 'Review link not found.' using errcode = 'P0404'; end if;
  if b.status <> 'checked_out' then raise exception 'You can review after you check out.'; end if;
  if coalesce(b.departed_at, b.check_out_at) < now() - interval '90 days' then raise exception 'Reviews are open for 90 days after the stay.'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose 1 to 5 stars.'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 60 then raise exception 'Add the name to show with your review (e.g. Ananya, Bengaluru).'; end if;
  v_new := not exists (select 1 from public.stay_reviews where booking_id = b.id);
  insert into public.stay_reviews (property_id, booking_id, guest_name, rating, body, stayed_on)
  values (b.property_id, b.id, btrim(p_name), p_rating, nullif(left(btrim(coalesce(p_body, '')), 1000), ''), public._local_date(b.property_id, b.check_in_at))
  on conflict (booking_id) do update set guest_name = excluded.guest_name, rating = excluded.rating, body = excluded.body, updated_at = now();
  if v_new then
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (b.property_id, 'web_review', 'New review · ' || repeat('★', p_rating), btrim(p_name) || ' · ' || b.code, b.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- STAFF (signed in)
create or replace function public.bp_settings_get(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role public.member_role; bp public.booking_pages; p public.properties; v_slug text; n int := 1;
begin
  v_role := public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  select * into p from public.properties where id = p_property;
  select * into bp from public.booking_pages where property_id = p_property;
  if bp.property_id is null then                                  -- suggest an address from the name
    v_slug := trim(both '-' from regexp_replace(regexp_replace(lower(p.name), '[^a-z0-9]+', '-', 'g'), '-+', '-', 'g'));
    if char_length(v_slug) < 3 then v_slug := 'stay-' || substr(replace(p.id::text, '-', ''), 1, 6); end if;
    v_slug := left(v_slug, 44);
    while exists (select 1 from public.booking_pages where slug = v_slug) loop
      n := n + 1; v_slug := left(regexp_replace(v_slug, '-[0-9]+$', ''), 44) || '-' || n;
    end loop;
  end if;
  return jsonb_build_object('role', v_role, 'exists', bp.property_id is not null,
    'page', case when bp.property_id is not null then to_jsonb(bp) - 'property_id' else jsonb_build_object(
       'slug', v_slug, 'enabled', false, 'headline', null, 'about', null, 'amenities', '[]'::jsonb, 'house_rules',
       'Check-in from ' || to_char(p.checkin_time, 'HH12:MI AM') || ' · Check-out by ' || to_char(p.checkout_time, 'HH12:MI AM') || E'\nGovernment photo ID needed at check-in',
       'cancel_policy', 'Free cancellation up to 3 days before check-in — the advance is refunded by UPI. After that, the advance is kept.',
       'advance_mode', 'none', 'advance_pct', 30, 'approve_first', false, 'hold_minutes', 30, 'max_nights', 30, 'book_ahead_days', 365,
       'whatsapp', null, 'instagram', null, 'map_url', null, 'show_address', true, 'show_licences', true, 'show_reviews', true, 'photos', '[]'::jsonb) end,
    'property', jsonb_build_object('name', p.name, 'kind', p.kind, 'city', p.city, 'phone', p.phone, 'upi_id', p.upi_id,
       'is_pg', coalesce((to_jsonb(p)->>'is_pg')::boolean, false)),
    'access', public._access_state(p_property),
    'rooms', (select count(*) from jsonb_array_elements(public._bp_rooms(p_property))),
    'licences', public._bp_licences(p_property),
    'licences_installed', to_regclass('public.legal_documents') is not null);
end $$;

create or replace function public.bp_slug_free(p_property uuid, p_slug text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return not exists (select 1 from public.booking_pages where slug = lower(btrim(p_slug)) and property_id <> p_property)
     and lower(btrim(p_slug)) not in ('admin','api','app','www','stay','demo','login','signup','help','support','nammastay','test','book','booking');
end $$;

-- Owner only. p: any of the booking_pages columns
create or replace function public.bp_settings_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_slug text; v_photos jsonb; v_am text[]; v_wa text; v_mode text; pr public.properties;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select * into pr from public.properties where id = p_property;
  v_slug := lower(btrim(coalesce(p->>'slug', '')));
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$' or v_slug ~ '--' then
    raise exception 'Page address: 3–50 letters, numbers and single dashes (e.g. social-backpackers-gokarna).';
  end if;
  if not public.bp_slug_free(p_property, v_slug) then raise exception 'That page address is taken — try adding your town.'; end if;
  v_mode := coalesce(nullif(p->>'advance_mode', ''), 'none');
  if coalesce((p->>'enabled')::boolean, false) then
    if coalesce((to_jsonb(pr)->>'is_pg')::boolean, false) then raise exception 'The booking page is for nightly stays — it is off while PG mode is on.'; end if;
    if jsonb_array_length(public._bp_rooms(p_property)) = 0 then raise exception 'Add your rooms and beds first (Rooms & beds).'; end if;
    if v_mode <> 'none' and coalesce(pr.upi_id, '') = '' then
      raise exception 'Add your UPI ID first (Settings → Payments) — guests pay the advance straight to it. Or choose "No advance".';
    end if;
  end if;
  v_photos := coalesce(p->'photos', '[]'::jsonb);
  if jsonb_typeof(v_photos) <> 'array' or jsonb_array_length(v_photos) > 12 then raise exception 'Up to 12 photos.'; end if;
  if exists (select 1 from jsonb_array_elements(v_photos) e
              where coalesce(e->>'path', '') not like p_property::text || '/%' or e->>'path' ~ '\.\.' or char_length(coalesce(e->>'caption', '')) > 80) then
    raise exception 'Photo list is invalid — please upload again.';
  end if;
  v_photos := (select coalesce(jsonb_agg(jsonb_build_object('path', e->>'path', 'caption', nullif(btrim(coalesce(e->>'caption', '')), ''))), '[]'::jsonb)
                 from jsonb_array_elements(v_photos) e);
  select coalesce(array_agg(x), '{}') into v_am from (
    select distinct on (lower(btrim(a))) left(btrim(a), 40) x from jsonb_array_elements_text(coalesce(p->'amenities', '[]'::jsonb)) a
     where btrim(a) <> '' limit 30) s;
  v_wa := public._clean_phone(p->>'whatsapp');
  if v_wa ~ '^[6-9][0-9]{9}$' then v_wa := '+91' || v_wa; end if;

  insert into public.booking_pages as bp (property_id, slug, enabled, headline, about, amenities, house_rules, cancel_policy, advance_mode, advance_pct,
       approve_first, hold_minutes, max_nights, book_ahead_days, whatsapp, instagram, map_url, show_address, show_licences, show_reviews, photos)
  values (p_property, v_slug, coalesce((p->>'enabled')::boolean, false), nullif(btrim(p->>'headline'), ''), nullif(btrim(p->>'about'), ''), v_am,
       nullif(btrim(p->>'house_rules'), ''), nullif(btrim(p->>'cancel_policy'), ''), v_mode, coalesce(nullif(p->>'advance_pct', '')::int, 30),
       coalesce((p->>'approve_first')::boolean, false), coalesce(nullif(p->>'hold_minutes', '')::int, 30), coalesce(nullif(p->>'max_nights', '')::int, 30),
       coalesce(nullif(p->>'book_ahead_days', '')::int, 365), v_wa, nullif(ltrim(btrim(coalesce(p->>'instagram', '')), '@'), ''),
       nullif(btrim(p->>'map_url'), ''), coalesce((p->>'show_address')::boolean, true), coalesce((p->>'show_licences')::boolean, true),
       coalesce((p->>'show_reviews')::boolean, true), v_photos)
  on conflict (property_id) do update set slug = excluded.slug, enabled = excluded.enabled, headline = excluded.headline, about = excluded.about,
       amenities = excluded.amenities, house_rules = excluded.house_rules, cancel_policy = excluded.cancel_policy, advance_mode = excluded.advance_mode,
       advance_pct = excluded.advance_pct, approve_first = excluded.approve_first, hold_minutes = excluded.hold_minutes, max_nights = excluded.max_nights,
       book_ahead_days = excluded.book_ahead_days, whatsapp = excluded.whatsapp, instagram = excluded.instagram, map_url = excluded.map_url,
       show_address = excluded.show_address, show_licences = excluded.show_licences, show_reviews = excluded.show_reviews, photos = excluded.photos,
       updated_at = now();
  return public.bp_settings_get(p_property);
end $$;

-- Owner + manager: requests from the page (newest first). p_filter: 'open' (needs action) | 'all'
create or replace function public.bp_requests(p_property uuid, p_filter text default 'open') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._bp_expire(p_property);
  return jsonb_build_object(
    'counts', jsonb_build_object(
       'needs_action', (select count(*) from public.booking_requests where property_id = p_property and status in ('payment_claimed','awaiting_confirmation')),
       'waiting_payment', (select count(*) from public.booking_requests where property_id = p_property and status = 'awaiting_payment'),
       'confirmed_30d', (select count(*) from public.booking_requests where property_id = p_property and status = 'confirmed' and created_at > now() - interval '30 days'),
       'value_30d', (select coalesce(sum(total_paise), 0) from public.booking_requests where property_id = p_property and status = 'confirmed' and created_at > now() - interval '30 days')),
    'items', coalesce((select jsonb_agg(x.j order by x.ord, x.created_at desc) from (
       select jsonb_build_object('id', r.id, 'code', r.code, 'token', r.token, 'status', r.status, 'room_name', r.room_name, 'unit', r.unit,
                'units', r.units, 'guests', r.guests, 'check_in', r.check_in, 'check_out', r.check_out, 'nights', r.check_out - r.check_in,
                'guest_name', r.guest_name, 'guest_phone', r.guest_phone, 'guest_email', r.guest_email, 'guest_note', r.guest_note,
                'total_paise', r.total_paise, 'advance_paise', r.advance_paise, 'utr', r.utr, 'claimed_at', r.claimed_at, 'beds_lost', r.beds_lost,
                'expires_at', r.expires_at, 'decided_at', r.decided_at, 'owner_note', r.owner_note, 'created_at', r.created_at,
                'bookings', (select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'status', b.status, 'bed', bd.label, 'paid_paise', b.paid_paise,
                                 'self_checkin_token', b.self_checkin_token) order by b.code)
                               from public.bookings b join public.beds bd on bd.id = b.bed_id where b.id = any (r.booking_ids))) j,
              r.created_at,
              case r.status when 'payment_claimed' then 0 when 'awaiting_confirmation' then 1 when 'awaiting_payment' then 2 else 3 end ord
         from public.booking_requests r
        where r.property_id = p_property
          and (coalesce(p_filter, 'open') = 'all' or r.status in ('payment_claimed','awaiting_confirmation','awaiting_payment')
               or (r.status in ('confirmed','declined') and r.decided_at > now() - interval '2 days'))
        order by ord, r.created_at desc limit 200) x), '[]'::jsonb));
end $$;

-- p_action: 'confirm' (advance received → recorded as a UPI payment) | 'confirm_unpaid' (confirm without recording money)
--           | 'decline' (beds released; if the guest paid, refund them)
create or replace function public.bp_request_decide(p_id uuid, p_action text, p_amount int default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.booking_requests; v_left int; v_amt int; v_part int; b record; i int := 0; v_ref text;
begin
  select * into r from public.booking_requests where id = p_id for update;
  if not found then raise exception 'Request not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(r.property_id, array['owner','manager']::public.member_role[]);
  if p_action not in ('confirm','confirm_unpaid','decline') then raise exception 'Unknown action.'; end if;
  if r.status in ('confirmed','declined','cancelled') then raise exception 'Already %.', r.status; end if;
  if r.status = 'expired' and p_action <> 'decline' then
    -- late OK from the owner: take the beds back if still free
    begin
      update public.bookings set status = 'pending', cancelled_at = null where id = any (r.booking_ids) and status = 'cancelled';
    exception when exclusion_violation then
      raise exception 'The hold ran out and those beds/rooms are booked now. Decline, or book the guest into other beds from Bookings.';
    end;
  end if;

  if p_action = 'decline' then
    update public.bookings set status = 'cancelled', cancelled_at = now(),
           note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': declined' || coalesce(' — ' || nullif(btrim(p_note), ''), '')), 2000)
     where id = any (r.booking_ids) and status in ('pending','confirmed');
    update public.booking_requests set status = 'declined', decided_at = now(), decided_by = auth.uid(), owner_note = nullif(left(btrim(coalesce(p_note, '')), 500), '')
     where id = r.id returning * into r;
    return jsonb_build_object('status', r.status, 'refund_paise', case when r.utr is not null then r.advance_paise else 0 end);
  end if;

  if r.beds_lost and exists (select 1 from public.bookings where id = any (r.booking_ids) and status = 'cancelled') then
    raise exception 'Those beds/rooms were booked by someone else after the hold ran out. Decline (and refund), or book the guest into other beds from Bookings.';
  end if;

  update public.bookings set status = 'confirmed',
         note = left(concat_ws(E'\n', note, 'Booking page ' || r.code || ': confirmed'), 2000)
   where id = any (r.booking_ids) and status = 'pending';

  if p_action = 'confirm' and r.status in ('payment_claimed','awaiting_payment','expired') then
    v_amt := coalesce(p_amount, r.advance_paise);
    if v_amt <= 0 or v_amt > r.total_paise then raise exception 'Amount received must be between ₹1 and the booking total.'; end if;
    v_left := v_amt;
    for b in select k.id, k.total_paise - k.paid_paise as due from public.bookings k where k.id = any (r.booking_ids) order by k.code loop
      exit when v_left <= 0;
      i := i + 1;
      v_part := case when i = r.units then v_left else least(v_left, greatest(b.due, 0)) end;
      continue when v_part <= 0;
      v_ref := case when r.utr is null then null when i = 1 then r.utr else left(r.utr, 60) || '-' || i end;
      begin
        insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, note)
        values (r.property_id, b.id, 'payment', 'upi', v_part, v_ref, 'Advance via booking page ' || r.code);
      exception when unique_violation then
        raise exception 'UPI reference % is already recorded on another payment — check it in Payments.', r.utr;
      end;
      v_left := v_left - v_part;
    end loop;
  end if;

  update public.booking_requests set status = 'confirmed', decided_at = now(), decided_by = auth.uid(),
         owner_note = nullif(left(btrim(coalesce(p_note, '')), 500), ''),
         advance_paise = case when p_action = 'confirm' and r.status <> 'awaiting_confirmation' then coalesce(p_amount, r.advance_paise) else r.advance_paise end
   where id = r.id returning * into r;
  return jsonb_build_object('status', r.status, 'refund_paise', 0);
end $$;

-- Owner + manager: the number for the menu badge (requests that need a tap)
create or replace function public.bp_counts(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if not exists (select 1 from public.booking_pages where property_id = p_property) then return 0; end if;
  perform public._bp_expire(p_property);
  return (select count(*) from public.booking_requests where property_id = p_property and status in ('payment_claimed','awaiting_confirmation'));
end $$;

-- Owner + manager: reviews, and recent guests to ask
create or replace function public.bp_reviews(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return jsonb_build_object(
    'average', (select round(avg(rating)::numeric, 1) from public.stay_reviews where property_id = p_property and not hidden),
    'count', (select count(*) from public.stay_reviews where property_id = p_property and not hidden),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.guest_name, 'rating', r.rating, 'body', r.body, 'stayed_on', r.stayed_on,
               'hidden', r.hidden, 'reply', r.reply, 'created_at', r.created_at, 'booking_code', b.code) order by r.created_at desc)
             from public.stay_reviews r join public.bookings b on b.id = r.booking_id where r.property_id = p_property), '[]'::jsonb),
    'ask', coalesce((select jsonb_agg(x.j order by x.out_at desc) from (
             select jsonb_build_object('booking_id', b.id, 'code', b.code, 'guest_name', g.full_name, 'phone', g.phone,
                      'check_out', public._local_date(p_property, b.check_out_at), 'token', b.self_checkin_token) j, b.check_out_at out_at
               from public.bookings b join public.guests g on g.id = b.guest_id
              where b.property_id = p_property and b.status = 'checked_out' and g.phone is not null
                and coalesce(b.departed_at, b.check_out_at) > now() - interval '30 days'
                and not exists (select 1 from public.stay_reviews r where r.booking_id = b.id)
              order by b.check_out_at desc limit 30) x), '[]'::jsonb));
end $$;

create or replace function public.bp_review_moderate(p_id uuid, p_hidden boolean, p_reply text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.stay_reviews where id = p_id;
  if v_prop is null then raise exception 'Review not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  update public.stay_reviews set hidden = coalesce(p_hidden, hidden), reply = nullif(left(btrim(coalesce(p_reply, '')), 600), ''),
         replied_at = case when nullif(btrim(coalesce(p_reply, '')), '') is distinct from reply then now() else replied_at end, updated_at = now()
   where id = p_id;
end $$;

-- ---------------------------------------------------------------- who may call what
do $$ declare f text; begin
  foreach f in array array['bp_public(text)','bp_availability(text,date,date)','bp_request(text,jsonb)','bp_request_status(uuid)',
      'bp_claim_paid(uuid,text)','bp_cancel_request(uuid)','bp_review_get(uuid)','bp_review_submit(uuid,integer,text,text)'] loop
    execute 'revoke execute on function public.' || f || ' from public';
    execute 'grant execute on function public.' || f || ' to anon, authenticated';
  end loop;
  foreach f in array array['bp_counts(uuid)','bp_settings_get(uuid)','bp_slug_free(uuid,text)','bp_settings_save(uuid,jsonb)','bp_requests(uuid,text)',
      'bp_request_decide(uuid,text,integer,text)','bp_reviews(uuid)','bp_review_moderate(uuid,boolean,text)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
  foreach f in array array['_bp_today(uuid)','_bp_open(uuid)','_bp_client_key()','_bp_range(public.properties,date,date)','_bp_rooms(uuid)',
      '_bp_free(public.properties,jsonb,tstzrange)','_bp_min_stay(uuid,uuid,date)','_bp_expire(uuid)','bp_expire_all()','_bp_page_by_slug(text)',
      '_bp_licences(uuid)','_bp_request_json(public.booking_requests)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

-- Check: should say true
select to_regclass('public.booking_pages') is not null and to_regclass('public.booking_requests') is not null
   and to_regclass('public.stay_reviews') is not null
   and exists (select 1 from storage.buckets where id = 'stay-photos' and public) as booking_page_installed;
