-- =====================================================================
-- NammaStay · rooms beds prices
-- Rooms, beds, blocked beds, weekend & season prices, extras catalogue
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
-- Name: _night_rate(uuid, uuid, integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._night_rate(p_property uuid, p_room uuid, p_base integer, p_day date) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select greatest(0, coalesce((
    select case r.adjust when 'percent' then round(p_base * (100 + r.value) / 100.0)::int when 'amount' then p_base + r.value else r.value end
      from public.rate_rules r
     where r.property_id = p_property and r.is_active and (r.room_ids is null or p_room = any (r.room_ids))
       and ((r.kind = 'weekend' and extract(dow from p_day)::smallint = any (r.weekdays))
         or (r.kind = 'season' and p_day between r.date_from and r.date_to
             and (r.weekdays is null or extract(dow from p_day)::smallint = any (r.weekdays))))
     order by (r.kind = 'season') desc, r.priority desc, r.created_at desc limit 1), p_base))
$$;

--
-- Name: _stay_rate(uuid, timestamp with time zone, timestamp with time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._stay_rate(p_bed uuid, p_in timestamp with time zone, p_out timestamp with time zone, p_base integer DEFAULT NULL::integer) RETURNS TABLE(rate_paise integer, min_nights integer, rule_names text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: available_beds(uuid, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.available_beds(p_property uuid, p_in timestamp with time zone, p_out timestamp with time zone) RETURNS TABLE(id uuid, label text, room_id uuid, room_name text, rate_paise integer, max_guests smallint, base_guests smallint, extra_guest_paise integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: bed_board(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bed_board(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_tz text; t0 timestamptz; t1 timestamptz; v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, (now() at time zone v_tz)::date);
  t1 := t0 + interval '1 day';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'name', r.name, 'description', r.description,
           'beds', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', bd.id, 'label', bd.label, 'position', bd.position,
                      'rate_paise', bd.rate_paise, 'is_active', bd.is_active,
                      'block', (select k.reason from public.bed_blocks k
                                 where k.bed_id = bd.id and k.period @> now() limit 1),
                      'booking', (select jsonb_build_object('id', b.id, 'guest', g.full_name, 'status', b.status,
                                          'check_out_at', b.check_out_at)
                                    from public.bookings b join public.guests g on g.id = b.guest_id
                                   where b.bed_id = bd.id and b.status in ('pending','confirmed','checked_in')
                                     and b.stay && tstzrange(t0, t1, '[)')
                                   order by (b.status = 'checked_in') desc, b.check_in_at limit 1)
                    ) order by bd.sort, bd.label), '[]'::jsonb)
                    from public.beds bd where bd.room_id = r.id)
         ) order by r.sort, r.name), '[]'::jsonb)
    into v
    from public.rooms r where r.property_id = p_property;
  return v;
end $$;

