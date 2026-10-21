-- =====================================================================
-- NammaStay · smart pricing
-- Smart pricing (pack 041): prices follow demand inside the owner's limits
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
-- Name: _sp_check(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_check(p_property uuid) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner', 'manager']::public.member_role[]);
  perform public._require_perm(p_property, 'manage_rooms');
end $$;

--
-- Name: _sp_groups(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_groups(p_property uuid) RETURNS TABLE(room_id uuid, room text, rate_paise integer, label text, beds integer, min_paise integer, max_paise integer, custom boolean, sort integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: _sp_is_pg(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_is_pg(p_property uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select to_regclass('public.pg_properties') is not null
     and exists (select 1 from public.pg_properties where property_id = p_property)
$$;

--
-- Name: _sp_price(public.stay_packages, public.bookings); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_price(sp public.stay_packages, b public.bookings) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
  select sp.price_paise + sp.extra_adult_paise * greatest(greatest(b.visitors, 1) - sp.base_guests, 0) + sp.child_paise * coalesce(b.children, 0)
$$;

--
-- Name: _sp_rebuild(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_rebuild(p_property uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: _sp_run(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_run(p_property uuid, p_by uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: _sp_today(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_today(p_property uuid) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (now() at time zone public._sp_tz(p_property))::date
$$;

--
-- Name: _sp_tz(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._sp_tz(p_property uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce((select nullif(timezone, '') from public.properties where id = p_property), 'Asia/Kolkata')
$$;

--
-- Name: sp_apply(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_apply(p_property uuid, p jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: sp_date_delete(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_date_delete(p_property uuid, p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._sp_check(p_property);
  delete from public.smart_price_dates where id = p_id and property_id = p_property;
end $$;

--
-- Name: sp_date_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_date_save(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: sp_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_get(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: sp_limits_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_limits_save(p_property uuid, p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: sp_night_lock(uuid, uuid, date, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_night_lock(p_property uuid, p_room uuid, p_night date, p_locked boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: sp_pause(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_pause(p_property uuid, p_days integer) RETURNS date
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v date;
begin
  perform public._sp_check(p_property);
  if p_days is null or p_days < 0 or p_days > 60 then raise exception 'Pause for 0 to 60 days.'; end if;
  v := case when p_days = 0 then null else public._sp_today(p_property) + p_days - 1 end;
  update public.smart_price_settings set paused_until = v, updated_at = now(), updated_by = auth.uid() where property_id = p_property;
  return v;
end $$;

--
-- Name: sp_run_all(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_run_all() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: sp_run_now(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_run_now(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._sp_check(p_property);
  return public._sp_run(p_property, auth.uid());
end $$;

--
-- Name: sp_settings_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_settings_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: sp_skip(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_skip(p_property uuid, p jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_n int;
begin
  perform public._sp_check(p_property);
  update public.smart_price_nights n set skip_pct = n.suggest_pct, suggest_pct = null, suggest_amt = null
   where n.property_id = p_property and n.suggest_pct is not null
     and (p is null or jsonb_typeof(p) <> 'array' or exists (select 1 from jsonb_array_elements(p) e where (e->>'room_id')::uuid = n.room_id and (e->>'night')::date = n.night));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

--
-- Name: sp_undo(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_undo(p_property uuid, p_run uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: smart_price_dates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smart_price_dates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    date_from date NOT NULL,
    date_to date NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT smart_price_dates_check CHECK (((date_to >= date_from) AND ((date_to - date_from) <= 30))),
    CONSTRAINT smart_price_dates_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 60)))
);

--
-- Name: smart_price_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smart_price_limits (
    property_id uuid NOT NULL,
    room_id uuid NOT NULL,
    rate_paise integer NOT NULL,
    min_paise integer NOT NULL,
    max_paise integer NOT NULL,
    CONSTRAINT smart_price_limits_check CHECK ((max_paise >= min_paise)),
    CONSTRAINT smart_price_limits_min_paise_check CHECK ((min_paise > 0))
);

--
-- Name: smart_price_nights; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smart_price_nights (
    property_id uuid NOT NULL,
    room_id uuid NOT NULL,
    night date NOT NULL,
    auto_pct integer DEFAULT 0 NOT NULL,
    auto_amt integer,
    owner_pct integer DEFAULT 0 NOT NULL,
    suggest_pct integer,
    suggest_amt integer,
    skip_pct integer,
    locked boolean DEFAULT false NOT NULL,
    owner_rule boolean DEFAULT false NOT NULL,
    booked integer,
    cap integer,
    reason text,
    applied_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: smart_price_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smart_price_rules (
    rule_id uuid NOT NULL,
    property_id uuid NOT NULL
);

--
-- Name: smart_price_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smart_price_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    ran_at timestamp with time zone DEFAULT now() NOT NULL,
    kind text NOT NULL,
    up integer DEFAULT 0 NOT NULL,
    down integer DEFAULT 0 NOT NULL,
    suggested integer DEFAULT 0 NOT NULL,
    by_user uuid,
    undo jsonb DEFAULT '[]'::jsonb NOT NULL,
    undone_at timestamp with time zone,
    CONSTRAINT smart_price_runs_kind_check CHECK ((kind = ANY (ARRAY['auto'::text, 'suggest'::text, 'applied'::text, 'off'::text, 'undo'::text, 'pinned'::text])))
);

--
-- Name: smart_price_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.smart_price_settings (
    property_id uuid NOT NULL,
    mode text DEFAULT 'off'::text NOT NULL,
    max_step_pct integer DEFAULT 10 NOT NULL,
    no_weekend_discount boolean DEFAULT true NOT NULL,
    paused_until date,
    last_run_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT smart_price_settings_max_step_pct_check CHECK (((max_step_pct >= 5) AND (max_step_pct <= 30))),
    CONSTRAINT smart_price_settings_mode_check CHECK ((mode = ANY (ARRAY['off'::text, 'suggest'::text, 'auto'::text])))
);

--
-- Name: smart_price_dates smart_price_dates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_dates
    ADD CONSTRAINT smart_price_dates_pkey PRIMARY KEY (id);

--
-- Name: smart_price_limits smart_price_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_limits
    ADD CONSTRAINT smart_price_limits_pkey PRIMARY KEY (property_id, room_id, rate_paise);

--
-- Name: smart_price_nights smart_price_nights_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_nights
    ADD CONSTRAINT smart_price_nights_pkey PRIMARY KEY (property_id, room_id, night);

--
-- Name: smart_price_rules smart_price_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_rules
    ADD CONSTRAINT smart_price_rules_pkey PRIMARY KEY (rule_id);

--
-- Name: smart_price_runs smart_price_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_runs
    ADD CONSTRAINT smart_price_runs_pkey PRIMARY KEY (id);

--
-- Name: smart_price_settings smart_price_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_settings
    ADD CONSTRAINT smart_price_settings_pkey PRIMARY KEY (property_id);

--
-- Name: smart_price_dates_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX smart_price_dates_prop ON public.smart_price_dates USING btree (property_id, date_from);

--
-- Name: smart_price_rules_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX smart_price_rules_prop ON public.smart_price_rules USING btree (property_id);

--
-- Name: smart_price_runs_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX smart_price_runs_prop ON public.smart_price_runs USING btree (property_id, ran_at DESC);

--
-- Name: smart_price_dates smart_price_dates_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_dates
    ADD CONSTRAINT smart_price_dates_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: smart_price_limits smart_price_limits_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_limits
    ADD CONSTRAINT smart_price_limits_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: smart_price_limits smart_price_limits_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_limits
    ADD CONSTRAINT smart_price_limits_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE CASCADE;

--
-- Name: smart_price_nights smart_price_nights_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_nights
    ADD CONSTRAINT smart_price_nights_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: smart_price_nights smart_price_nights_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_nights
    ADD CONSTRAINT smart_price_nights_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE CASCADE;

--
-- Name: smart_price_rules smart_price_rules_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_rules
    ADD CONSTRAINT smart_price_rules_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: smart_price_rules smart_price_rules_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_rules
    ADD CONSTRAINT smart_price_rules_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.rate_rules(id) ON DELETE CASCADE;

--
-- Name: smart_price_runs smart_price_runs_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_runs
    ADD CONSTRAINT smart_price_runs_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: smart_price_settings smart_price_settings_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.smart_price_settings
    ADD CONSTRAINT smart_price_settings_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: smart_price_dates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.smart_price_dates ENABLE ROW LEVEL SECURITY;

--
-- Name: smart_price_limits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.smart_price_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: smart_price_nights; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.smart_price_nights ENABLE ROW LEVEL SECURITY;

--
-- Name: smart_price_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.smart_price_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: smart_price_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.smart_price_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: smart_price_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.smart_price_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION _sp_check(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_check(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _sp_groups(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_groups(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _sp_is_pg(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_is_pg(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _sp_price(sp public.stay_packages, b public.bookings); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_price(sp public.stay_packages, b public.bookings) FROM PUBLIC;

--
-- Name: FUNCTION _sp_rebuild(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_rebuild(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _sp_run(p_property uuid, p_by uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_run(p_property uuid, p_by uuid) FROM PUBLIC;

--
-- Name: FUNCTION _sp_today(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_today(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _sp_tz(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._sp_tz(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION sp_apply(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_apply(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_apply(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION sp_date_delete(p_property uuid, p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_date_delete(p_property uuid, p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_date_delete(p_property uuid, p_id uuid) TO authenticated;

--
-- Name: FUNCTION sp_date_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_date_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_date_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION sp_get(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_get(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_get(p_property uuid) TO authenticated;

--
-- Name: FUNCTION sp_limits_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_limits_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_limits_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION sp_night_lock(p_property uuid, p_room uuid, p_night date, p_locked boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_night_lock(p_property uuid, p_room uuid, p_night date, p_locked boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_night_lock(p_property uuid, p_room uuid, p_night date, p_locked boolean) TO authenticated;

--
-- Name: FUNCTION sp_pause(p_property uuid, p_days integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_pause(p_property uuid, p_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_pause(p_property uuid, p_days integer) TO authenticated;

--
-- Name: FUNCTION sp_run_all(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_run_all() FROM PUBLIC;

--
-- Name: FUNCTION sp_run_now(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_run_now(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_run_now(p_property uuid) TO authenticated;

--
-- Name: FUNCTION sp_settings_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_settings_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_settings_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION sp_skip(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_skip(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_skip(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION sp_undo(p_property uuid, p_run uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sp_undo(p_property uuid, p_run uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_undo(p_property uuid, p_run uuid) TO authenticated;
