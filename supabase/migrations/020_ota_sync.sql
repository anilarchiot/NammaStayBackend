-- =====================================================================
-- NammaStay · 020_ota_sync.sql
-- OTA calendar sync (iCal) — Airbnb, Booking.com, Agoda, Vrbo, Google…
--   EXPORT: every bed/room has a secret calendar link (beds.ical_token).
--           OTAs import it, so nights booked or blocked in NammaStay are
--           closed there too. Served by the `ical` edge function.
--   IMPORT: each bed/room can have OTA calendar links (ota_feeds). The
--           `ota-sync` edge function fetches them (every 30 min + "Sync
--           now") and calls ota_apply(), which turns OTA reservations into
--           calendar blocks ("🔗 Airbnb · reserved") so staff can't
--           double-book them. Clashes with NammaStay bookings → alert.
-- iCal shares availability only — not prices, guest names or payments.
-- Run AFTER 019_prices_oct_2026.sql. Then deploy the two edge functions
-- and run setup/ota_schedule.sql (see docs/GO-LIVE.md §35).
-- =====================================================================

alter table public.beds add column if not exists ical_token uuid not null default gen_random_uuid();
create unique index if not exists beds_ical_token on public.beds (ical_token);

create table if not exists public.ota_feeds (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null,
  bed_id         uuid not null,
  channel        text not null check (channel in ('airbnb','booking','agoda','vrbo','google','other')),
  import_url     text not null check (import_url ~ '^https://' and char_length(import_url) <= 1000),
  label          text check (char_length(label) <= 60),
  last_synced_at timestamptz,
  last_status    text check (last_status in ('ok','error')),
  last_error     text check (char_length(last_error) <= 300),
  events_count   int not null default 0,
  created_at     timestamptz not null default now(),
  foreign key (bed_id, property_id) references public.beds(id, property_id) on delete cascade,
  unique (bed_id, import_url)
);
create index if not exists ota_feeds_prop on public.ota_feeds (property_id);

alter table public.bed_blocks
  add column if not exists feed_id uuid references public.ota_feeds(id) on delete cascade,
  add column if not exists external_uid text check (char_length(external_uid) <= 300);
create unique index if not exists bed_blocks_feed_uid on public.bed_blocks (feed_id, external_uid) where feed_id is not null;

alter table public.ota_feeds enable row level security;
create policy ota_feeds_select on public.ota_feeds for select to authenticated
  using (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])));
revoke all on public.ota_feeds from anon, authenticated;
grant select on public.ota_feeds to authenticated;

-- ---------------------------------------------------------------- staff (owner / manager with "rooms & prices")
create or replace function public.ota_overview(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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

create or replace function public.ota_feed_save(p_property uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.ota_feed_delete(p_feed uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.ota_feeds where id = p_feed;
  if v_prop is null then raise exception 'Calendar link not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  perform public._require_perm(v_prop, 'manage_rooms');
  delete from public.ota_feeds where id = p_feed;                 -- its imported blocks go too
end $$;

-- New secret link for one bed/room (if the old one was shared by mistake)
create or replace function public.ota_new_token(p_bed uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid; v_tok uuid := gen_random_uuid();
begin
  select property_id into v_prop from public.beds where id = p_bed;
  if v_prop is null then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  update public.beds set ical_token = v_tok where id = p_bed;
  return v_tok;
end $$;

-- Feeds the `ota-sync` function may refresh for this person (checks their role)
create or replace function public.ota_feeds_for_sync(p_property uuid) returns setof uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query select id from public.ota_feeds where property_id = p_property;
end $$;

-- ---------------------------------------------------------------- server only (edge functions, service role)
-- Calendar export for one bed/room. p_exclude: skip blocks imported from this channel (avoids echoing an OTA's own bookings back).
create or replace function public.ota_export(p_token uuid, p_exclude text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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

create or replace function public.ota_due_feeds(p_limit int default 300) returns setof public.ota_feeds
language sql stable security definer set search_path = public, pg_temp as $$
  select f.* from public.ota_feeds f join public.beds b on b.id = f.bed_id
   where b.is_active and public._access_state(f.property_id) not in ('expired','suspended')
   order by f.last_synced_at nulls first limit least(greatest(coalesce(p_limit, 300), 1), 1000)
$$;

-- p_events: [{ "uid": "...", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD" }]  (end = check-out day)
-- or p_error: why fetching/parsing failed.
create or replace function public.ota_apply(p_feed uuid, p_events jsonb, p_error text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------- permissions
revoke execute on function public.ota_overview(uuid), public.ota_feed_save(uuid, jsonb), public.ota_feed_delete(uuid),
  public.ota_new_token(uuid), public.ota_feeds_for_sync(uuid), public.ota_export(uuid, text), public.ota_due_feeds(int),
  public.ota_apply(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.ota_overview(uuid), public.ota_feed_save(uuid, jsonb), public.ota_feed_delete(uuid),
  public.ota_new_token(uuid), public.ota_feeds_for_sync(uuid) to authenticated;
grant execute on function public.ota_export(uuid, text), public.ota_due_feeds(int), public.ota_apply(uuid, jsonb, text) to service_role;