--
-- Name: rate_preview(uuid, date, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rate_preview(p_bed uuid, p_from date, p_days integer DEFAULT 14) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare bd public.beds%rowtype;
begin
  select * into bd from public.beds where id = p_bed;
  if not found then raise exception 'Bed not found.'; end if;
  perform public._assert_role(bd.property_id, array['owner','manager','front_desk']::public.member_role[]);
  return (select jsonb_agg(jsonb_build_object('day', d::date, 'rate_paise', public._night_rate(bd.property_id, bd.room_id, bd.rate_paise, d::date)) order by d)
            from generate_series(p_from, p_from + least(greatest(coalesce(p_days, 14), 1), 62) - 1, interval '1 day') d);
end $$;

--
-- Name: rate_rule_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rate_rule_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.rate_rules where id = p_id;
  if v_prop is null then raise exception 'Price rule not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  perform public._require_perm(v_prop, 'manage_rooms');
  delete from public.rate_rules where id = p_id;
end $$;

--
-- Name: rate_rule_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rate_rule_save(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: set_bed_block(uuid, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_bed_block(p_bed uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_bed public.beds%rowtype; v_id uuid;
begin
  select * into v_bed from public.beds where id = p_bed;
  if not found then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_bed.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if exists (select 1 from public.bookings b where b.bed_id = p_bed
              and b.status in ('pending','confirmed','checked_in') and b.stay && tstzrange(p_from, p_to, '[)')) then
    raise exception '% has bookings in that period. Move them first.', v_bed.label;
  end if;
  begin
    insert into public.bed_blocks (property_id, bed_id, starts_at, ends_at, reason)
    values (v_bed.property_id, p_bed, p_from, p_to, p_reason) returning id into v_id;
  exception when exclusion_violation then
    raise exception '% is already blocked for part of that period.', v_bed.label;
  end;
  return v_id;
end $$;

--
-- Name: bed_blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bed_blocks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    bed_id uuid NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    period tstzrange GENERATED ALWAYS AS (tstzrange(starts_at, ends_at, '[)'::text)) STORED,
    reason text NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    feed_id uuid,
    external_uid text,
    CONSTRAINT bed_blocks_check CHECK ((ends_at > starts_at)),
    CONSTRAINT bed_blocks_external_uid_check CHECK ((char_length(external_uid) <= 300)),
    CONSTRAINT bed_blocks_reason_check CHECK (((char_length(btrim(reason)) >= 2) AND (char_length(btrim(reason)) <= 200)))
);

--
-- Name: beds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.beds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    room_id uuid NOT NULL,
    label text NOT NULL,
    "position" public.bed_position DEFAULT 'single'::public.bed_position NOT NULL,
    rate_paise integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    max_guests smallint DEFAULT 1 NOT NULL,
    base_guests smallint DEFAULT 1 NOT NULL,
    extra_guest_paise integer DEFAULT 0 NOT NULL,
    ical_token uuid DEFAULT gen_random_uuid() NOT NULL,
    hk_status text DEFAULT 'clean'::text NOT NULL,
    hk_note text,
    hk_updated_at timestamp with time zone,
    hk_by uuid,
    CONSTRAINT beds_base_guests_check CHECK (((base_guests >= 1) AND (base_guests <= 20))),
    CONSTRAINT beds_extra_guest_paise_check CHECK (((extra_guest_paise >= 0) AND (extra_guest_paise <= 10000000))),
    CONSTRAINT beds_hk_note_check CHECK ((char_length(hk_note) <= 200)),
    CONSTRAINT beds_hk_status_check CHECK ((hk_status = ANY (ARRAY['clean'::text, 'dirty'::text, 'cleaning'::text, 'inspect'::text]))),
    CONSTRAINT beds_label_check CHECK (((char_length(btrim(label)) >= 1) AND (char_length(btrim(label)) <= 40))),
    CONSTRAINT beds_max_guests_check CHECK (((max_guests >= 1) AND (max_guests <= 20))),
    CONSTRAINT beds_rate_paise_check CHECK (((rate_paise >= 0) AND (rate_paise <= 10000000)))
);

--
-- Name: extra_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.extra_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    category text DEFAULT 'other'::text NOT NULL,
    price_paise integer NOT NULL,
    unit text DEFAULT 'each'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT extra_items_category_check CHECK ((category = ANY (ARRAY['food'::text, 'laundry'::text, 'rental'::text, 'transport'::text, 'tour'::text, 'other'::text]))),
    CONSTRAINT extra_items_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 80))),
    CONSTRAINT extra_items_price_paise_check CHECK (((price_paise >= 0) AND (price_paise <= 100000000))),
    CONSTRAINT extra_items_unit_check CHECK ((char_length(unit) <= 30))
);

--
-- Name: rate_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rate_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    kind text NOT NULL,
    weekdays smallint[],
    date_from date,
    date_to date,
    adjust text NOT NULL,
    value integer NOT NULL,
    room_ids uuid[],
    min_nights smallint,
    priority smallint DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rate_rules_adjust_check CHECK ((adjust = ANY (ARRAY['percent'::text, 'amount'::text, 'fixed'::text]))),
    CONSTRAINT rate_rules_check CHECK (((kind <> 'weekend'::text) OR ((weekdays IS NOT NULL) AND (cardinality(weekdays) > 0)))),
    CONSTRAINT rate_rules_check1 CHECK (((kind <> 'season'::text) OR ((date_from IS NOT NULL) AND (date_to IS NOT NULL) AND (date_to >= date_from)))),
    CONSTRAINT rate_rules_check2 CHECK (((adjust <> 'percent'::text) OR ((value >= '-90'::integer) AND (value <= 300)))),
    CONSTRAINT rate_rules_check3 CHECK (((adjust <> 'fixed'::text) OR (value > 0))),
    CONSTRAINT rate_rules_kind_check CHECK ((kind = ANY (ARRAY['weekend'::text, 'season'::text]))),
    CONSTRAINT rate_rules_min_nights_check CHECK (((min_nights IS NULL) OR ((min_nights >= 2) AND (min_nights <= 30)))),
    CONSTRAINT rate_rules_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 60))),
    CONSTRAINT rate_rules_weekdays_check CHECK (((weekdays IS NULL) OR (weekdays <@ ARRAY[(0)::smallint, (1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint])))
);

