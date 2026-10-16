-- =====================================================================
-- NammaStay · 026_pricing_housekeeping.sql
--   1. Seasonal & weekend pricing — price rules per property:
--        weekend (e.g. Fri + Sat nights +20%), season / dates
--        (e.g. 20 Dec – 5 Jan +30%, or a fixed ₹1,200), optional rooms,
--        optional minimum stay. Applied automatically when a booking is
--        made or its dates / bed change; the stay's nightly rate becomes
--        the average of its nights, so every total, invoice and discount
--        stays consistent. Rates shown while booking include the rules.
--   2. Housekeeping board — each bed/room is Clean / Dirty / Cleaning /
--        Inspect; check-out marks it Dirty automatically.
-- Run AFTER 025_admin_growth.sql.
-- =====================================================================

-- ---------------------------------------------------------------- 1. price rules
create table if not exists public.rate_rules (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 60),
  kind        text not null check (kind in ('weekend','season')),
  weekdays    smallint[] check (weekdays is null or weekdays <@ array[0,1,2,3,4,5,6]::smallint[]),   -- nights: 0 = Sunday … 6 = Saturday
  date_from   date,
  date_to     date,                                               -- last night included
  adjust      text not null check (adjust in ('percent','amount','fixed')),
  value       int  not null,                                      -- percent (-90…300) · ₹ in paise (+/-) · fixed price in paise
  room_ids    uuid[],                                             -- null = all rooms
  min_nights  smallint check (min_nights is null or min_nights between 2 and 30),
  priority    smallint not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  check (kind <> 'weekend' or (weekdays is not null and cardinality(weekdays) > 0)),
  check (kind <> 'season' or (date_from is not null and date_to is not null and date_to >= date_from)),
  check (adjust <> 'percent' or value between -90 and 300),
  check (adjust <> 'fixed' or value > 0)
);
create index if not exists rate_rules_prop on public.rate_rules (property_id) where is_active;
alter table public.rate_rules enable row level security;
drop policy if exists rate_rules_select on public.rate_rules;
create policy rate_rules_select on public.rate_rules for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.rate_rules from anon, authenticated;
grant select on public.rate_rules to authenticated;

-- The price of one night (property local date) for a bed/room with base rate p_base
create or replace function public._night_rate(p_property uuid, p_room uuid, p_base int, p_day date) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(0, coalesce((
    select case r.adjust when 'percent' then round(p_base * (100 + r.value) / 100.0)::int when 'amount' then p_base + r.value else r.value end
      from public.rate_rules r
     where r.property_id = p_property and r.is_active and (r.room_ids is null or p_room = any (r.room_ids))
       and ((r.kind = 'weekend' and extract(dow from p_day)::smallint = any (r.weekdays))
         or (r.kind = 'season' and p_day between r.date_from and r.date_to
             and (r.weekdays is null or extract(dow from p_day)::smallint = any (r.weekdays))))
     order by (r.kind = 'season') desc, r.priority desc, r.created_at desc limit 1), p_base))
$$;

