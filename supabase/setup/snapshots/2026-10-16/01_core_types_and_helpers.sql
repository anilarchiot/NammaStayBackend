-- =====================================================================
-- NammaStay · core types and helpers
-- Shared building blocks: enum types, access checks (role, permission, subscription), time helpers, trigger functions
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
-- Name: bed_position; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.bed_position AS ENUM (
    'lower',
    'upper',
    'single'
);

--
-- Name: booking_source; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.booking_source AS ENUM (
    'walk_in',
    'direct',
    'ota',
    'referral'
);

--
-- Name: booking_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.booking_status AS ENUM (
    'pending',
    'confirmed',
    'checked_in',
    'checked_out',
    'cancelled',
    'no_show'
);

--
-- Name: id_doc_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.id_doc_type AS ENUM (
    'aadhaar',
    'passport',
    'driving_licence',
    'pan',
    'voter_id',
    'other'
);

--
-- Name: lead_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.lead_status AS ENUM (
    'new',
    'contacted',
    'demo_booked',
    'won',
    'lost'
);

--
-- Name: member_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.member_role AS ENUM (
    'owner',
    'manager',
    'front_desk',
    'accountant'
);

--
-- Name: payment_kind; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_kind AS ENUM (
    'payment',
    'refund'
);

--
-- Name: payment_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_method AS ENUM (
    'upi',
    'cash',
    'card',
    'bank'
);

--
-- Name: sub_payment_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.sub_payment_status AS ENUM (
    'pending',
    'approved',
    'rejected'
);

--
-- Name: _access_state(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._access_state(p_property uuid) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare s public.subscriptions%rowtype; v_end timestamptz; v_grace int;
begin
  select * into s from public.subscriptions where property_id = p_property;
  if not found then return 'expired'; end if;
  if s.is_suspended then return 'suspended'; end if;
  if s.is_complimentary then return 'complimentary'; end if;
  if s.paid_until is not null and s.paid_until > now() then return 'active'; end if;
  if s.trial_ends_at > now() and (s.paid_until is null or s.paid_until <= now()) then return 'trial'; end if;
  v_end := greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at));
  select grace_days into v_grace from public.platform_settings where id = 1;
  if now() < v_end + make_interval(days => v_grace) then return 'grace'; end if;
  return 'expired';
end $$;

--
-- Name: _admin_audit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._admin_audit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare n jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end; o jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_diff jsonb; v_prop uuid; v_action text;
begin
  if auth.uid() is null or not exists (select 1 from public.platform_admins where user_id = auth.uid()) then return coalesce(new, old); end if;
  select jsonb_object_agg(k, jsonb_build_array(o->k, n->k)) into v_diff
    from jsonb_object_keys(coalesce(n, o)) k where k not in ('updated_at', 'doc') and (o is null or n is null or o->k is distinct from n->k);
  if tg_op = 'UPDATE' and v_diff is null then return new; end if;
  v_prop := coalesce(nullif(coalesce(n, o)->>'property_id', ''), case when tg_table_name = 'properties' then coalesce(n, o)->>'id' end)::uuid;
  v_action := case tg_table_name
    when 'subscriptions' then 'subscription_changed'
    when 'subscription_payments' then case when tg_op = 'UPDATE' and n->>'status' is distinct from o->>'status' then 'payment_' || (n->>'status') else 'payment_changed' end
    when 'plans' then 'plan_changed' when 'platform_settings' then 'settings_changed' when 'properties' then lower(tg_op) || '_property'
    when 'coupons' then lower(tg_op) || '_coupon' when 'leads' then 'lead_changed' when 'platform_admins' then lower(tg_op) || '_admin'
    else lower(tg_op) || '_' || tg_table_name end;
  insert into public.admin_actions (admin_id, admin_email, action, property_id, details)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), v_action, v_prop,
          jsonb_build_object('table', tg_table_name, 'changes', v_diff, 'key', coalesce(n, o)->>'id', 'code', coalesce(n, o)->>'code', 'name', coalesce(n, o)->>'name'));
  return coalesce(new, old);
end $$;