--
-- Name: rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rooms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    sort integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rooms_description_check CHECK ((char_length(description) <= 200)),
    CONSTRAINT rooms_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 80)))
);

--
-- Name: bed_blocks bed_blocks_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bed_blocks
    ADD CONSTRAINT bed_blocks_no_overlap EXCLUDE USING gist (bed_id WITH =, period WITH &&);

--
-- Name: bed_blocks bed_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bed_blocks
    ADD CONSTRAINT bed_blocks_pkey PRIMARY KEY (id);

--
-- Name: beds beds_id_property_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beds
    ADD CONSTRAINT beds_id_property_id_key UNIQUE (id, property_id);

--
-- Name: beds beds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beds
    ADD CONSTRAINT beds_pkey PRIMARY KEY (id);

--
-- Name: beds beds_room_id_label_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beds
    ADD CONSTRAINT beds_room_id_label_key UNIQUE (room_id, label);

--
-- Name: extra_items extra_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extra_items
    ADD CONSTRAINT extra_items_pkey PRIMARY KEY (id);

--
-- Name: rate_rules rate_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_rules
    ADD CONSTRAINT rate_rules_pkey PRIMARY KEY (id);

--
-- Name: rooms rooms_id_property_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_id_property_id_key UNIQUE (id, property_id);

--
-- Name: rooms rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_pkey PRIMARY KEY (id);

--
-- Name: rooms rooms_property_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_property_id_name_key UNIQUE (property_id, name);

--
-- Name: bed_blocks_feed_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bed_blocks_feed_uid ON public.bed_blocks USING btree (feed_id, external_uid) WHERE (feed_id IS NOT NULL);

--
-- Name: bed_blocks_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bed_blocks_property ON public.bed_blocks USING gist (property_id, period);

--
-- Name: beds_ical_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX beds_ical_token ON public.beds USING btree (ical_token);

--
-- Name: beds_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX beds_property ON public.beds USING btree (property_id, sort);

--
-- Name: extra_items_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX extra_items_prop ON public.extra_items USING btree (property_id, is_active, sort);

--
-- Name: rate_rules_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rate_rules_prop ON public.rate_rules USING btree (property_id) WHERE is_active;

--
-- Name: bed_blocks bed_blocks_require_access; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bed_blocks_require_access BEFORE INSERT ON public.bed_blocks FOR EACH ROW EXECUTE FUNCTION public._require_access();

--
-- Name: beds beds_require_access; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER beds_require_access BEFORE INSERT OR UPDATE ON public.beds FOR EACH ROW EXECUTE FUNCTION public._require_access();

--
-- Name: bed_blocks cx_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cx_touch AFTER INSERT OR DELETE OR UPDATE ON public.bed_blocks FOR EACH ROW EXECUTE FUNCTION public._cx_touch();

--
-- Name: beds cx_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cx_touch AFTER INSERT OR DELETE OR UPDATE ON public.beds FOR EACH ROW EXECUTE FUNCTION public._cx_touch();

--
-- Name: rate_rules cx_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER cx_touch AFTER INSERT OR DELETE OR UPDATE ON public.rate_rules FOR EACH ROW EXECUTE FUNCTION public._cx_touch();

--
-- Name: beds perm_beds; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perm_beds BEFORE INSERT OR DELETE OR UPDATE ON public.beds FOR EACH ROW EXECUTE FUNCTION public._perm_rooms();

