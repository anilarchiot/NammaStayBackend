-- =====================================================================
-- NammaStay · 041_smart_pricing.sql — Smart pricing: prices follow demand, inside the owner's limits
--
-- Every morning (and when the Smart pricing tab is opened) NammaStay looks at the next 60 nights for
-- each room: how full the night is, how fast beds are going compared with this property's usual pace,
-- how close the date is, weekends and festival / event dates. It then works out a small change:
--   • busy nights go up (+5 … +15 %), festival nights at least +10 %
--   • quiet nights a few days away get a small discount (−5 … −10 %); never Fri/Sat if the owner says so
--   • never more than the "biggest change in one day" step (default 10 %), never outside the owner's
--     lowest / highest price for each bed type, never on nights with the owner's own seasonal price,
--     never on nights the owner pinned by hand.
-- Modes: off · suggest (owner taps Apply) · auto (applied by itself + a notification).
--
-- HOW PRICES CHANGE: through the existing price rules (rate_rules). Smart pricing writes its own
-- "Smart pricing" season rules (tracked in smart_price_rules) — the live pricing code (_night_rate,
-- bookings, booking page, API, channel manager) is NOT changed and simply picks them up.
-- Bookings already made keep their price. Turning it off removes its rules: prices go back to normal.
--
-- ADD-ON ONLY — new tables and functions; existing tables and functions are not changed.
-- Owners and managers with "rooms & prices" permission. Not for PG / monthly tenants.
-- Safe to run more than once. Rollback: rollback_041_smart_pricing.sql
-- =====================================================================

do $$ begin
  if to_regprocedure('public._night_rate(uuid,uuid,integer,date)') is null or to_regclass('public.rate_rules') is null then
    raise exception 'Price rules (026) are missing — run the main setup first.';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.smart_price_settings (
  property_id         uuid primary key references public.properties(id) on delete cascade,
  mode                text not null default 'off' check (mode in ('off', 'suggest', 'auto')),
  max_step_pct        int  not null default 10 check (max_step_pct between 5 and 30),
  no_weekend_discount boolean not null default true,
  paused_until        date,
  last_run_at         timestamptz,
  updated_at          timestamptz not null default now(),
  updated_by          uuid
);

create table if not exists public.smart_price_limits (           -- per bed type = room + its normal price
  property_id uuid not null references public.properties(id) on delete cascade,
  room_id     uuid not null references public.rooms(id) on delete cascade,
  rate_paise  int  not null,
  min_paise   int  not null check (min_paise > 0),
  max_paise   int  not null,
  primary key (property_id, room_id, rate_paise),
  check (max_paise >= min_paise)
);

create table if not exists public.smart_price_dates (            -- festivals & local events
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 2 and 60),
  date_from   date not null,
  date_to     date not null,
  created_at  timestamptz not null default now(),
  check (date_to >= date_from and date_to - date_from <= 30)
);
create index if not exists smart_price_dates_prop on public.smart_price_dates (property_id, date_from);

