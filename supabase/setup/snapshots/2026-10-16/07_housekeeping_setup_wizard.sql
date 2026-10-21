-- =====================================================================
-- NammaStay · housekeeping setup wizard
-- Housekeeping board, first-time setup wizard
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
-- Name: hk_board(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.hk_board(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: hk_counts(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.hk_counts(p_property uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object('dirty', count(*) filter (where hk_status = 'dirty'), 'cleaning', count(*) filter (where hk_status = 'cleaning'),
                            'inspect', count(*) filter (where hk_status = 'inspect'))
    from public.beds where property_id = p_property and is_active
     and p_property in (select public.my_property_ids())
$$;

--
-- Name: hk_set(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.hk_set(p_bed uuid, p_status text, p_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.beds where id = p_bed;
  if v_prop is null then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);
  if p_status not in ('clean','dirty','cleaning','inspect') then raise exception 'Unknown status.'; end if;
  update public.beds set hk_status = p_status, hk_note = nullif(left(btrim(coalesce(p_note, '')), 200), ''), hk_updated_at = now(), hk_by = auth.uid() where id = p_bed;
end $$;

--
-- Name: setup_finish(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.setup_finish(p_property uuid, p_done boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  update public.properties set setup_done_at = case when p_done then coalesce(setup_done_at, now()) end where id = p_property;
end $$;

--
-- Name: setup_progress(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.setup_progress(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare p public.properties%rowtype;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  select * into p from public.properties where id = p_property;
  return jsonb_build_object(
    'done_at', p.setup_done_at,
    'details', p.phone is not null and p.address is not null and p.city is not null,
    'rooms', exists (select 1 from public.beds where property_id = p_property and is_active),
    'upi', p.upi_id is not null,
    'staff', (select count(*) from public.property_members where property_id = p_property) > 1,
    'booking', exists (select 1 from public.bookings where property_id = p_property));
end $$;

--
-- Name: FUNCTION hk_board(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.hk_board(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.hk_board(p_property uuid) TO authenticated;

--
-- Name: FUNCTION hk_counts(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.hk_counts(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.hk_counts(p_property uuid) TO authenticated;

--
-- Name: FUNCTION hk_set(p_bed uuid, p_status text, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.hk_set(p_bed uuid, p_status text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.hk_set(p_bed uuid, p_status text, p_note text) TO authenticated;

--
-- Name: FUNCTION setup_finish(p_property uuid, p_done boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.setup_finish(p_property uuid, p_done boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.setup_finish(p_property uuid, p_done boolean) TO authenticated;

--
-- Name: FUNCTION setup_progress(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.setup_progress(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.setup_progress(p_property uuid) TO authenticated;