--
-- Name: extra_items perm_extra_items; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perm_extra_items BEFORE INSERT OR DELETE OR UPDATE ON public.extra_items FOR EACH ROW EXECUTE FUNCTION public._perm_rooms();

--
-- Name: rooms perm_rooms; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perm_rooms BEFORE INSERT OR DELETE OR UPDATE ON public.rooms FOR EACH ROW EXECUTE FUNCTION public._perm_rooms();

--
-- Name: rooms rooms_require_access; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER rooms_require_access BEFORE INSERT OR UPDATE ON public.rooms FOR EACH ROW EXECUTE FUNCTION public._require_access();

--
-- Name: bed_blocks bed_blocks_bed_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bed_blocks
    ADD CONSTRAINT bed_blocks_bed_id_property_id_fkey FOREIGN KEY (bed_id, property_id) REFERENCES public.beds(id, property_id) ON DELETE CASCADE;

--
-- Name: beds beds_room_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.beds
    ADD CONSTRAINT beds_room_id_property_id_fkey FOREIGN KEY (room_id, property_id) REFERENCES public.rooms(id, property_id) ON DELETE RESTRICT;

--
-- Name: extra_items extra_items_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extra_items
    ADD CONSTRAINT extra_items_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: rate_rules rate_rules_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_rules
    ADD CONSTRAINT rate_rules_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: rooms rooms_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: bed_blocks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bed_blocks ENABLE ROW LEVEL SECURITY;

--
-- Name: beds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.beds ENABLE ROW LEVEL SECURITY;

--
-- Name: beds beds_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY beds_select ON public.beds FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: beds beds_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY beds_write ON public.beds TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids))) WITH CHECK ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids)));

--
-- Name: bed_blocks blocks_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY blocks_select ON public.bed_blocks FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: bed_blocks blocks_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY blocks_write ON public.bed_blocks TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids))) WITH CHECK ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids)));

--
-- Name: extra_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.extra_items ENABLE ROW LEVEL SECURITY;

--
-- Name: extra_items extras_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY extras_select ON public.extra_items FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: extra_items extras_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY extras_write ON public.extra_items TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids))) WITH CHECK ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids)));

--
-- Name: rate_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rate_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: rate_rules rate_rules_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rate_rules_select ON public.rate_rules FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: rooms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;

--
-- Name: rooms rooms_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rooms_select ON public.rooms FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: rooms rooms_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rooms_write ON public.rooms TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids))) WITH CHECK ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids)));

--
-- Name: FUNCTION _night_rate(p_property uuid, p_room uuid, p_base integer, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._night_rate(p_property uuid, p_room uuid, p_base integer, p_day date) FROM PUBLIC;

--
-- Name: FUNCTION _stay_rate(p_bed uuid, p_in timestamp with time zone, p_out timestamp with time zone, p_base integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._stay_rate(p_bed uuid, p_in timestamp with time zone, p_out timestamp with time zone, p_base integer) FROM PUBLIC;

--
-- Name: FUNCTION available_beds(p_property uuid, p_in timestamp with time zone, p_out timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.available_beds(p_property uuid, p_in timestamp with time zone, p_out timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.available_beds(p_property uuid, p_in timestamp with time zone, p_out timestamp with time zone) TO authenticated;

--
-- Name: FUNCTION bed_board(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.bed_board(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.bed_board(p_property uuid) TO authenticated;

--
-- Name: FUNCTION rate_preview(p_bed uuid, p_from date, p_days integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rate_preview(p_bed uuid, p_from date, p_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rate_preview(p_bed uuid, p_from date, p_days integer) TO authenticated;

--
-- Name: FUNCTION rate_rule_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rate_rule_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rate_rule_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION rate_rule_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.rate_rule_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rate_rule_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION set_bed_block(p_bed uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_bed_block(p_bed uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_bed_block(p_bed uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text) TO authenticated;

--
-- Name: TABLE bed_blocks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bed_blocks TO authenticated;

--
-- Name: TABLE beds; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.beds TO authenticated;

--
-- Name: TABLE extra_items; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.extra_items TO authenticated;

--
-- Name: TABLE rate_rules; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.rate_rules TO authenticated;

--
-- Name: TABLE rooms; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rooms TO authenticated;