create table if not exists public.smart_price_nights (           -- one row per room per night looked at
  property_id uuid not null references public.properties(id) on delete cascade,
  room_id     uuid not null references public.rooms(id) on delete cascade,
  night       date not null,
  auto_pct    int  not null default 0,        -- change in effect now (vs the owner's own price)
  auto_amt    int,                            -- the same as ₹ (paise) per night when the owner has no % rule that night
  owner_pct   int  not null default 0,        -- the owner's own weekend % rule that night (kept, combined)
  suggest_pct int,                            -- waiting for the owner (suggest mode)
  suggest_amt int,
  skip_pct    int,                            -- owner skipped this suggestion: don't suggest the same again
  locked      boolean not null default false, -- owner pinned this night: never changed automatically
  owner_rule  boolean not null default false, -- the owner's own seasonal / fixed price covers this night
  booked      int,
  cap         int,
  reason      text,
  applied_at  timestamptz,
  updated_at  timestamptz not null default now(),
  primary key (property_id, room_id, night)
);

create table if not exists public.smart_price_rules (            -- the rate_rules rows Smart pricing owns
  rule_id     uuid primary key references public.rate_rules(id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade
);
create index if not exists smart_price_rules_prop on public.smart_price_rules (property_id);

create table if not exists public.smart_price_runs (             -- "Recent changes" + undo
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  ran_at      timestamptz not null default now(),
  kind        text not null check (kind in ('auto', 'suggest', 'applied', 'off', 'undo', 'pinned')),
  up          int not null default 0,
  down        int not null default 0,
  suggested   int not null default 0,
  by_user     uuid,
  undo        jsonb not null default '[]',
  undone_at   timestamptz
);
create index if not exists smart_price_runs_prop on public.smart_price_runs (property_id, ran_at desc);

do $$ declare t text; begin
  foreach t in array array['smart_price_settings', 'smart_price_limits', 'smart_price_dates', 'smart_price_nights', 'smart_price_rules', 'smart_price_runs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);   -- only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- helpers (server only)
create or replace function public._sp_tz(p_property uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select nullif(timezone, '') from public.properties where id = p_property), 'Asia/Kolkata')
$$;

create or replace function public._sp_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone public._sp_tz(p_property))::date
$$;

create or replace function public._sp_check(p_property uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner', 'manager']::public.member_role[]);
  perform public._require_perm(p_property, 'manage_rooms');
end $$;

create or replace function public._sp_is_pg(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select to_regclass('public.pg_properties') is not null
     and exists (select 1 from public.pg_properties where property_id = p_property)
$$;

-- bed types: one per room + normal price, with the owner's limits (default 85 % … 150 % of the normal price)
create or replace function public._sp_groups(p_property uuid)
returns table (room_id uuid, room text, rate_paise int, label text, beds int, min_paise int, max_paise int, custom boolean, sort int)
language sql stable security definer set search_path = public, pg_temp as $$
  with g as (
    select b.room_id, r.name room, b.rate_paise, count(*)::int beds, min(r.sort) rsort,
           case when count(distinct b.position) = 1 then min(b.position::text) end pos
      from public.beds b join public.rooms r on r.id = b.room_id
     where b.property_id = p_property and b.is_active
     group by b.room_id, r.name, b.rate_paise)
  select g.room_id, g.room, g.rate_paise,
         g.room || case when (select count(*) from g g2 where g2.room_id = g.room_id) > 1
                        then ' · ' || coalesce(initcap(g.pos), to_char(g.rate_paise / 100, 'FM₹99,999')) else '' end,
         g.beds,
         coalesce(l.min_paise, (round(g.rate_paise * 0.85 / 1000.0) * 1000)::int),
         coalesce(l.max_paise, (round(g.rate_paise * 1.5 / 1000.0) * 1000)::int),
         l.room_id is not null,
         row_number() over (order by g.rsort, g.room, g.rate_paise desc)::int
    from g left join public.smart_price_limits l on l.property_id = p_property and l.room_id = g.room_id and l.rate_paise = g.rate_paise
$$;

-- Rebuild the "Smart pricing" price rules from the nights table (consecutive nights with the same change = one rule)
create or replace function public._sp_rebuild(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  delete from public.rate_rules where id in (select rule_id from public.smart_price_rules where property_id = p_property);
  with n as (
    select x.room_id, x.night,
           case when x.owner_pct = 0 then 'amount' else 'percent' end adj,
           case when x.owner_pct = 0 then coalesce(x.auto_amt, 0)
                else round((100 + x.owner_pct) * (100 + x.auto_pct) / 100.0 - 100)::int end val
      from public.smart_price_nights x
     where x.property_id = p_property and x.night >= public._sp_today(p_property) and x.auto_pct <> 0
       and not x.locked and not x.owner_rule
       and exists (select 1 from public.rooms r where r.id = x.room_id)),
  runs as (
    select room_id, adj, val, min(night) d0, max(night) d1
      from (select n.*, n.night - (row_number() over (partition by room_id, adj, val order by night))::int grp from n where val <> 0) z
     group by room_id, adj, val, grp),
  ins as (
    insert into public.rate_rules (property_id, name, kind, date_from, date_to, adjust, value, room_ids, priority, is_active)
    select p_property, 'Smart pricing', 'season', d0, d1, adj, val, array[room_id], -1, true   -- below the owner's own dated rules (priority 0+)
      from runs where adj = 'amount' or val between -90 and 300
    returning id)
  insert into public.smart_price_rules (rule_id, property_id) select id, p_property from ins;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- The heart: look at the next 60 nights and change / suggest prices
create or replace function public._sp_run(p_property uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  st public.smart_price_settings; tz text := public._sp_tz(p_property); v_today date := public._sp_today(p_property);
  v_beds int; v_hist int; v_usual numeric[]; r record; x record; cur public.smart_price_nights; o record; g record;
  v_occ numeric; v_L int; v_pace numeric; v_wk boolean; v_fest text; v_opct int; v_t int; v_why text;
  v_lo numeric; v_hi numeric; v_cur int; v_new int; v_amt int; v_alo int; v_ahi int; v_rep int;
  v_up int := 0; v_down int := 0; v_sug int := 0; v_undo jsonb := '[]'::jsonb; v_owner boolean;
begin
  select * into st from public.smart_price_settings where property_id = p_property;
  if not found or st.mode = 'off' or public._sp_is_pg(p_property) then return jsonb_build_object('ran', false); end if;
  if st.paused_until is not null and st.paused_until >= v_today then return jsonb_build_object('ran', false, 'paused', true); end if;

  -- this property's usual pace: how full past nights already were 1 / 3 / 7 / 14 / 30 days before
  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  select count(*) into v_hist
    from public.bookings b, generate_series(greatest((b.check_in_at at time zone tz)::date, v_today - 56), least((b.check_out_at at time zone tz)::date - 1, v_today - 1), interval '1 day') h
   where b.property_id = p_property and b.status not in ('cancelled', 'no_show') and b.check_out_at > now() - interval '60 days' and b.check_in_at < now();
  select array_agg(u order by bk) into v_usual from (
    select bk, (select count(*) from public.bookings b,
                       generate_series(greatest((b.check_in_at at time zone tz)::date, v_today - 56), least((b.check_out_at at time zone tz)::date - 1, v_today - 1), interval '1 day') h
                 where b.property_id = p_property and b.status not in ('cancelled', 'no_show') and b.check_out_at > now() - interval '60 days' and b.check_in_at < now()
                   and (b.created_at at time zone tz)::date <= h::date - bk)::numeric / greatest(56 * v_beds, 1) u
      from unnest(array[1, 3, 7, 14, 30]) bk) z;

  for r in select distinct g2.room_id from public._sp_groups(p_property) g2 loop
    for x in
      select d::date night,
             (select count(*) from public.beds b where b.room_id = r.room_id and b.is_active)
             - (select count(distinct bb.bed_id) from public.bed_blocks bb join public.beds b on b.id = bb.bed_id
                 where b.room_id = r.room_id and b.is_active and (bb.starts_at at time zone tz)::date <= d::date
                   and ((bb.ends_at at time zone tz)::date > d::date or (bb.starts_at at time zone tz)::date = d::date)) cap,
             (select count(distinct bk.bed_id) from public.bookings bk join public.beds b on b.id = bk.bed_id
               where b.room_id = r.room_id and bk.status in ('pending', 'confirmed', 'checked_in')
                 and (bk.check_in_at at time zone tz)::date <= d::date and (bk.check_out_at at time zone tz)::date > d::date) booked
        from generate_series(v_today, v_today + 59, interval '1 day') d
    loop
      select * into cur from public.smart_price_nights where property_id = p_property and room_id = r.room_id and night = x.night;
      if found and cur.locked then continue; end if;
      v_cur := coalesce(cur.auto_pct, 0);

      -- the owner's own rule that night (Smart pricing's own rules left out)
      select rr.kind, rr.adjust, rr.value into o from public.rate_rules rr
       where rr.property_id = p_property and rr.is_active and (rr.room_ids is null or r.room_id = any (rr.room_ids))
         and not exists (select 1 from public.smart_price_rules s where s.rule_id = rr.id)
         and ((rr.kind = 'weekend' and extract(dow from x.night)::smallint = any (rr.weekdays))
           or (rr.kind = 'season' and x.night between rr.date_from and rr.date_to
               and (rr.weekdays is null or extract(dow from x.night)::smallint = any (rr.weekdays))))
       order by (rr.kind = 'season') desc, rr.priority desc, rr.created_at desc limit 1;
      v_owner := found and (o.kind = 'season' or o.adjust <> 'percent');
      v_opct := case when found and not v_owner then o.value else 0 end;

      v_occ := case when x.cap > 0 then x.booked::numeric / x.cap else 1 end;
      v_L := x.night - v_today;
      v_wk := extract(dow from x.night) in (5, 6);
      select string_agg(name, ', ') into v_fest from public.smart_price_dates where property_id = p_property and x.night between date_from and date_to;
      v_pace := case when v_hist >= 30 then v_occ / greatest(v_usual[case when v_L >= 30 then 5 when v_L >= 14 then 4 when v_L >= 7 then 3 when v_L >= 3 then 2 else 1 end], 0.05) end;

      v_t := 0; v_why := null;
      if x.cap <= 0 then v_why := 'No beds to sell';
      elsif v_owner then v_why := 'Your own seasonal price';
      else
        if v_occ >= 0.85 then v_t := 10; v_why := 'Nearly full — ' || x.booked || ' of ' || x.cap || ' beds booked';
        elsif v_occ >= 0.7 then v_t := 5; v_why := 'Filling well — ' || x.booked || ' of ' || x.cap || ' beds booked'; end if;
        if v_pace is not null and v_L >= 3 and v_pace >= 1.5 and v_occ >= 0.4 then
          v_t := v_t + 5; v_why := coalesce(v_why || ', ', x.booked || ' of ' || x.cap || ' beds booked, ') || 'going faster than usual'; end if;
        if v_fest is not null and v_L >= 1 then
          v_t := greatest(v_t, 10) + case when v_occ >= 0.7 then 5 else 0 end; v_why := v_fest || coalesce(' · ' || v_why, '');
        elsif v_occ < 0.5 and not (v_wk and st.no_weekend_discount) then
          if v_L <= 2 then v_t := -10; v_why := 'Only ' || x.booked || ' of ' || x.cap || ' beds booked, ' || case v_L when 0 then 'tonight' when 1 then 'tomorrow' else 'in 2 days' end;
          elsif v_L <= 6 and v_occ < 0.35 then v_t := -5; v_why := 'Only ' || x.booked || ' of ' || x.cap || ' beds booked, ' || v_L || ' days away';
          elsif v_pace is not null and v_pace <= 0.5 and v_L <= 14 and v_occ < 0.35 then v_t := -5; v_why := 'Filling slower than usual — ' || x.booked || ' of ' || x.cap || ' beds booked';
          end if;
        end if;
        -- the owner's lowest / highest price for every bed type in this room
        if v_t <> 0 then
          select max((gg.min_paise::numeric * 10000 / (gg.rate_paise * (100 + v_opct))) - 100), min((gg.max_paise::numeric * 10000 / (gg.rate_paise * (100 + v_opct))) - 100)
            into v_lo, v_hi from public._sp_groups(p_property) gg where gg.room_id = r.room_id;
          if v_t > 0 then v_t := greatest(0, least(v_t, floor(v_hi)::int)); else v_t := least(0, greatest(v_t, ceil(v_lo)::int)); end if;
        end if;
        if x.booked >= x.cap then v_t := v_cur; v_why := 'Full — no beds left to sell'; end if;   -- nothing to sell: leave the price
      end if;

      -- move at most max_step_pct a day
      v_new := case when v_owner or x.cap <= 0 then 0 else v_cur + greatest(-st.max_step_pct, least(st.max_step_pct, v_t - v_cur)) end;
      v_amt := null;
      if v_opct = 0 and v_new <> 0 then                                          -- as ₹, rounded to ₹10
        select max(gg.rate_paise), max(gg.min_paise - gg.rate_paise), min(gg.max_paise - gg.rate_paise)
          into v_rep, v_alo, v_ahi from public._sp_groups(p_property) gg where gg.room_id = r.room_id;
        v_amt := (round(v_rep * v_new / 100.0 / 1000.0) * 1000)::int;
        v_amt := greatest(v_alo, least(v_ahi, v_amt));
        if v_amt = 0 then v_new := 0; v_amt := null; end if;
      end if;

      insert into public.smart_price_nights as n (property_id, room_id, night, owner_pct, owner_rule, booked, cap, reason, updated_at)
      values (p_property, r.room_id, x.night, v_opct, v_owner, x.booked, x.cap, v_why, now())
      on conflict (property_id, room_id, night) do update set owner_pct = excluded.owner_pct, owner_rule = excluded.owner_rule,
        booked = excluded.booked, cap = excluded.cap, reason = excluded.reason, updated_at = now();

      if st.mode = 'auto' or v_owner then
        if v_new <> v_cur or (v_new <> 0 and v_amt is distinct from cur.auto_amt) then
          v_undo := v_undo || jsonb_build_object('room', r.room_id, 'night', x.night, 'pct', v_cur, 'amt', cur.auto_amt);
          update public.smart_price_nights set auto_pct = v_new, auto_amt = v_amt, applied_at = now(), suggest_pct = null, suggest_amt = null
           where property_id = p_property and room_id = r.room_id and night = x.night;
          if v_new > v_cur then v_up := v_up + 1; elsif v_new < v_cur then v_down := v_down + 1; end if;
        else
          update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property and room_id = r.room_id and night = x.night;
        end if;
      else   -- suggest
        if v_new <> v_cur and v_new is distinct from cur.skip_pct then
          update public.smart_price_nights set suggest_pct = v_new, suggest_amt = v_amt where property_id = p_property and room_id = r.room_id and night = x.night;
          v_sug := v_sug + 1;
        else
          update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property and room_id = r.room_id and night = x.night;
        end if;
      end if;
    end loop;
  end loop;

  delete from public.smart_price_nights where property_id = p_property and night < v_today - 120;   -- keep 4 months for "extra earned"
  update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property and night < v_today and suggest_pct is not null;
  perform public._sp_rebuild(p_property);
  update public.smart_price_settings set last_run_at = now() where property_id = p_property;

  if v_up + v_down > 0 or v_sug > 0 then
    insert into public.smart_price_runs (property_id, kind, up, down, suggested, by_user, undo)
    values (p_property, case when st.mode = 'auto' then 'auto' else 'suggest' end, v_up, v_down, v_sug, p_by, v_undo);
  end if;
  if st.mode = 'auto' and v_up + v_down > 0 then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'smart_price', 'Smart pricing: ' || v_up || case when v_up = 1 then ' night up, ' else ' nights up, ' end || v_down || case when v_down = 1 then ' night down' else ' nights down' end,
            'Prices changed by demand, inside your limits. See or undo: Settings → Smart pricing.');
  elsif st.mode = 'suggest' and v_sug > 0 and p_by is null then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'smart_price', v_sug || case when v_sug = 1 then ' price suggestion' else ' price suggestions' end || ' waiting',
            'Settings → Smart pricing: tap Apply or Skip.');
  end if;
  return jsonb_build_object('ran', true, 'up', v_up, 'down', v_down, 'suggested', v_sug);
end $$;

-- ---------------------------------------------------------------- what the Smart pricing tab shows
create or replace function public.sp_get(p_property uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare st public.smart_price_settings; v_today date; tz text; v_groups jsonb; v_nights jsonb; v_prices jsonb; v_sug jsonb; v_stats jsonb; v_runs jsonb; v_dates jsonb;
begin
  perform public._sp_check(p_property);
  if public._sp_is_pg(p_property) then return jsonb_build_object('is_pg', true); end if;
  insert into public.smart_price_settings (property_id) values (p_property) on conflict do nothing;
  select * into st from public.smart_price_settings where property_id = p_property;
  if st.mode <> 'off' and (st.last_run_at is null or st.last_run_at < now() - interval '20 hours') then
    perform public._sp_run(p_property, null);
    select * into st from public.smart_price_settings where property_id = p_property;
  end if;
  v_today := public._sp_today(p_property); tz := public._sp_tz(p_property);

  select coalesce(jsonb_agg(jsonb_build_object('room_id', g.room_id, 'room', g.room, 'rate_paise', g.rate_paise, 'label', g.label, 'beds', g.beds,
           'min_paise', g.min_paise, 'max_paise', g.max_paise, 'custom', g.custom) order by g.sort), '[]'::jsonb)
    into v_groups from public._sp_groups(p_property) g;

  select coalesce(jsonb_agg(jsonb_build_object('night', d::date, 'weekend', extract(dow from d) in (5, 6),
           'booked', (select count(distinct bk.bed_id) from public.bookings bk join public.beds b on b.id = bk.bed_id
                       where bk.property_id = p_property and b.is_active and bk.status in ('pending', 'confirmed', 'checked_in')
                         and (bk.check_in_at at time zone tz)::date <= d::date and (bk.check_out_at at time zone tz)::date > d::date),
           'cap', (select count(*) from public.beds b where b.property_id = p_property and b.is_active
                     and not exists (select 1 from public.bed_blocks bb where bb.bed_id = b.id and (bb.starts_at at time zone tz)::date <= d::date
                                       and ((bb.ends_at at time zone tz)::date > d::date or (bb.starts_at at time zone tz)::date = d::date))),
           'festival', (select string_agg(name, ', ') from public.smart_price_dates where property_id = p_property and d::date between date_from and date_to))
           order by d), '[]'::jsonb)
    into v_nights from generate_series(v_today, v_today + 59, interval '1 day') d;

  select coalesce(jsonb_agg(jsonb_build_object('room_id', g.room_id, 'rate_paise', g.rate_paise, 'label', g.label,
           'cells', (select jsonb_agg(jsonb_build_object('night', d::date, 'price_paise', public._night_rate(p_property, g.room_id, g.rate_paise, d::date),
                       'auto_pct', coalesce(n.auto_pct, 0), 'locked', coalesce(n.locked, false), 'owner_rule', coalesce(n.owner_rule, false),
                       'suggest', n.suggest_pct is not null) order by d)
                       from generate_series(v_today, v_today + 59, interval '1 day') d
                       left join public.smart_price_nights n on n.property_id = p_property and n.room_id = g.room_id and n.night = d::date))
           order by g.sort), '[]'::jsonb)
    into v_prices from public._sp_groups(p_property) g;

  select coalesce(jsonb_agg(jsonb_build_object('room_id', n.room_id, 'room', r.name, 'night', n.night, 'pct', n.suggest_pct, 'reason', n.reason,
           'from_paise', public._night_rate(p_property, n.room_id, rep.rate_paise, n.night),
           'to_paise', case when n.owner_pct = 0 then rep.rate_paise + coalesce(n.suggest_amt, 0)
                            else round(rep.rate_paise * (100 + n.owner_pct) * (100 + n.suggest_pct) / 10000.0)::int end,
           'rate_paise', rep.rate_paise) order by n.night, r.sort), '[]'::jsonb)
    into v_sug
    from public.smart_price_nights n join public.rooms r on r.id = n.room_id
    cross join lateral (select max(b.rate_paise) rate_paise from public.beds b where b.room_id = n.room_id and b.is_active) rep
   where n.property_id = p_property and n.suggest_pct is not null and n.night >= v_today and rep.rate_paise is not null;

  select jsonb_build_object(
      'extra_30_paise', coalesce(sum(case when n.auto_pct > 0 then
                          case when n.owner_pct = 0 then coalesce(n.auto_amt, 0) else round(bd.rate_paise * (100 + n.owner_pct) / 100.0 * n.auto_pct / 100.0) end end), 0)::bigint,
      'up_nights_30', count(*) filter (where n.auto_pct > 0),
      'discount_nights_30', count(*) filter (where n.auto_pct < 0))
    into v_stats
    from public.bookings b join public.beds bd on bd.id = b.bed_id
    cross join lateral generate_series((b.check_in_at at time zone tz)::date, (b.check_out_at at time zone tz)::date - 1, interval '1 day') h
    join public.smart_price_nights n on n.property_id = b.property_id and n.room_id = bd.room_id and n.night = h::date and n.auto_pct <> 0 and n.applied_at <= b.created_at
   where b.property_id = p_property and b.created_at > now() - interval '30 days' and b.status not in ('cancelled', 'no_show');
  v_stats := v_stats || jsonb_build_object(
      'up_now', (select count(distinct night) from public.smart_price_nights where property_id = p_property and night >= v_today and auto_pct > 0 and not locked and not owner_rule),
      'down_now', (select count(distinct night) from public.smart_price_nights where property_id = p_property and night >= v_today and auto_pct < 0 and not locked and not owner_rule));

  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'ran_at', x.ran_at, 'kind', x.kind, 'up', x.up, 'down', x.down, 'suggested', x.suggested,
           'can_undo', x.undone_at is null and jsonb_array_length(x.undo) > 0 and x.ran_at > now() - interval '7 days', 'undone', x.undone_at is not null) order by x.ran_at desc), '[]'::jsonb)
    into v_runs from (select * from public.smart_price_runs where property_id = p_property order by ran_at desc limit 8) x;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'date_from', date_from, 'date_to', date_to) order by date_from), '[]'::jsonb)
    into v_dates from public.smart_price_dates where property_id = p_property and date_to >= v_today;

  return jsonb_build_object('is_pg', false, 'today', v_today,
    'settings', jsonb_build_object('mode', st.mode, 'max_step_pct', st.max_step_pct, 'no_weekend_discount', st.no_weekend_discount,
                  'paused_until', case when st.paused_until >= v_today then st.paused_until end, 'last_run_at', st.last_run_at),
    'channel_manager', to_regclass('public.channex_room_map') is not null
                       and exists (select 1 from public.channex_room_map where property_id = p_property and cx_rate_plan_id is not null),
    'groups', v_groups, 'nights', v_nights, 'prices', v_prices, 'suggestions', v_sug, 'stats', v_stats, 'runs', v_runs, 'dates', v_dates);