-- Average nightly rate for a stay (rounded to the paise) and the longest minimum-stay rule it touches
create or replace function public._stay_rate(p_bed uuid, p_in timestamptz, p_out timestamptz, p_base int default null)
returns table (rate_paise int, min_nights int, rule_names text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare bd public.beds%rowtype; tz text; d0 date; d1 date; n int; total bigint := 0; d date; base int;
begin
  select * into bd from public.beds where id = p_bed;
  select timezone into tz from public.properties where id = bd.property_id;
  base := coalesce(p_base, bd.rate_paise);
  d0 := (p_in at time zone tz)::date; d1 := (p_out at time zone tz)::date;
  if d1 <= d0 then d1 := d0 + 1; end if;
  n := d1 - d0;
  for d in select generate_series(d0, d1 - 1, interval '1 day')::date loop
    total := total + public._night_rate(bd.property_id, bd.room_id, base, d);
  end loop;
  return query select round(total::numeric / n)::int,
    coalesce((select max(r.min_nights) from public.rate_rules r
               where r.property_id = bd.property_id and r.is_active and r.min_nights is not null
                 and (r.room_ids is null or bd.room_id = any (r.room_ids))
                 and ((r.kind = 'season' and r.date_from <= d1 - 1 and r.date_to >= d0)
                   or (r.kind = 'weekend' and exists (select 1 from generate_series(d0, d1 - 1, interval '1 day') g
                                                        where extract(dow from g)::smallint = any (r.weekdays))))), 0)::int,
    (select string_agg(distinct r.name, ', ') from public.rate_rules r
      where r.property_id = bd.property_id and r.is_active and (r.room_ids is null or bd.room_id = any (r.room_ids))
        and exists (select 1 from generate_series(d0, d1 - 1, interval '1 day') g
                     where (r.kind = 'weekend' and extract(dow from g)::smallint = any (r.weekdays))
                        or (r.kind = 'season' and g::date between r.date_from and r.date_to)));
end $$;

-- Apply the rules to bookings (new bookings; date or bed changes)
create or replace function public._apply_rate_rules() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare s record; base int;
begin
  if new.status not in ('pending','confirmed','checked_in') then return new; end if;
  if not exists (select 1 from public.rate_rules where property_id = new.property_id and is_active) then return new; end if;
  if tg_op = 'UPDATE' then
    if (new.check_in_at, new.check_out_at, new.bed_id) is not distinct from (old.check_in_at, old.check_out_at, old.bed_id) then return new; end if;
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
drop trigger if exists bookings_rate_rules on public.bookings;
create trigger bookings_rate_rules before insert or update of check_in_at, check_out_at, bed_id on public.bookings
  for each row execute function public._apply_rate_rules();

-- Rooms shown while booking: price for these dates (rules included)
create or replace function public.available_beds(p_property uuid, p_in timestamptz, p_out timestamptz)
returns table (id uuid, label text, room_id uuid, room_name text, rate_paise int,
               max_guests smallint, base_guests smallint, extra_guest_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query
  select bd.id, bd.label, r.id, r.name, (select s.rate_paise from public._stay_rate(bd.id, p_in, p_out, bd.rate_paise) s),
         bd.max_guests, bd.base_guests, bd.extra_guest_paise
    from public.beds bd join public.rooms r on r.id = bd.room_id
   where bd.property_id = p_property and bd.is_active
     and not exists (select 1 from public.bookings b where b.bed_id = bd.id
                      and b.status in ('pending','confirmed','checked_in')
                      and b.stay && tstzrange(p_in, p_out, '[)'))
     and not exists (select 1 from public.bed_blocks k where k.bed_id = bd.id
                      and k.period && tstzrange(p_in, p_out, '[)'))
   order by r.sort, r.name, bd.sort, bd.label;
end $$;

-- p: { id?, name, kind, weekdays[], date_from, date_to, adjust, value (percent number or rupees), room_ids[], min_nights, priority, is_active }
create or replace function public.rate_rule_save(p_property uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_adj text := coalesce(p->>'adjust', 'percent'); v_val numeric := nullif(p->>'value', '')::numeric; v_kind text := coalesce(p->>'kind', 'weekend');
  v_days smallint[] := case when jsonb_typeof(p->'weekdays') = 'array' and jsonb_array_length(p->'weekdays') > 0 then array(select (x)::smallint from jsonb_array_elements_text(p->'weekdays') x) end;
  v_rooms uuid[] := case when jsonb_typeof(p->'room_ids') = 'array' and jsonb_array_length(p->'room_ids') > 0 then array(select (x)::uuid from jsonb_array_elements_text(p->'room_ids') x) end;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  perform public._require_perm(p_property, 'manage_rooms');
  if v_val is null then raise exception 'Enter the price change.'; end if;
  if v_kind = 'weekend' and v_days is null then raise exception 'Pick at least one night of the week.'; end if;
  if v_kind = 'season' and (nullif(p->>'date_from', '') is null or nullif(p->>'date_to', '') is null) then raise exception 'Pick the first and last night.'; end if;
  if v_rooms is not null and exists (select 1 from unnest(v_rooms) x where x not in (select id from public.rooms where property_id = p_property)) then raise exception 'Unknown room.'; end if;
  v_val := case v_adj when 'percent' then round(v_val) else round(v_val * 100) end;      -- ₹ → paise
  if nullif(p->>'id', '') is null then
    insert into public.rate_rules (property_id, name, kind, weekdays, date_from, date_to, adjust, value, room_ids, min_nights, priority, is_active)
    values (p_property, btrim(p->>'name'), v_kind, v_days, nullif(p->>'date_from', '')::date, nullif(p->>'date_to', '')::date, v_adj, v_val::int, v_rooms,
            nullif(p->>'min_nights', '')::smallint, coalesce(nullif(p->>'priority', '')::smallint, 0), coalesce((p->>'is_active')::boolean, true))
    returning id into v_id;
  else
    update public.rate_rules set name = btrim(p->>'name'), kind = v_kind, weekdays = v_days, date_from = nullif(p->>'date_from', '')::date,
           date_to = nullif(p->>'date_to', '')::date, adjust = v_adj, value = v_val::int, room_ids = v_rooms, min_nights = nullif(p->>'min_nights', '')::smallint,
           priority = coalesce(nullif(p->>'priority', '')::smallint, 0), is_active = coalesce((p->>'is_active')::boolean, true)
     where id = (p->>'id')::uuid and property_id = p_property returning id into v_id;
    if v_id is null then raise exception 'Price rule not found.'; end if;
  end if;
  return v_id;
exception when check_violation then raise exception 'Check the price rule — percent between -90 and 300, a fixed price above ₹0, the last night after the first.';
end $$;

create or replace function public.rate_rule_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.rate_rules where id = p_id;
  if v_prop is null then raise exception 'Price rule not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  perform public._require_perm(v_prop, 'manage_rooms');
  delete from public.rate_rules where id = p_id;
end $$;

-- Preview: what one bed/room costs per night for the next p_days nights
create or replace function public.rate_preview(p_bed uuid, p_from date, p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare bd public.beds%rowtype;
begin
  select * into bd from public.beds where id = p_bed;
  if not found then raise exception 'Bed not found.'; end if;
  perform public._assert_role(bd.property_id, array['owner','manager','front_desk']::public.member_role[]);
  return (select jsonb_agg(jsonb_build_object('day', d::date, 'rate_paise', public._night_rate(bd.property_id, bd.room_id, bd.rate_paise, d::date)) order by d)
            from generate_series(p_from, p_from + least(greatest(coalesce(p_days, 14), 1), 62) - 1, interval '1 day') d);
end $$;

-- ---------------------------------------------------------------- 2. housekeeping
alter table public.beds
  add column if not exists hk_status text not null default 'clean' check (hk_status in ('clean','dirty','cleaning','inspect')),
  add column if not exists hk_note text check (char_length(hk_note) <= 200),
  add column if not exists hk_updated_at timestamptz,
  add column if not exists hk_by uuid;

create or replace function public._hk_on_checkout() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'checked_out' and old.status is distinct from 'checked_out' then
    update public.beds set hk_status = 'dirty', hk_note = null, hk_updated_at = now(), hk_by = auth.uid() where id = new.bed_id;
  end if;
  return new;
end $$;
drop trigger if exists bookings_hk_checkout on public.bookings;
create trigger bookings_hk_checkout after update of status on public.bookings for each row execute function public._hk_on_checkout();

create or replace function public.hk_board(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare tz text; today date;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  select timezone into tz from public.properties where id = p_property;
  today := (now() at time zone tz)::date;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', bd.id, 'label', bd.label, 'room', r.name, 'room_id', r.id, 'status', bd.hk_status, 'note', bd.hk_note, 'updated_at', bd.hk_updated_at,
      'updated_by', (select coalesce(m.display_name, m.email) from public.property_members m where m.property_id = p_property and m.user_id = bd.hk_by),
      'in_house', (select jsonb_build_object('guest', g.full_name, 'out', b.check_out_at, 'leaving_today', (b.check_out_at at time zone tz)::date = today)
                     from public.bookings b join public.guests g on g.id = b.guest_id
                    where b.bed_id = bd.id and b.status = 'checked_in' order by b.check_in_at desc limit 1),
      'arriving', (select jsonb_build_object('guest', g.full_name, 'at', b.check_in_at)
                     from public.bookings b join public.guests g on g.id = b.guest_id
                    where b.bed_id = bd.id and b.status in ('pending','confirmed') and (b.check_in_at at time zone tz)::date = today
                    order by b.check_in_at limit 1),
      'blocked', exists (select 1 from public.bed_blocks k where k.bed_id = bd.id and k.period @> now()))
    order by r.sort, r.name, bd.sort, bd.label), '[]'::jsonb)
    from public.beds bd join public.rooms r on r.id = bd.room_id where bd.property_id = p_property and bd.is_active);
end $$;

create or replace function public.hk_set(p_bed uuid, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.beds where id = p_bed;
  if v_prop is null then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  if p_status not in ('clean','dirty','cleaning','inspect') then raise exception 'Unknown status.'; end if;
  update public.beds set hk_status = p_status, hk_note = nullif(left(btrim(coalesce(p_note, '')), 200), ''), hk_updated_at = now(), hk_by = auth.uid() where id = p_bed;
end $$;

create or replace function public.hk_counts(p_property uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('dirty', count(*) filter (where hk_status = 'dirty'), 'cleaning', count(*) filter (where hk_status = 'cleaning'),
                            'inspect', count(*) filter (where hk_status = 'inspect'))
    from public.beds where property_id = p_property and is_active
     and p_property in (select public.my_property_ids())
$$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public._night_rate(uuid, uuid, int, date), public._stay_rate(uuid, timestamptz, timestamptz, int), public._apply_rate_rules(),
  public.rate_rule_save(uuid, jsonb), public.rate_rule_delete(uuid), public.rate_preview(uuid, date, int), public._hk_on_checkout(),
  public.hk_board(uuid), public.hk_set(uuid, text, text), public.hk_counts(uuid) from public, anon, authenticated;
grant execute on function public.rate_rule_save(uuid, jsonb), public.rate_rule_delete(uuid), public.rate_preview(uuid, date, int),
  public.hk_board(uuid), public.hk_set(uuid, text, text), public.hk_counts(uuid) to authenticated;
revoke execute on function public.available_beds(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.available_beds(uuid, timestamptz, timestamptz) to authenticated;