--
-- Name: _allowed(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._allowed(p_property uuid, p_perm text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_role public.member_role; v_set jsonb;
begin
  if auth.uid() is null then return true; end if;                -- SQL editor, scheduled jobs
  select role into v_role from public.property_members where property_id = p_property and user_id = auth.uid();
  if v_role is null then return false; end if;
  if v_role = 'owner' then return true; end if;
  select role_permissions -> (v_role::text) -> p_perm into v_set from public.properties where id = p_property;
  if v_set is not null and jsonb_typeof(v_set) = 'boolean' then return v_set::text::boolean; end if;
  return public._perm_default(v_role, p_perm);
end $$;

--
-- Name: _apply_rate_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._apply_rate_rules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: _assert_role(uuid, public.member_role[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._assert_role(p_property uuid, p_roles public.member_role[]) RETURNS public.member_role
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare r public.member_role;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '42501';
  end if;
  select role into r from public.property_members
   where property_id = p_property and user_id = auth.uid();
  if r is null or not (r = any (p_roles)) then
    raise exception 'You don''t have permission to do this.' using errcode = '42501';
  end if;
  return r;
end $$;

--
-- Name: _booking_guest_trash(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._booking_guest_trash() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  insert into public.booking_guest_doc_trash (path)
  select p from unnest(array_remove(array[old.id_doc_path, old.id_doc_back_path], null)) p;
  return old;
end $$;

--
-- Name: _bookings_audit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._bookings_audit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_guest text;
begin
  if tg_op = 'INSERT' then
    select full_name into v_guest from public.guests where id = new.guest_id;
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'created',
            jsonb_build_object('status', new.status, 'total_paise', new.total_paise), auth.uid());
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (new.property_id, 'booking_created',
            'New booking ' || new.code,
            v_guest || ' · ' || to_char(new.check_in_at at time zone 'Asia/Kolkata', 'DD Mon') ||
            ' – ' || to_char(new.check_out_at at time zone 'Asia/Kolkata', 'DD Mon'),
            new.id);
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'status',
            jsonb_build_object('from', old.status, 'to', new.status), auth.uid());
  end if;
  if new.check_in_at is distinct from old.check_in_at
     or new.check_out_at is distinct from old.check_out_at
     or new.bed_id is distinct from old.bed_id then
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'changed',
            jsonb_build_object('check_in_at', new.check_in_at, 'check_out_at', new.check_out_at,
                               'bed_changed', new.bed_id is distinct from old.bed_id,
                               'total_paise', new.total_paise), auth.uid());
  end if;
  if new.self_checkin_at is distinct from old.self_checkin_at and new.self_checkin_at is not null then
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (new.property_id, 'booking', new.id, new.id, 'self_checkin', '{}'::jsonb, null);
    insert into public.notifications (property_id, kind, title, body, booking_id)
    values (new.property_id, 'self_checkin', 'Self check-in submitted', new.code, new.id);
  end if;
  return new;
end $$;

--
-- Name: _coupon_used(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._coupon_used() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and new.coupon_code is not null then
    update public.coupons set used = used + 1 where code = new.coupon_code;
  end if;
  return new;
end $$;

--
-- Name: _cx_touch(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._cx_touch() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  update public.channex_links set dirty_at = now()
   where property_id = coalesce(new.property_id, old.property_id) and enabled;
  return coalesce(new, old);
end $$;

--
-- Name: _day_start(text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._day_start(p_tz text, p_day date) RETURNS timestamp with time zone
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select p_day::timestamp at time zone p_tz
$$;

--
-- Name: _hk_on_checkout(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._hk_on_checkout() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.status = 'checked_out' and old.status is distinct from 'checked_out' then
    update public.beds set hk_status = 'dirty', hk_note = null, hk_updated_at = now(), hk_by = auth.uid() where id = new.bed_id;
  end if;
  return new;
end $$;

--
-- Name: _local_date(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._local_date(p_property uuid, p_ts timestamp with time zone) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (p_ts at time zone public._tz(p_property))::date
$$;

--
-- Name: _night(text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._night(p_tz text, p_day date) RETURNS timestamp with time zone
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (p_day + time '20:00') at time zone p_tz
$$;

--
-- Name: _on_sub_payment_approved(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._on_sub_payment_approved() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then perform public._issue_platform_invoice(new.id); end if;
  return new;
end $$;

--
-- Name: _payments_audit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._payments_audit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (new.property_id, 'payment', new.id, new.booking_id, new.kind::text,
          jsonb_build_object('amount_paise', new.amount_paise, 'method', new.method, 'code', new.code),
          auth.uid());
  return new;
end $$;

--
-- Name: _payments_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._payments_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if tg_op = 'DELETE' and current_setting('nammastay.deleting_booking', true) = 'on' then
    return old;
  end if;
  raise exception 'Payments can''t be edited or deleted. Record a refund instead.';
end $$;

--
-- Name: _payments_sync_booking(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._payments_sync_booking() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  update public.bookings b
     set paid_paise = coalesce((
           select sum(case p.kind when 'payment' then p.amount_paise else -p.amount_paise end)
             from public.payments p where p.booking_id = new.booking_id), 0)
   where b.id = new.booking_id;
  return new;
end $$;

--
-- Name: _perm_bookings(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._perm_bookings() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if tg_op = 'DELETE' then perform public._require_perm(old.property_id, 'delete_bookings'); return old; end if;
  if new.status = 'cancelled' and old.status <> 'cancelled' then perform public._require_perm(new.property_id, 'cancel_bookings'); end if;
  return new;
end $$;

--
-- Name: _perm_charges(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._perm_charges() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._require_perm(coalesce(new.property_id, old.property_id), 'add_extras');
  return coalesce(new, old);
end $$;

--
-- Name: _perm_default(public.member_role, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._perm_default(p_role public.member_role, p_perm text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select case p_role
    when 'owner'      then true
    when 'manager'    then true
    when 'front_desk' then p_perm in ('view_payments','record_payments','cancel_bookings','delete_bookings','add_extras')
    when 'accountant' then p_perm in ('view_reports','view_payments','export_data')
    else false end
$$;

--
-- Name: _perm_guests(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._perm_guests() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin perform public._require_perm(old.property_id, 'delete_guests'); return old; end $$;

--
-- Name: _perm_payments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._perm_payments() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._require_perm(new.property_id, case new.kind when 'refund' then 'refunds' else 'record_payments' end);
  return new;
end $$;

--
-- Name: _perm_rooms(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._perm_rooms() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._require_perm(coalesce(new.property_id, old.property_id), 'manage_rooms');
  return coalesce(new, old);
end $$;

--
-- Name: _pg_keep_tenant_booking(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._pg_keep_tenant_booking() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_t uuid; v_cur uuid;
begin
  select id, booking_id into v_t, v_cur from public.tenancies where booking_ids @> array[new.id] limit 1;
  if v_t is null then return new; end if;
  new.rate_paise := 0;
  new.discount_paise := 0;
  new.extra_paise := 0;
  new.total_paise := coalesce(new.charges_paise, 0);
  if new.bed_id is distinct from old.bed_id and new.id = v_cur then
    update public.tenancies set bed_id = new.bed_id, updated_at = now() where id = v_t;
  end if;
  return new;
end $$;

--
-- Name: _pg_lock_kind(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._pg_lock_kind() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.kind is distinct from old.kind
     and exists (select 1 from public.pg_properties where property_id = old.id)
     and not public.is_platform_admin() then
    raise exception 'This is a PG / co-living account — the property type can''t be changed. Contact NammaStay support if you need to.'
      using errcode = '42501';
  end if;
  return new;
end $$;

--
-- Name: _properties_start_trial(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._properties_start_trial() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  insert into public.subscriptions (property_id, trial_ends_at)
  values (new.id, now() + make_interval(days => (select trial_days from public.platform_settings where id = 1)))
  on conflict (property_id) do nothing;
  return new;
end $$;

--
-- Name: _require_access(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._require_access() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if public._access_state(new.property_id) = 'suspended' then
    raise exception 'This property''s NammaStay account is suspended. Please contact NammaStay support.'
      using errcode = 'P0402', hint = 'account_suspended';
  end if;
  if public._access_state(new.property_id) = 'expired' then
    raise exception 'This property''s NammaStay subscription has ended. The owner can renew in Settings → Billing.'
      using errcode = 'P0402', hint = 'subscription_expired';
  end if;
  return new;
end $$;

--
-- Name: _require_perm(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._require_perm(p_property uuid, p_perm text) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if not public._allowed(p_property, p_perm) then
    raise exception '%', case p_perm
      when 'view_reports'    then 'Your role can’t see reports. Ask the owner.'
      when 'view_payments'   then 'Your role can’t see payments. Ask the owner.'
      when 'record_payments' then 'Your role can’t take payments. Ask the owner.'
      when 'refunds'         then 'Your role can’t give refunds. Ask the owner.'
      when 'cancel_bookings' then 'Your role can’t cancel bookings. Ask the owner.'
      when 'delete_bookings' then 'Your role can’t delete bookings. Ask the owner.'
      when 'delete_guests'   then 'Your role can’t delete guests. Ask the owner.'
      when 'manage_rooms'    then 'Your role can’t change rooms, beds or prices. Ask the owner.'
      when 'add_extras'      then 'Your role can’t add or remove extras. Ask the owner.'
      else 'Your role can’t do this. Ask the owner.' end
      using errcode = '42501';
  end if;
end $$;

--
-- Name: _touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  new.updated_at := now();
  return new;
end $$;

--
-- Name: _tz(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._tz(p_property uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select timezone from public.properties where id = p_property
$$;

--
-- Name: checkin_upload_allowed(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.checkin_upload_allowed(p_name text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare
  parts text[] := string_to_array(p_name, '/');
  v_ok boolean;
  v_count int;
begin
  if array_length(parts, 1) <> 3
     or parts[1] !~ '^[0-9a-f-]{36}$' or parts[2] !~ '^[0-9a-f-]{36}$' then
    return false;
  end if;
  select true into v_ok from public.bookings
   where property_id = parts[1]::uuid
     and self_checkin_token = parts[2]::uuid
     and status in ('pending','confirmed','checked_in')
     and check_out_at > now();
  if v_ok is not true then return false; end if;
  select count(*) into v_count from storage.objects
   where bucket_id = 'guest-ids' and name like parts[1] || '/' || parts[2] || '/%';
  return v_count < 4;
end $_$;

--
-- Name: is_platform_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_platform_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
     and (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
          or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'))
$$;

--
-- Name: my_property_ids(public.member_role[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_property_ids(p_roles public.member_role[] DEFAULT NULL::public.member_role[]) RETURNS SETOF uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select property_id from public.property_members
   where user_id = auth.uid()
     and (p_roles is null or role = any (p_roles))
$$;

--
-- Name: FUNCTION _access_state(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._access_state(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _admin_audit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._admin_audit() FROM PUBLIC;

--
-- Name: FUNCTION _allowed(p_property uuid, p_perm text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._allowed(p_property uuid, p_perm text) FROM PUBLIC;
GRANT ALL ON FUNCTION public._allowed(p_property uuid, p_perm text) TO authenticated;

--
-- Name: FUNCTION _apply_rate_rules(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._apply_rate_rules() FROM PUBLIC;

--
-- Name: FUNCTION _assert_role(p_property uuid, p_roles public.member_role[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._assert_role(p_property uuid, p_roles public.member_role[]) FROM PUBLIC;

--
-- Name: FUNCTION _booking_guest_trash(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._booking_guest_trash() FROM PUBLIC;

--
-- Name: FUNCTION _bookings_audit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._bookings_audit() FROM PUBLIC;

--
-- Name: FUNCTION _coupon_used(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._coupon_used() FROM PUBLIC;

--
-- Name: FUNCTION _cx_touch(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._cx_touch() FROM PUBLIC;

--
-- Name: FUNCTION _day_start(p_tz text, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._day_start(p_tz text, p_day date) FROM PUBLIC;

--
-- Name: FUNCTION _hk_on_checkout(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._hk_on_checkout() FROM PUBLIC;

--
-- Name: FUNCTION _local_date(p_property uuid, p_ts timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._local_date(p_property uuid, p_ts timestamp with time zone) FROM PUBLIC;

--
-- Name: FUNCTION _night(p_tz text, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._night(p_tz text, p_day date) FROM PUBLIC;

--
-- Name: FUNCTION _on_sub_payment_approved(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._on_sub_payment_approved() FROM PUBLIC;

--
-- Name: FUNCTION _payments_audit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._payments_audit() FROM PUBLIC;

--
-- Name: FUNCTION _payments_immutable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._payments_immutable() FROM PUBLIC;

--
-- Name: FUNCTION _payments_sync_booking(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._payments_sync_booking() FROM PUBLIC;

--
-- Name: FUNCTION _perm_bookings(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._perm_bookings() FROM PUBLIC;

--
-- Name: FUNCTION _perm_charges(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._perm_charges() FROM PUBLIC;

--
-- Name: FUNCTION _perm_default(p_role public.member_role, p_perm text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._perm_default(p_role public.member_role, p_perm text) FROM PUBLIC;

--
-- Name: FUNCTION _perm_guests(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._perm_guests() FROM PUBLIC;

--
-- Name: FUNCTION _perm_payments(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._perm_payments() FROM PUBLIC;

--
-- Name: FUNCTION _perm_rooms(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._perm_rooms() FROM PUBLIC;

--
-- Name: FUNCTION _pg_keep_tenant_booking(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._pg_keep_tenant_booking() FROM PUBLIC;

--
-- Name: FUNCTION _pg_lock_kind(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._pg_lock_kind() FROM PUBLIC;

--
-- Name: FUNCTION _properties_start_trial(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._properties_start_trial() FROM PUBLIC;

--
-- Name: FUNCTION _require_access(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._require_access() FROM PUBLIC;

--
-- Name: FUNCTION _require_perm(p_property uuid, p_perm text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._require_perm(p_property uuid, p_perm text) FROM PUBLIC;

--
-- Name: FUNCTION _touch_updated_at(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._touch_updated_at() FROM PUBLIC;

--
-- Name: FUNCTION _tz(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._tz(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION checkin_upload_allowed(p_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.checkin_upload_allowed(p_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.checkin_upload_allowed(p_name text) TO anon;
GRANT ALL ON FUNCTION public.checkin_upload_allowed(p_name text) TO authenticated;

--
-- Name: FUNCTION is_platform_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_platform_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_platform_admin() TO authenticated;

--
-- Name: FUNCTION my_property_ids(p_roles public.member_role[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_property_ids(p_roles public.member_role[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_property_ids(p_roles public.member_role[]) TO authenticated;