end $$;

-- ---------------------------------------------------------------- owner actions
create or replace function public.sp_settings_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_mode text := coalesce(nullif(p->>'mode', ''), 'off'); v_step int := coalesce(nullif(p->>'max_step_pct', '')::int, 10);
        v_old text; v_today date := public._sp_today(p_property); v_undo jsonb;
begin
  perform public._sp_check(p_property);
  if public._sp_is_pg(p_property) then raise exception 'Smart pricing is for nightly stays, not monthly PG tenants.'; end if;
  if v_mode not in ('off', 'suggest', 'auto') then raise exception 'Choose Suggest only, Automatic or Off.'; end if;
  if v_step not in (5, 10, 15, 20) then raise exception 'Biggest change in one day: 5, 10, 15 or 20%%.'; end if;
  insert into public.smart_price_settings (property_id) values (p_property) on conflict do nothing;
  select mode into v_old from public.smart_price_settings where property_id = p_property;
  update public.smart_price_settings set mode = v_mode, max_step_pct = v_step,
         no_weekend_discount = coalesce((p->>'no_weekend_discount')::boolean, no_weekend_discount),
         paused_until = case when v_mode = 'off' then null else paused_until end,
         updated_at = now(), updated_by = auth.uid()
   where property_id = p_property;
  if v_mode = 'off' and v_old <> 'off' then          -- back to the owner's own prices
    select coalesce(jsonb_agg(jsonb_build_object('room', room_id, 'night', night, 'pct', auto_pct, 'amt', auto_amt)), '[]'::jsonb) into v_undo
      from public.smart_price_nights where property_id = p_property and night >= v_today and auto_pct <> 0;
    update public.smart_price_nights set auto_pct = 0, auto_amt = null, suggest_pct = null, suggest_amt = null, applied_at = now()
     where property_id = p_property and night >= v_today and (auto_pct <> 0 or suggest_pct is not null);
    perform public._sp_rebuild(p_property);
    insert into public.smart_price_runs (property_id, kind, by_user, undo) values (p_property, 'off', auth.uid(), v_undo);
  elsif v_mode <> 'off' then
    if v_mode = 'auto' and v_old = 'suggest' then
      update public.smart_price_nights set suggest_pct = null, suggest_amt = null where property_id = p_property;
    end if;
    return public._sp_run(p_property, auth.uid());
  end if;
  return jsonb_build_object('ran', false);
