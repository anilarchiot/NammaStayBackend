-- =====================================================================
-- NammaStay · properties team permissions
-- Properties, team members, roles & permissions, invites, activity log, notifications
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
-- Name: properties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.properties (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'hostel'::text NOT NULL,
    address text,
    city text,
    phone text,
    email text,
    upi_id text,
    timezone text DEFAULT 'Asia/Kolkata'::text NOT NULL,
    checkin_time time without time zone DEFAULT '14:00:00'::time without time zone NOT NULL,
    checkout_time time without time zone DEFAULT '11:00:00'::time without time zone NOT NULL,
    id_doc_retention_days integer DEFAULT 180 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    role_permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    legal_name text,
    gstin text,
    gst_mode text DEFAULT 'none'::text NOT NULL,
    gst_rate numeric(5,2) DEFAULT 5 NOT NULL,
    extras_gst_rate numeric(5,2) DEFAULT 5 NOT NULL,
    invoice_prefix text DEFAULT 'INV'::text NOT NULL,
    offers jsonb DEFAULT '{"tiers": [{"pct": 5, "from_stay": 2}, {"pct": 10, "from_stay": 5}], "enabled": false}'::jsonb NOT NULL,
    bill_name text,
    bill_gstin text,
    bill_address text,
    bill_state text,
    setup_done_at timestamp with time zone,
    CONSTRAINT properties_address_check CHECK ((char_length(address) <= 300)),
    CONSTRAINT properties_bill_address_check CHECK ((char_length(bill_address) <= 300)),
    CONSTRAINT properties_bill_gstin_check CHECK (((bill_gstin IS NULL) OR (bill_gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'::text))),
    CONSTRAINT properties_bill_name_check CHECK ((char_length(bill_name) <= 120)),
    CONSTRAINT properties_bill_state_check CHECK (((bill_state IS NULL) OR (bill_state ~ '^[0-9]{2}$'::text))),
    CONSTRAINT properties_city_check CHECK ((char_length(city) <= 80)),
    CONSTRAINT properties_email_check CHECK (((email IS NULL) OR (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text))),
    CONSTRAINT properties_extras_gst_rate_check CHECK (((extras_gst_rate >= (0)::numeric) AND (extras_gst_rate <= (28)::numeric))),
    CONSTRAINT properties_gst_mode_check CHECK ((gst_mode = ANY (ARRAY['none'::text, 'auto'::text, 'fixed'::text]))),
    CONSTRAINT properties_gst_rate_check CHECK (((gst_rate >= (0)::numeric) AND (gst_rate <= (28)::numeric))),
    CONSTRAINT properties_gstin_check CHECK (((gstin IS NULL) OR (gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'::text))),
    CONSTRAINT properties_id_doc_retention_days_check CHECK (((id_doc_retention_days >= 1) AND (id_doc_retention_days <= 3650))),
    CONSTRAINT properties_invoice_prefix_check CHECK ((invoice_prefix ~ '^[A-Z0-9-]{1,10}$'::text)),
    CONSTRAINT properties_kind_check CHECK ((kind = ANY (ARRAY['hostel'::text, 'hotel'::text, 'homestay'::text]))),
    CONSTRAINT properties_legal_name_check CHECK ((char_length(legal_name) <= 120)),
    CONSTRAINT properties_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 120))),
    CONSTRAINT properties_offers_check CHECK ((jsonb_typeof(offers) = 'object'::text)),
    CONSTRAINT properties_phone_check CHECK ((char_length(phone) <= 20)),
    CONSTRAINT properties_role_permissions_check CHECK ((jsonb_typeof(role_permissions) = 'object'::text)),
    CONSTRAINT properties_upi_id_check CHECK (((upi_id IS NULL) OR (upi_id ~ '^[A-Za-z0-9._-]{2,255}@[A-Za-z]{2,64}$'::text)))
);

--
-- Name: add_member(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_member(p_property uuid, p_email text, p_role text, p_name text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_user uuid;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select id into v_user from auth.users where lower(email) = lower(btrim(p_email));
  if v_user is null then
    raise exception 'No login exists for %. Invite them from Supabase → Authentication → Users first.', p_email;
  end if;
  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (p_property, v_user, p_role::public.member_role, nullif(btrim(p_name), ''), lower(btrim(p_email)))
  on conflict (property_id, user_id)
  do update set role = excluded.role, display_name = coalesce(excluded.display_name, property_members.display_name);
end $$;

--
-- Name: claim_property_invites(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_property_invites() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_uid uuid := auth.uid(); v_email text; v_n int := 0; r record;
begin
  if v_uid is null then return 0; end if;
  select lower(email) into v_email from auth.users where id = v_uid;
  for r in select * from public.property_invites where lower(email) = v_email and claimed_at is null for update loop
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (r.property_id, v_uid, r.role, r.display_name, v_email)
    on conflict (property_id, user_id) do update set role = excluded.role;
    update public.property_invites set claimed_by = v_uid, claimed_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

--
-- Name: create_my_property(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_my_property(p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_uid uuid := auth.uid(); v_email text; v_prop uuid;
begin
  if v_uid is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  if exists (select 1 from public.property_members where user_id = v_uid) then
    raise exception 'Your account already has a property. To add another, contact NammaStay support.';
  end if;
  if coalesce(char_length(btrim(p->>'name')), 0) < 2 then raise exception 'Please enter your property name.'; end if;
  select email into v_email from auth.users where id = v_uid;

  insert into public.properties (name, kind, city, phone, email)
  values (left(btrim(p->>'name'), 120),
          coalesce(nullif(p->>'kind', ''), 'hostel'),
          left(nullif(btrim(p->>'city'), ''), 80),
          left(nullif(btrim(p->>'phone'), ''), 20),
          v_email)
  returning id into v_prop;                         -- trigger starts the free trial

  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (v_prop, v_uid, 'owner', left(nullif(btrim(p->>'owner_name'), ''), 80), v_email);

  return jsonb_build_object('property_id', v_prop,
    'trial_ends_at', (select trial_ends_at from public.subscriptions where property_id = v_prop));
end $$;

--
-- Name: list_members(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_members(p_property uuid) RETURNS TABLE(user_id uuid, display_name text, email text, role public.member_role, last_seen_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return query select m.user_id, m.display_name, m.email, m.role, m.last_seen_at
                 from public.property_members m where m.property_id = p_property
                order by m.role, m.display_name;
end $$;

--
-- Name: mark_notifications_read(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_notifications_read(p_property uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  update public.notifications set read_at = now()
   where property_id = p_property and read_at is null
     and (user_id is null or user_id = auth.uid())
     and property_id in (select public.my_property_ids())
$$;

--
-- Name: my_memberships(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_memberships() RETURNS TABLE(property_id uuid, property_name text, role public.member_role, display_name text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select m.property_id, p.name, m.role, m.display_name
    from public.property_members m join public.properties p on p.id = m.property_id
   where m.user_id = auth.uid()
   order by p.name
$$;

--
-- Name: remove_member(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_member(p_property uuid, p_user uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if (select role from public.property_members where property_id = p_property and user_id = p_user) = 'owner'
     and (select count(*) from public.property_members where property_id = p_property and role = 'owner') <= 1 then
    raise exception 'A property needs at least one owner.';
  end if;
  delete from public.property_members where property_id = p_property and user_id = p_user;
end $$;

--
-- Name: set_role_permissions(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_role_permissions(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v jsonb := '{}'::jsonb; r text; k text;
  v_perms text[] := array['view_reports','view_payments','record_payments','refunds','cancel_bookings','delete_bookings',
                          'delete_guests','manage_rooms','add_extras','export_data'];
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  foreach r in array array['manager','front_desk','accountant'] loop
    if p ? r and jsonb_typeof(p->r) = 'object' then
      v := v || jsonb_build_object(r, (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
                                        from jsonb_each(p->r) where key = any (v_perms) and jsonb_typeof(value) = 'boolean'));
    end if;
  end loop;
  update public.properties set role_permissions = v where id = p_property;
  return v;
end $$;

--
-- Name: touch_presence(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_presence(p_property uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  update public.property_members set last_seen_at = now()
   where property_id = p_property and user_id = auth.uid()
     and (last_seen_at is null or last_seen_at < now() - interval '5 minutes')
$$;

--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    property_id uuid NOT NULL,
    entity text NOT NULL,
    entity_id uuid NOT NULL,
    booking_id uuid,
    action text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    actor uuid,
    at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    user_id uuid,
    kind text NOT NULL,
    title text NOT NULL,
    body text,
    booking_id uuid,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: property_invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    email text NOT NULL,
    role public.member_role DEFAULT 'owner'::public.member_role NOT NULL,
    display_name text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    claimed_by uuid,
    claimed_at timestamp with time zone,
    CONSTRAINT property_invites_display_name_check CHECK ((char_length(display_name) <= 80)),
    CONSTRAINT property_invites_email_check CHECK ((email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text))
);

--
-- Name: property_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_members (
    property_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role public.member_role NOT NULL,
    display_name text,
    email text,
    last_seen_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT property_members_display_name_check CHECK ((char_length(display_name) <= 80))
);

--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);

--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);

--
-- Name: properties properties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.properties
    ADD CONSTRAINT properties_pkey PRIMARY KEY (id);

--
-- Name: property_invites property_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_invites
    ADD CONSTRAINT property_invites_pkey PRIMARY KEY (id);

--
-- Name: property_invites property_invites_property_id_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_invites
    ADD CONSTRAINT property_invites_property_id_email_key UNIQUE (property_id, email);

--
-- Name: property_members property_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_members
    ADD CONSTRAINT property_members_pkey PRIMARY KEY (property_id, user_id);

--
-- Name: audit_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_booking ON public.audit_log USING btree (booking_id, at);

--
-- Name: audit_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_property ON public.audit_log USING btree (property_id, at DESC);

--
-- Name: notifications_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_recent ON public.notifications USING btree (property_id, created_at DESC);

--
-- Name: notifications_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_unread ON public.notifications USING btree (property_id, created_at DESC) WHERE (read_at IS NULL);

--
-- Name: property_invites_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX property_invites_email ON public.property_invites USING btree (lower(email)) WHERE (claimed_at IS NULL);

--
-- Name: property_members_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX property_members_user ON public.property_members USING btree (user_id);

--
-- Name: properties admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.properties FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: property_members members_require_access; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER members_require_access BEFORE INSERT ON public.property_members FOR EACH ROW EXECUTE FUNCTION public._require_access();

--
-- Name: properties pg_lock_kind; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER pg_lock_kind BEFORE UPDATE OF kind ON public.properties FOR EACH ROW EXECUTE FUNCTION public._pg_lock_kind();

--
-- Name: properties properties_start_trial; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER properties_start_trial AFTER INSERT ON public.properties FOR EACH ROW EXECUTE FUNCTION public._properties_start_trial();

--
-- Name: properties properties_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER properties_touch BEFORE UPDATE ON public.properties FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

--
-- Name: notifications notifications_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

--
-- Name: property_invites property_invites_claimed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_invites
    ADD CONSTRAINT property_invites_claimed_by_fkey FOREIGN KEY (claimed_by) REFERENCES auth.users(id) ON DELETE SET NULL;

--
-- Name: property_invites property_invites_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_invites
    ADD CONSTRAINT property_invites_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: property_members property_members_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_members
    ADD CONSTRAINT property_members_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: property_members property_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_members
    ADD CONSTRAINT property_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log audit_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY audit_select ON public.audit_log FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role]) AS my_property_ids)));

--
-- Name: property_members members_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY members_select ON public.property_members FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: notifications notif_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notif_select ON public.notifications FOR SELECT TO authenticated USING (((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)) AND ((user_id IS NULL) OR (user_id = ( SELECT auth.uid() AS uid)))));

--
-- Name: notifications notif_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notif_update ON public.notifications FOR UPDATE TO authenticated USING (((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)) AND ((user_id IS NULL) OR (user_id = ( SELECT auth.uid() AS uid))))) WITH CHECK ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: properties; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.properties ENABLE ROW LEVEL SECURITY;

--
-- Name: properties properties_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY properties_select ON public.properties FOR SELECT TO authenticated USING ((id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: properties properties_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY properties_update ON public.properties FOR UPDATE TO authenticated USING ((id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids))) WITH CHECK ((id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids)));

--
-- Name: property_invites; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.property_invites ENABLE ROW LEVEL SECURITY;

--
-- Name: property_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.property_members ENABLE ROW LEVEL SECURITY;

--
-- Name: TABLE properties; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.name; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(name) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.kind; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(kind) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.address; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(address) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.city; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(city) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.phone; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(phone) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.email; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(email) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.upi_id; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(upi_id) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.checkin_time; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(checkin_time) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.checkout_time; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(checkout_time) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.id_doc_retention_days; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(id_doc_retention_days) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.legal_name; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(legal_name) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.gstin; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(gstin) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.gst_mode; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(gst_mode) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.gst_rate; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(gst_rate) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.extras_gst_rate; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(extras_gst_rate) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.invoice_prefix; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(invoice_prefix) ON TABLE public.properties TO authenticated;

--
-- Name: COLUMN properties.offers; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(offers) ON TABLE public.properties TO authenticated;

--
-- Name: FUNCTION add_member(p_property uuid, p_email text, p_role text, p_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.add_member(p_property uuid, p_email text, p_role text, p_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_member(p_property uuid, p_email text, p_role text, p_name text) TO authenticated;

--
-- Name: FUNCTION claim_property_invites(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_property_invites() FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_property_invites() TO authenticated;

--
-- Name: FUNCTION create_my_property(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_my_property(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_my_property(p jsonb) TO authenticated;

--
-- Name: FUNCTION list_members(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_members(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_members(p_property uuid) TO authenticated;

--
-- Name: FUNCTION mark_notifications_read(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.mark_notifications_read(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_notifications_read(p_property uuid) TO authenticated;

--
-- Name: FUNCTION my_memberships(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_memberships() FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_memberships() TO authenticated;

--
-- Name: FUNCTION remove_member(p_property uuid, p_user uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.remove_member(p_property uuid, p_user uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_member(p_property uuid, p_user uuid) TO authenticated;

--
-- Name: FUNCTION set_role_permissions(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_role_permissions(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_role_permissions(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION touch_presence(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.touch_presence(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.touch_presence(p_property uuid) TO authenticated;

--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.audit_log TO authenticated;

--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.notifications TO authenticated;

--
-- Name: COLUMN notifications.read_at; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(read_at) ON TABLE public.notifications TO authenticated;

--
-- Name: TABLE property_members; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.property_members TO authenticated;

-- ---------------------------------------------------------------- storage, realtime & default rows
-- live updates for the bell icon
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; end $$;
