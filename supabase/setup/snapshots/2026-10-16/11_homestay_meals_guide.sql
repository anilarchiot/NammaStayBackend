-- =====================================================================
-- NammaStay · homestay meals guide
-- Homestay: meal plans, kitchen list, house guide
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
-- Name: booking_meal_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_meal_get(p_booking uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid; m public.booking_meals%rowtype; b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select * into m from public.booking_meals where booking_id = p_booking;
  if not found then return jsonb_build_object('plan', null); end if;
  return jsonb_build_object('plan', jsonb_build_object('plan_id', m.plan_id, 'name', m.plan_name, 'breakfast', m.breakfast, 'lunch', m.lunch,
    'dinner', m.dinner, 'adults', m.adults, 'children', m.children, 'nights', m.nights, 'amount_paise', m.amount_paise,
    'charged', exists (select 1 from public.booking_charges c where c.id = m.charge_id),
    'stale', (m.nights <> b.nights or m.adults <> b.visitors or m.children <> coalesce(b.children, 0))));
end $$;

--
-- Name: booking_meal_set(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.booking_meal_set(p_booking uuid, p_plan uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare b public.bookings%rowtype; mp public.meal_plans%rowtype; old public.booking_meals%rowtype;
  v_night int; v_amt int; v_charge jsonb; v_meals text;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  select * into old from public.booking_meals where booking_id = p_booking for update;
  if found and old.charge_id is not null and exists (select 1 from public.booking_charges where id = old.charge_id) then
    perform public.remove_charge(old.charge_id);                       -- the old "Meals: …" line comes off the bill
  end if;
  delete from public.booking_meals where booking_id = p_booking;
  if p_plan is null then return jsonb_build_object('plan', null); end if;

  select * into mp from public.meal_plans where id = p_plan and property_id = b.property_id;
  if not found then raise exception 'That meal plan isn’t in your list any more.'; end if;
  v_night := mp.adult_paise * greatest(b.visitors, 1) + mp.child_paise * coalesce(b.children, 0);
  v_amt := v_night * b.nights;
  v_meals := array_to_string(array_remove(array[case when mp.breakfast then 'breakfast' end, case when mp.lunch then 'lunch' end,
                                                case when mp.dinner then 'dinner' end], null), ' + ');
  if v_night > 0 then
    v_charge := public.add_charge(p_booking, jsonb_build_object('name', left('Meals: ' || mp.name, 80), 'category', 'food',
      'qty', b.nights, 'unit_price_paise', v_night,
      'note', left(greatest(b.visitors, 1) || ' adult' || case when b.visitors > 1 then 's' else '' end
              || case when coalesce(b.children, 0) > 0 then ' + ' || b.children || ' child' || case when b.children > 1 then 'ren' else '' end else '' end
              || ', every night (' || v_meals || ')', 200),
      'charged_on', public._local_date(b.property_id, b.check_in_at)));
  end if;
  insert into public.booking_meals (booking_id, property_id, plan_id, plan_name, breakfast, lunch, dinner, adults, children, nights, amount_paise, charge_id)
  values (b.id, b.property_id, mp.id, mp.name, mp.breakfast, mp.lunch, mp.dinner, greatest(b.visitors, 1), coalesce(b.children, 0), b.nights,
          coalesce(v_amt, 0), nullif(v_charge->>'id', '')::uuid);
  return jsonb_build_object('plan', mp.name, 'amount_paise', coalesce(v_amt, 0));
end $$;

--
-- Name: guide_for_token(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guide_for_token(p_token uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce((
    select (to_jsonb(g) - 'property_id' - 'updated_at' - case when b.check_in_at > now() + interval '1 day' then 'wifi_password' else '' end)
           || jsonb_build_object('property', p.name)
      from public.bookings b
      join public.property_guide g on g.property_id = b.property_id
      join public.properties p on p.id = b.property_id
     where b.self_checkin_token = p_token and b.status in ('pending','confirmed','checked_in') and b.check_out_at > now()
     limit 1), '{}'::jsonb)
$$;

--
-- Name: guide_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guide_get(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return coalesce((select to_jsonb(g) - 'property_id' from public.property_guide g where property_id = p_property), '{}'::jsonb);
end $$;

--
-- Name: guide_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guide_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare t text[] := array['welcome','house_rules','wifi_name','wifi_password','directions','maps_url','host_name','host_phone','checkin_info','checkout_info','food_info'];
  v jsonb := '{}'::jsonb; k text; v_phone text;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  foreach k in array t loop v := v || jsonb_build_object(k, nullif(btrim(coalesce(p->>k, '')), '')); end loop;
  v_phone := nullif(regexp_replace(coalesce(v->>'host_phone', ''), '[\s\-()]', '', 'g'), '');
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the host phone number.'; end if;
  if v->>'maps_url' is not null and v->>'maps_url' !~* '^https?://' then raise exception 'The map link should start with https://'; end if;
  insert into public.property_guide as g (property_id, welcome, house_rules, wifi_name, wifi_password, directions, maps_url, host_name, host_phone,
                                          checkin_info, checkout_info, food_info, updated_at)
  values (p_property, v->>'welcome', v->>'house_rules', v->>'wifi_name', v->>'wifi_password', v->>'directions', v->>'maps_url', v->>'host_name',
          v_phone, v->>'checkin_info', v->>'checkout_info', v->>'food_info', now())
  on conflict (property_id) do update set welcome = excluded.welcome, house_rules = excluded.house_rules, wifi_name = excluded.wifi_name,
     wifi_password = excluded.wifi_password, directions = excluded.directions, maps_url = excluded.maps_url, host_name = excluded.host_name,
     host_phone = excluded.host_phone, checkin_info = excluded.checkin_info, checkout_info = excluded.checkout_info,
     food_info = excluded.food_info, updated_at = now();
  return jsonb_build_object('ok', true);
end $_$;

--
-- Name: kitchen_list(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kitchen_list(p_property uuid, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_tz text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  return (with x as (
      select b.id, b.code, g.full_name, r.name as room, bd.label as unit, m.plan_name, m.breakfast, m.lunch, m.dinner,
             greatest(b.visitors, 1) as adults, coalesce(b.children, 0) as children,
             (b.check_in_at at time zone v_tz)::date as d_in, (b.check_out_at at time zone v_tz)::date as d_out, b.status
        from public.booking_meals m
        join public.bookings b on b.id = m.booking_id
        join public.guests g on g.id = b.guest_id
        join public.beds bd on bd.id = b.bed_id
        join public.rooms r on r.id = bd.room_id
       where m.property_id = p_property and b.status in ('pending','confirmed','checked_in','checked_out')
         and (b.check_in_at at time zone v_tz)::date <= p_day and (b.check_out_at at time zone v_tz)::date >= p_day),
    y as (select *, (breakfast and d_in < p_day) as has_b, (lunch and d_out > p_day) as has_l, (dinner and d_out > p_day) as has_d from x)
    select jsonb_build_object('day', p_day,
      'totals', jsonb_build_object(
        'breakfast', coalesce(sum(case when has_b then adults + children end), 0),
        'lunch', coalesce(sum(case when has_l then adults + children end), 0),
        'dinner', coalesce(sum(case when has_d then adults + children end), 0)),
      'rows', coalesce(jsonb_agg(jsonb_build_object('booking_id', id, 'code', code, 'guest', full_name, 'room', room, 'unit', unit,
          'plan', plan_name, 'adults', adults, 'children', children, 'breakfast', has_b, 'lunch', has_l, 'dinner', has_d)
          order by room, unit) filter (where has_b or has_l or has_d), '[]'::jsonb))
    from y);
end $$;

--
-- Name: meal_plan_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.meal_plan_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.meal_plans where id = p_id;
  if v_prop is null then raise exception 'Meal plan not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.meal_plans where id = p_id;          -- bookings keep their plan name and bill line
end $$;

--
-- Name: meal_plan_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.meal_plan_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', ''));
  v_b boolean := coalesce((p->>'breakfast')::boolean, false); v_l boolean := coalesce((p->>'lunch')::boolean, false);
  v_d boolean := coalesce((p->>'dinner')::boolean, false);
  v_a int := coalesce(nullif(p->>'adult_paise', '')::int, 0); v_c int := coalesce(nullif(p->>'child_paise', '')::int, 0);
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if char_length(v_name) < 1 then raise exception 'Give the meal plan a name, e.g. “Breakfast included”.'; end if;
  if not (v_b or v_l or v_d) then raise exception 'Tick at least one meal (breakfast, lunch or dinner).'; end if;
  if v_a < 0 or v_c < 0 or v_a > 10000000 or v_c > 10000000 then raise exception 'Enter a price between ₹0 and ₹1,00,000.'; end if;
  if v_id is null then
    if (select count(*) from public.meal_plans where property_id = p_property) >= 12 then raise exception 'Up to 12 meal plans.'; end if;
    insert into public.meal_plans (property_id, name, breakfast, lunch, dinner, adult_paise, child_paise, is_active, sort)
    values (p_property, left(v_name, 60), v_b, v_l, v_d, v_a, v_c, coalesce((p->>'is_active')::boolean, true),
            coalesce((select max(sort) + 1 from public.meal_plans where property_id = p_property), 0))
    returning id into v_id;
  else
    update public.meal_plans set name = left(v_name, 60), breakfast = v_b, lunch = v_l, dinner = v_d, adult_paise = v_a, child_paise = v_c,
           is_active = coalesce((p->>'is_active')::boolean, is_active)
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Meal plan not found.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

--
-- Name: meal_plans_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.meal_plans_list(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'breakfast', breakfast, 'lunch', lunch, 'dinner', dinner,
      'adult_paise', adult_paise, 'child_paise', child_paise, 'is_active', is_active) order by sort, created_at)
    from public.meal_plans where property_id = p_property), '[]'::jsonb);
end $$;

--
-- Name: booking_meals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_meals (
    booking_id uuid NOT NULL,
    property_id uuid NOT NULL,
    plan_id uuid,
    plan_name text NOT NULL,
    breakfast boolean DEFAULT false NOT NULL,
    lunch boolean DEFAULT false NOT NULL,
    dinner boolean DEFAULT false NOT NULL,
    adults smallint DEFAULT 1 NOT NULL,
    children smallint DEFAULT 0 NOT NULL,
    nights smallint DEFAULT 1 NOT NULL,
    amount_paise integer DEFAULT 0 NOT NULL,
    charge_id uuid,
    note text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT booking_meals_note_check CHECK ((char_length(note) <= 200))
);

--
-- Name: meal_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    breakfast boolean DEFAULT false NOT NULL,
    lunch boolean DEFAULT false NOT NULL,
    dinner boolean DEFAULT false NOT NULL,
    adult_paise integer DEFAULT 0 NOT NULL,
    child_paise integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT meal_plans_adult_paise_check CHECK (((adult_paise >= 0) AND (adult_paise <= 10000000))),
    CONSTRAINT meal_plans_check CHECK ((breakfast OR lunch OR dinner)),
    CONSTRAINT meal_plans_child_paise_check CHECK (((child_paise >= 0) AND (child_paise <= 10000000))),
    CONSTRAINT meal_plans_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 60)))
);

--
-- Name: property_guide; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_guide (
    property_id uuid NOT NULL,
    welcome text,
    house_rules text,
    wifi_name text,
    wifi_password text,
    directions text,
    maps_url text,
    host_name text,
    host_phone text,
    checkin_info text,
    checkout_info text,
    food_info text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT property_guide_checkin_info_check CHECK ((char_length(checkin_info) <= 1000)),
    CONSTRAINT property_guide_checkout_info_check CHECK ((char_length(checkout_info) <= 1000)),
    CONSTRAINT property_guide_directions_check CHECK ((char_length(directions) <= 1500)),
    CONSTRAINT property_guide_food_info_check CHECK ((char_length(food_info) <= 1000)),
    CONSTRAINT property_guide_host_name_check CHECK ((char_length(host_name) <= 80)),
    CONSTRAINT property_guide_host_phone_check CHECK (((host_phone IS NULL) OR (host_phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT property_guide_house_rules_check CHECK ((char_length(house_rules) <= 2000)),
    CONSTRAINT property_guide_maps_url_check CHECK (((maps_url IS NULL) OR ((maps_url ~* '^https?://'::text) AND (char_length(maps_url) <= 500)))),
    CONSTRAINT property_guide_welcome_check CHECK ((char_length(welcome) <= 1000)),
    CONSTRAINT property_guide_wifi_name_check CHECK ((char_length(wifi_name) <= 80)),
    CONSTRAINT property_guide_wifi_password_check CHECK ((char_length(wifi_password) <= 80))
);

--
-- Name: booking_meals booking_meals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_meals
    ADD CONSTRAINT booking_meals_pkey PRIMARY KEY (booking_id);

--
-- Name: meal_plans meal_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_plans
    ADD CONSTRAINT meal_plans_pkey PRIMARY KEY (id);

--
-- Name: property_guide property_guide_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_guide
    ADD CONSTRAINT property_guide_pkey PRIMARY KEY (property_id);

--
-- Name: booking_meals_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_meals_property ON public.booking_meals USING btree (property_id);

--
-- Name: meal_plans_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meal_plans_property ON public.meal_plans USING btree (property_id, sort);

--
-- Name: booking_meals booking_meals_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_meals
    ADD CONSTRAINT booking_meals_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_meals booking_meals_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_meals
    ADD CONSTRAINT booking_meals_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.meal_plans(id) ON DELETE SET NULL;

--
-- Name: meal_plans meal_plans_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_plans
    ADD CONSTRAINT meal_plans_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: property_guide property_guide_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_guide
    ADD CONSTRAINT property_guide_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: booking_meals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_meals ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_meals booking_meals_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY booking_meals_select ON public.booking_meals FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: meal_plans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.meal_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: meal_plans meal_plans_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY meal_plans_select ON public.meal_plans FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: property_guide; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.property_guide ENABLE ROW LEVEL SECURITY;

--
-- Name: property_guide property_guide_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY property_guide_select ON public.property_guide FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: FUNCTION booking_meal_get(p_booking uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_meal_get(p_booking uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_meal_get(p_booking uuid) TO authenticated;

--
-- Name: FUNCTION booking_meal_set(p_booking uuid, p_plan uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.booking_meal_set(p_booking uuid, p_plan uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.booking_meal_set(p_booking uuid, p_plan uuid) TO authenticated;

--
-- Name: FUNCTION guide_for_token(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guide_for_token(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.guide_for_token(p_token uuid) TO authenticated;
GRANT ALL ON FUNCTION public.guide_for_token(p_token uuid) TO anon;

--
-- Name: FUNCTION guide_get(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guide_get(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.guide_get(p_property uuid) TO authenticated;

--
-- Name: FUNCTION guide_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guide_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.guide_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION kitchen_list(p_property uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.kitchen_list(p_property uuid, p_day date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.kitchen_list(p_property uuid, p_day date) TO authenticated;

--
-- Name: FUNCTION meal_plan_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.meal_plan_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.meal_plan_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION meal_plan_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.meal_plan_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.meal_plan_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION meal_plans_list(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.meal_plans_list(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.meal_plans_list(p_property uuid) TO authenticated;

--
-- Name: TABLE booking_meals; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.booking_meals TO authenticated;

--
-- Name: TABLE meal_plans; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.meal_plans TO authenticated;

--
-- Name: TABLE property_guide; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.property_guide TO authenticated;