end $$;

create or replace function public.sp_limits_save(p_property uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare x jsonb; g record;
begin
  perform public._sp_check(p_property);
  if jsonb_typeof(p) <> 'array' then raise exception 'Send the limits as a list.'; end if;
  for x in select * from jsonb_array_elements(p) loop
    select * into g from public._sp_groups(p_property) gg where gg.room_id = (x->>'room_id')::uuid and gg.rate_paise = (x->>'rate_paise')::int;
    if not found then raise exception 'That bed type no longer exists — reload the page.'; end if;
    if (x->>'min_paise')::int is null or (x->>'max_paise')::int is null then raise exception 'Enter the lowest and highest price for %.', g.label; end if;
    if (x->>'min_paise')::int > g.rate_paise then raise exception '%: the lowest price can’t be above the normal price (₹%).', g.label, g.rate_paise / 100; end if;
    if (x->>'max_paise')::int < g.rate_paise then raise exception '%: the highest price can’t be below the normal price (₹%).', g.label, g.rate_paise / 100; end if;
    if (x->>'min_paise')::int < g.rate_paise * 0.5 then raise exception '%: the lowest price can be at most 50%% below normal.', g.label; end if;
    if (x->>'max_paise')::int > g.rate_paise * 3 then raise exception '%: the highest price can be at most 3 times normal.', g.label; end if;
    insert into public.smart_price_limits (property_id, room_id, rate_paise, min_paise, max_paise)
    values (p_property, g.room_id, g.rate_paise, (x->>'min_paise')::int, (x->>'max_paise')::int)
    on conflict (property_id, room_id, rate_paise) do update set min_paise = excluded.min_paise, max_paise = excluded.max_paise;
  end loop;
end $$;

create or replace function public.sp_date_save(p_property uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_from date := nullif(p->>'date_from', '')::date; v_to date := coalesce(nullif(p->>'date_to', '')::date, nullif(p->>'date_from', '')::date);
begin
  perform public._sp_check(p_property);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Name the festival or event, e.g. "Diwali".'; end if;
  if v_from is null then raise exception 'Pick the first night.'; end if;
  if v_to < v_from then raise exception 'The last night is before the first night.'; end if;
  if v_to - v_from > 30 then raise exception 'Keep it to 31 nights or fewer.'; end if;
  if v_id is null then
    insert into public.smart_price_dates (property_id, name, date_from, date_to) values (p_property, btrim(p->>'name'), v_from, v_to) returning id into v_id;
  else
    update public.smart_price_dates set name = btrim(p->>'name'), date_from = v_from, date_to = v_to where id = v_id and property_id = p_property;
    if not found then raise exception 'Date not found.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.sp_date_delete(p_property uuid, p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._sp_check(p_property);
  delete from public.smart_price_dates where id = p_id and property_id = p_property;
end $$;

-- Apply suggestions: p = [{room_id, night}] or null for all
create or replace function public.sp_apply(p_property uuid, p jsonb) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_undo jsonb; v_up int; v_down int; v_n int;
begin
  perform public._sp_check(p_property);
  create temp table if not exists _sp_pick (room_id uuid, night date) on commit drop; truncate _sp_pick;
  insert into _sp_pick select n.room_id, n.night from public.smart_price_nights n
   where n.property_id = p_property and n.suggest_pct is not null and n.night >= public._sp_today(p_property)
     and (p is null or jsonb_typeof(p) <> 'array' or exists (select 1 from jsonb_array_elements(p) e where (e->>'room_id')::uuid = n.room_id and (e->>'night')::date = n.night));
  select coalesce(jsonb_agg(jsonb_build_object('room', n.room_id, 'night', n.night, 'pct', n.auto_pct, 'amt', n.auto_amt)), '[]'::jsonb),
         count(*) filter (where n.suggest_pct > n.auto_pct), count(*) filter (where n.suggest_pct < n.auto_pct), count(*)
    into v_undo, v_up, v_down, v_n
    from public.smart_price_nights n join _sp_pick k on k.room_id = n.room_id and k.night = n.night where n.property_id = p_property;
  if v_n = 0 then raise exception 'Nothing to apply — the suggestions may have changed. Reload the page.'; end if;
  update public.smart_price_nights n set auto_pct = n.suggest_pct, auto_amt = n.suggest_amt, suggest_pct = null, suggest_amt = null, skip_pct = null, applied_at = now()
    from _sp_pick k where n.property_id = p_property and k.room_id = n.room_id and k.night = n.night;
  perform public._sp_rebuild(p_property);
  insert into public.smart_price_runs (property_id, kind, up, down, by_user, undo) values (p_property, 'applied', v_up, v_down, auth.uid(), v_undo);
  return v_n;
end $$;

create or replace function public.sp_skip(p_property uuid, p jsonb) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  perform public._sp_check(p_property);
  update public.smart_price_nights n set skip_pct = n.suggest_pct, suggest_pct = null, suggest_amt = null
   where n.property_id = p_property and n.suggest_pct is not null
     and (p is null or jsonb_typeof(p) <> 'array' or exists (select 1 from jsonb_array_elements(p) e where (e->>'room_id')::uuid = n.room_id and (e->>'night')::date = n.night));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Pin a night to the owner's own price (Smart pricing leaves it alone) or hand it back
create or replace function public.sp_night_lock(p_property uuid, p_room uuid, p_night date, p_locked boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._sp_check(p_property);
  if not exists (select 1 from public.rooms where id = p_room and property_id = p_property) then raise exception 'Room not found.'; end if;
  if p_night < public._sp_today(p_property) then raise exception 'That night has passed.'; end if;
  insert into public.smart_price_nights (property_id, room_id, night, locked) values (p_property, p_room, p_night, p_locked)
  on conflict (property_id, room_id, night) do update set locked = excluded.locked,
    auto_pct = case when excluded.locked then 0 else smart_price_nights.auto_pct end,
    auto_amt = case when excluded.locked then null else smart_price_nights.auto_amt end,
    suggest_pct = null, suggest_amt = null, updated_at = now();
  perform public._sp_rebuild(p_property);
  insert into public.smart_price_runs (property_id, kind, by_user) values (p_property, 'pinned', auth.uid());
end $$;

create or replace function public.sp_run_now(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._sp_check(p_property);
  return public._sp_run(p_property, auth.uid());
end $$;

create or replace function public.sp_pause(p_property uuid, p_days int) returns date
language plpgsql security definer set search_path = public, pg_temp as $$
declare v date;
begin
  perform public._sp_check(p_property);
  if p_days is null or p_days < 0 or p_days > 60 then raise exception 'Pause for 0 to 60 days.'; end if;
  v := case when p_days = 0 then null else public._sp_today(p_property) + p_days - 1 end;
  update public.smart_price_settings set paused_until = v, updated_at = now(), updated_by = auth.uid() where property_id = p_property;
  return v;
end $$;

create or replace function public.sp_undo(p_property uuid, p_run uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.smart_price_runs; e jsonb; v_n int := 0;
begin
  perform public._sp_check(p_property);
  select * into x from public.smart_price_runs where id = p_run and property_id = p_property for update;
  if not found then raise exception 'Change not found.'; end if;
  if x.undone_at is not null then raise exception 'Already undone.'; end if;
  for e in select * from jsonb_array_elements(x.undo) loop
    if (e->>'night')::date >= public._sp_today(p_property) then
      update public.smart_price_nights set auto_pct = (e->>'pct')::int, auto_amt = nullif(e->>'amt', '')::int, suggest_pct = null, suggest_amt = null,
             skip_pct = coalesce(suggest_pct, skip_pct), applied_at = now()
       where property_id = p_property and room_id = (e->>'room')::uuid and night = (e->>'night')::date and not locked;
      v_n := v_n + 1;
    end if;
  end loop;
  if x.kind = 'off' then   -- undoing "turn off" = turn back on the way it was
    update public.smart_price_settings set mode = coalesce((select kind from public.smart_price_runs where property_id = p_property and kind in ('auto', 'suggest') order by ran_at desc limit 1), 'suggest')
     where property_id = p_property;
  end if;
  update public.smart_price_runs set undone_at = now() where id = p_run;
  perform public._sp_rebuild(p_property);
  insert into public.smart_price_runs (property_id, kind, by_user) values (p_property, 'undo', auth.uid());
  return v_n;
end $$;

-- Every morning (pg_cron): select cron.schedule('nammastay-smart-pricing', '30 0 * * *', $$select public.sp_run_all()$$);  -- 6:00 AM India
create or replace function public.sp_run_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; n int := 0;
begin
  for pid in select property_id from public.smart_price_settings where mode <> 'off' loop
    begin
      if (public._sp_run(pid, null)->>'ran')::boolean then n := n + 1; end if;
    exception when others then raise warning 'smart pricing % failed: %', pid, sqlerrm;
    end;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- permissions
do $$ declare f text; begin
  foreach f in array array['sp_get(uuid)', 'sp_settings_save(uuid, jsonb)', 'sp_limits_save(uuid, jsonb)', 'sp_date_save(uuid, jsonb)', 'sp_date_delete(uuid, uuid)',
    'sp_apply(uuid, jsonb)', 'sp_skip(uuid, jsonb)', 'sp_night_lock(uuid, uuid, date, boolean)', 'sp_run_now(uuid)', 'sp_pause(uuid, integer)', 'sp_undo(uuid, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['_sp_tz(uuid)', '_sp_today(uuid)', '_sp_check(uuid)', '_sp_is_pg(uuid)', '_sp_groups(uuid)', '_sp_rebuild(uuid)', '_sp_run(uuid, uuid)', 'sp_run_all()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

select to_regprocedure('public.sp_get(uuid)') is not null as smart_pricing_installed;
