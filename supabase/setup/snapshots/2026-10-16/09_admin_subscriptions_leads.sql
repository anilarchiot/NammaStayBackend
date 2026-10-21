-- =====================================================================
-- NammaStay · admin subscriptions leads
-- NammaStay admin: leads, plans & subscriptions, platform invoices, reminders, coupons, admin panel
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
-- Name: _assert_platform_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._assert_platform_admin() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
end $$;

--
-- Name: _coupon_quote(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._coupon_quote(p_plan text, p_code text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare c public.coupons%rowtype; pl public.plans%rowtype; v_disc int;
begin
  select * into pl from public.plans where id = p_plan;
  select * into c from public.coupons where code = upper(btrim(coalesce(p_code, '')));
  if not found or not c.is_active or (c.expires_at is not null and c.expires_at < now()) or (c.max_uses is not null and c.used >= c.max_uses) then
    raise exception 'That coupon code isn’t valid.';
  end if;
  if c.plan_ids is not null and not (p_plan = any (c.plan_ids)) then raise exception 'That coupon doesn’t apply to this plan.'; end if;
  v_disc := case c.kind when 'percent' then round(pl.price_paise * c.value / 100.0) else least(c.value, pl.price_paise - 100) end;
  return jsonb_build_object('code', c.code, 'discount_paise', v_disc, 'amount_paise', pl.price_paise - v_disc, 'price_paise', pl.price_paise);
end $$;

--
-- Name: _issue_platform_invoice(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._issue_platform_invoice(p_payment uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  sp public.subscription_payments%rowtype; ps public.platform_settings%rowtype; pr public.properties%rowtype; pl public.plans%rowtype;
  v_owner record; v_existing public.platform_invoices%rowtype; v_fy text; v_no int; v_num text; v_doc jsonb;
  v_gst boolean; v_inter boolean; v_rate numeric; v_taxable bigint; v_tax bigint; v_buyer_state text; v_day date;
begin
  select * into v_existing from public.platform_invoices where payment_id = p_payment;
  if found then return v_existing.doc; end if;
  select * into sp from public.subscription_payments where id = p_payment;
  if not found or sp.status <> 'approved' then return null; end if;
  select * into ps from public.platform_settings where id = 1;
  select * into pr from public.properties where id = sp.property_id;
  select * into pl from public.plans where id = sp.plan_id;
  select m.display_name, m.email into v_owner from public.property_members m where m.property_id = pr.id and m.role = 'owner' order by m.created_at limit 1;

  v_gst := ps.gstin is not null;
  v_rate := case when v_gst then ps.gst_rate else 0 end;
  v_taxable := round(sp.amount_paise * 100.0 / (100 + v_rate));
  v_tax := sp.amount_paise - v_taxable;
  v_buyer_state := coalesce(left(pr.bill_gstin, 2), pr.bill_state);
  v_inter := v_buyer_state is not null and v_buyer_state <> ps.state_code;

  v_day := (coalesce(sp.reviewed_at, now()) at time zone 'Asia/Kolkata')::date;
  v_fy := case when extract(month from v_day) >= 4 then extract(year from v_day)::int else extract(year from v_day)::int - 1 end::text;
  v_fy := v_fy || '-' || right(((v_fy::int) + 1)::text, 2);
  insert into public.platform_invoice_counters (fy, last_no) values (v_fy, 1)
  on conflict (fy) do update set last_no = public.platform_invoice_counters.last_no + 1 returning last_no into v_no;
  v_num := ps.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 4, '0');

  v_doc := jsonb_build_object(
    'number', v_num, 'issued_at', coalesce(sp.reviewed_at, now()), 'fy', v_fy, 'subscription', true,
    'title', case when v_gst then 'Tax invoice' else 'Invoice' end, 'gst', v_gst, 'inter_state', v_gst and v_inter,
    'seller', jsonb_build_object('name', 'NammaStay', 'legal_name', coalesce(ps.legal_name, ps.payee_name, 'NammaStay'), 'gstin', ps.gstin,
                                 'address', ps.address, 'phone', ps.support_whatsapp, 'email', ps.support_email),
    'buyer', jsonb_build_object('name', coalesce(pr.bill_name, pr.name), 'company', case when pr.bill_name is not null and pr.bill_name <> pr.name then pr.name end,
                                'gstin', pr.bill_gstin, 'address', coalesce(pr.bill_address, concat_ws(', ', pr.address, pr.city)),
                                'phone', pr.phone, 'email', v_owner.email),
    'period', jsonb_build_object('plan', pl.name, 'kind', pl.kind, 'from', sp.period_start, 'to', sp.period_end, 'property', pr.name),
    'lines', jsonb_build_array(jsonb_build_object(
       'desc', format('NammaStay subscription — %s plan (%s → %s) · %s', pl.name,
                      to_char(sp.period_start at time zone 'Asia/Kolkata', 'DD Mon YYYY'), to_char(sp.period_end at time zone 'Asia/Kolkata', 'DD Mon YYYY'), pr.name),
       'sac', ps.sac, 'qty', 1, 'rate_paise', sp.amount_paise, 'amount_paise', sp.amount_paise, 'gst_rate', v_rate,
       'taxable_paise', v_taxable, 'tax_paise', v_tax)),
    'amount_paise', sp.amount_paise, 'taxable_paise', v_taxable,
    'cgst_paise', case when v_gst and not v_inter then v_tax / 2 else 0 end,
    'sgst_paise', case when v_gst and not v_inter then v_tax - v_tax / 2 else 0 end,
    'igst_paise', case when v_gst and v_inter then v_tax else 0 end,
    'paid_paise', sp.amount_paise, 'balance_paise', 0,
    'payments', jsonb_build_array(jsonb_build_object('code', 'UPI', 'kind', 'payment', 'method', 'upi', 'amount_paise', sp.amount_paise,
                                                     'received_at', sp.submitted_at, 'reference', sp.utr)));
  insert into public.platform_invoices (property_id, payment_id, number, fy, issued_at, total_paise, doc)
  values (pr.id, sp.id, v_num, v_fy, coalesce(sp.reviewed_at, now()), sp.amount_paise, v_doc);
  insert into public.notifications (property_id, kind, title, body)
  values (pr.id, 'subscription', 'Invoice ' || v_num || ' is ready', 'Settings → Billing → Your invoices');
  return v_doc;
end $$;

--
-- Name: plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plans (
    id text NOT NULL,
    name text NOT NULL,
    period_months integer NOT NULL,
    price_paise integer NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    sort integer DEFAULT 0 NOT NULL,
    kind text,
    min_units integer,
    max_units integer,
    is_quote boolean DEFAULT false NOT NULL,
    CONSTRAINT plans_id_check CHECK ((id ~ '^[a-z0-9_]{2,30}$'::text)),
    CONSTRAINT plans_kind_check CHECK (((kind IS NULL) OR (kind = ANY (ARRAY['hostel'::text, 'hotel'::text, 'homestay'::text])))),
    CONSTRAINT plans_max_units_check CHECK (((max_units IS NULL) OR (max_units >= 1))),
    CONSTRAINT plans_min_units_check CHECK (((min_units IS NULL) OR (min_units >= 0))),
    CONSTRAINT plans_period_months_check CHECK (((period_months >= 1) AND (period_months <= 36))),
    CONSTRAINT plans_price_paise_check CHECK (((price_paise >= 0) AND (price_paise <= 100000000)))
);

--
-- Name: _plans_for(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._plans_for(p_property uuid) RETURNS SETOF public.plans
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  with k as (
    select coalesce(p.kind, 'hostel') as kind,
           (select count(*) from public.beds b where b.property_id = p.id and b.is_active)::int as n
      from public.properties p where p.id = p_property),
  exact as (
    select pl.* from public.plans pl, k
     where pl.is_active and (pl.kind is null or pl.kind = k.kind)
       and (pl.min_units is null or k.n >= pl.min_units) and (pl.max_units is null or k.n <= pl.max_units))
  select * from exact
  union all
  select pl.* from public.plans pl, k                       -- e.g. a homestay that outgrew 6 rooms → hotel prices
   where not exists (select 1 from exact) and pl.is_active and pl.kind = 'hotel'
     and (pl.min_units is null or k.n >= pl.min_units) and (pl.max_units is null or k.n <= pl.max_units)
$$;

--
-- Name: _reminder_text(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._reminder_text(p_kind text, p_ends timestamp with time zone) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object(
    'title', case p_kind when 'trial_3d' then 'Your free trial ends in 3 days' when 'trial_1d' then 'Your free trial ends tomorrow'
             when 'trial_ended' then 'Your free trial has ended' when 'renew_7d' then 'Your NammaStay plan renews in 7 days'
             when 'renew_1d' then 'Your NammaStay plan ends tomorrow' else 'Your NammaStay plan has ended' end,
    'body', case when p_kind in ('trial_ended','expired') then 'Choose a plan in Settings → Billing to keep using NammaStay.'
             else 'Ends ' || to_char(p_ends at time zone 'Asia/Kolkata', 'DD Mon YYYY') || ' — Settings → Billing to choose a plan.' end)
$$;

--
-- Name: admin_actions_list(integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_actions_list(p_limit integer DEFAULT 200, p_property uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'at', a.at, 'admin_email', a.admin_email, 'action', a.action,
            'property_id', a.property_id, 'property', p.name, 'details', a.details) order by a.at desc), '[]'::jsonb)
          from (select * from public.admin_actions where p_property is null or property_id = p_property order by at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) a
          left join public.properties p on p.id = a.property_id);
end $$;

--
-- Name: admin_backfill_invoices(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_backfill_invoices() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare r record; n int := 0;
begin
  perform public._assert_platform_admin();
  for r in select sp.id from public.subscription_payments sp left join public.platform_invoices i on i.payment_id = sp.id
            where sp.status = 'approved' and i.id is null order by sp.reviewed_at loop
    perform public._issue_platform_invoice(r.id); n := n + 1;
  end loop;
  return n;
end $$;

--
-- Name: admin_coupons(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_coupons() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb) from public.coupons c);
end $$;

--
-- Name: admin_create_property(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_create_property(p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare
  v_email text := lower(btrim(coalesce(p->>'owner_email', '')));
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_owner uuid;
  v_prop  uuid;
  v_days  int := nullif(p->>'trial_days', '')::int;
begin
  perform public._assert_platform_admin();
  if char_length(v_name) < 2 then raise exception 'Enter the property name.'; end if;
  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the owner’s email address.'; end if;
  if v_days is not null and (v_days < 0 or v_days > 365) then raise exception 'Trial days must be between 0 and 365.'; end if;

  insert into public.properties (name, kind, city, address, phone, email)
  values (left(v_name, 120), coalesce(nullif(p->>'kind', ''), 'hostel'),
          left(nullif(btrim(p->>'city'), ''), 80), left(nullif(btrim(p->>'address'), ''), 300),
          left(nullif(btrim(p->>'phone'), ''), 20), v_email)
  returning id into v_prop;                                   -- trigger starts the standard free trial

  update public.subscriptions set
    trial_ends_at    = case when v_days is not null then now() + make_interval(days => v_days) else trial_ends_at end,
    is_complimentary = coalesce((p->>'complimentary')::boolean, false),
    admin_note       = nullif(left(btrim(coalesce(p->>'admin_note', '')), 4000), '')
  where property_id = v_prop;

  -- optional: you as manager, to set up rooms and beds for them
  if coalesce((p->>'add_me')::boolean, false) then
    insert into public.property_members (property_id, user_id, role, display_name, email)
    select v_prop, auth.uid(), 'manager', 'NammaStay support', u.email from auth.users u where u.id = auth.uid()
    on conflict do nothing;
  end if;

  -- owner: link now if they already have a login, otherwise when they sign up
  select id into v_owner from auth.users where lower(email) = v_email;
  insert into public.property_invites (property_id, email, role, display_name, claimed_by, claimed_at)
  values (v_prop, v_email, 'owner', nullif(left(btrim(coalesce(p->>'owner_name', '')), 80), ''),
          v_owner, case when v_owner is not null then now() end);
  if v_owner is not null then
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (v_prop, v_owner, 'owner', nullif(left(btrim(coalesce(p->>'owner_name', '')), 80), ''), v_email)
    on conflict (property_id, user_id) do update set role = 'owner';
  end if;

  return jsonb_build_object('property_id', v_prop, 'owner_linked', v_owner is not null,
    'trial_ends_at', (select trial_ends_at from public.subscriptions where property_id = v_prop));
end $_$;

--
-- Name: admin_health(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_health() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(x order by (x->>'score')::int, x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object(
      'property_id', p.id, 'name', p.name, 'city', p.city, 'kind', p.kind, 'created_at', p.created_at, 'state', public._access_state(p.id),
      'trial_ends_at', s.trial_ends_at, 'paid_until', s.paid_until, 'last_seen_at', u.last_seen_at,
      'steps', jsonb_build_object('rooms', u.beds > 0, 'upi', p.upi_id is not null, 'staff', u.staff > 1, 'first_booking', u.bookings > 0,
                                  'first_payment', u.payments > 0, 'regular_use', u.bookings_14 >= 3),
      'bookings_14', u.bookings_14, 'active_days_7', u.active_days_7,
      'score', least(100, round(
          8 * ((u.beds > 0)::int + (p.upi_id is not null)::int + (u.staff > 1)::int + (u.bookings > 0)::int + (u.payments > 0)::int)
        + 3 * least(u.bookings_14, 10) + 6 * least(u.active_days_7, 5)))::int) x
      from public.properties p
      join public.subscriptions s on s.property_id = p.id
      cross join lateral (select
        (select count(*) from public.beds b where b.property_id = p.id and b.is_active) beds,
        (select count(*) from public.property_members m where m.property_id = p.id) staff,
        (select count(*) from public.bookings b where b.property_id = p.id) bookings,
        (select count(*) from public.payments y where y.property_id = p.id) payments,
        (select count(*) from public.bookings b where b.property_id = p.id and b.created_at > now() - interval '14 days') bookings_14,
        (select count(distinct d) from (select (b.created_at at time zone 'Asia/Kolkata')::date d from public.bookings b where b.property_id = p.id and b.created_at > now() - interval '7 days'
                                         union select (y.received_at at time zone 'Asia/Kolkata')::date from public.payments y where y.property_id = p.id and y.received_at > now() - interval '7 days') z) active_days_7,
        (select max(m.last_seen_at) from public.property_members m where m.property_id = p.id) last_seen_at) u) q);
end $$;

--
-- Name: admin_invoice_settings(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_invoice_settings() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  return (select jsonb_build_object('legal_name', legal_name, 'gstin', gstin, 'address', address, 'state_code', state_code,
            'sac', sac, 'gst_rate', gst_rate, 'invoice_prefix', invoice_prefix, 'payee_name', payee_name,
            'support_email', support_email, 'support_whatsapp', support_whatsapp)
          from public.platform_settings where id = 1);
end $$;

--
-- Name: admin_lead_converted(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_lead_converted(p_lead uuid, p_property uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  update public.leads set property_id = p_property, status = 'won' where id = p_lead;
end $$;

--
-- Name: admin_mark_reminder(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_mark_reminder(p_id uuid, p_done boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  update public.billing_reminders set whatsapp_done_at = case when p_done then now() end where id = p_id;
end $$;

--
-- Name: admin_mfa_info(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_mfa_info() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object(
    'admin', exists (select 1 from public.platform_admins where user_id = auth.uid()),
    'has_factor', exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'),
    'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'))
$$;

--
-- Name: admin_overview(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_overview() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v jsonb;
begin
  perform public._assert_platform_admin();
  with st as (
    select p.id, p.name, p.city, p.created_at, s.trial_ends_at, s.paid_until, s.plan_id, s.is_complimentary,
           public._access_state(p.id) as state,
           (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1) as owner_email,
           (select max(b.created_at) from public.bookings b where b.property_id = p.id) as last_booking_at,
           (select max(m.last_seen_at) from public.property_members m where m.property_id = p.id) as last_seen_at
      from public.properties p join public.subscriptions s on s.property_id = p.id)
  select jsonb_build_object(
    'total', (select count(*) from st),
    'counts', (select coalesce(jsonb_object_agg(state, n), '{}'::jsonb) from (select state, count(*) n from st group by state) c),
    'mrr_paise', (select coalesce(round(sum(pl.price_paise::numeric / pl.period_months)), 0)
                    from st join public.plans pl on pl.id = st.plan_id where st.state = 'active'),
    'signups_30d', (select count(*) from st where created_at > now() - interval '30 days'),
    'bookings_30d', (select count(*) from public.bookings where created_at > now() - interval '30 days'),
    'guest_payments_30d_paise', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                                   from public.payments where received_at > now() - interval '30 days'),
    'pending_payments', (select count(*) from public.subscription_payments where status = 'pending'),
    'weekly_signups', (select coalesce(jsonb_agg(jsonb_build_object('week', w::date,
                          'n', (select count(*) from st where created_at >= w and created_at < w + interval '7 days')) order by w), '[]'::jsonb)
                         from generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '1 week') w),
    'trial_ending', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'ends_at', trial_ends_at) order by trial_ends_at), '[]'::jsonb)
                       from st where state = 'trial' and trial_ends_at < now() + interval '3 days'),
    'payment_due', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'ended_at', greatest(trial_ends_at, coalesce(paid_until, trial_ends_at))) order by paid_until), '[]'::jsonb)
                      from st where state = 'grace'),
    'inactive', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'last_booking_at', last_booking_at, 'last_seen_at', last_seen_at) order by coalesce(last_seen_at, created_at)), '[]'::jsonb)
                   from st where state in ('trial','active') and created_at < now() - interval '7 days'
                     and coalesce(last_booking_at, created_at) < now() - interval '14 days'),
    'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'state', state, 'created_at', created_at, 'trial_ends_at', trial_ends_at, 'paid_until', paid_until, 'plan_id', plan_id,
                        'beds', (select count(*) from public.beds b where b.property_id = st.id and b.is_active),
                        'bookings_30d', (select count(*) from public.bookings b where b.property_id = st.id and b.created_at > now() - interval '30 days'),
                        'last_seen_at', last_seen_at) order by created_at desc), '[]'::jsonb) from st)
  ) into v;
  return v;
end $$;

--
-- Name: admin_platform_invoices(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_platform_invoices(p_property uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('number', i.number, 'issued_at', i.issued_at, 'total_paise', i.total_paise,
            'payment_id', i.payment_id, 'property', p.name, 'property_id', p.id, 'doc', i.doc) order by i.issued_at desc), '[]'::jsonb)
          from (select * from public.platform_invoices where p_property is null or property_id = p_property order by issued_at desc limit 300) i
          join public.properties p on p.id = i.property_id);
end $$;

--
-- Name: admin_property(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_property(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  if not exists (select 1 from public.properties where id = p_property) then raise exception 'Property not found.'; end if;
  return (select jsonb_build_object(
    'property', jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'address', p.address, 'city', p.city,
                                   'phone', p.phone, 'email', p.email, 'upi_id', p.upi_id, 'created_at', p.created_at),
    'subscription', to_jsonb(s) || jsonb_build_object('state', public._access_state(p.id)),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('name', m.display_name, 'email', m.email, 'role', m.role,
                  'last_seen_at', m.last_seen_at) order by m.role, m.created_at), '[]'::jsonb)
                from public.property_members m where m.property_id = p.id),
    'usage', jsonb_build_object(
       'rooms', (select count(*) from public.rooms where property_id = p.id),
       'beds', (select count(*) from public.beds where property_id = p.id and is_active),
       'guests', (select count(*) from public.guests where property_id = p.id),
       'bookings_total', (select count(*) from public.bookings where property_id = p.id),
       'bookings_30d', (select count(*) from public.bookings where property_id = p.id and created_at > now() - interval '30 days'),
       'guest_payments_30d_paise', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                                     from public.payments where property_id = p.id and received_at > now() - interval '30 days'),
       'last_booking_at', (select max(created_at) from public.bookings where property_id = p.id),
       'last_seen_at', (select max(last_seen_at) from public.property_members where property_id = p.id)),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', sp.id, 'plan_id', sp.plan_id, 'amount_paise', sp.amount_paise, 'utr', sp.utr,
                  'status', sp.status, 'submitted_at', sp.submitted_at, 'review_note', sp.review_note,
                  'period_start', sp.period_start, 'period_end', sp.period_end) order by sp.submitted_at desc), '[]'::jsonb)
                 from public.subscription_payments sp where sp.property_id = p.id))
    from public.properties p join public.subscriptions s on s.property_id = p.id where p.id = p_property);
end $$;

--
-- Name: admin_property_invites(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_property_invites(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('email', email, 'role', role, 'name', display_name,
            'created_at', created_at, 'claimed_at', claimed_at) order by created_at), '[]'::jsonb)
            from public.property_invites where property_id = p_property);
end $$;

--
-- Name: admin_reminders(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_reminders(p_all boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', b.id, 'kind', b.kind, 'ends_at', b.ends_at, 'created_at', b.created_at, 'emailed_at', b.emailed_at,
             'whatsapp_done_at', b.whatsapp_done_at, 'property_id', p.id, 'property', p.name, 'city', p.city, 'phone', p.phone,
             'owner', (select coalesce(m.display_name, m.email) from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
             'email', (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
             'text', public._reminder_text(b.kind, b.ends_at)) x
      from public.billing_reminders b join public.properties p on p.id = b.property_id
     where p_all or (b.whatsapp_done_at is null and b.created_at > now() - interval '10 days')
     order by b.created_at desc limit 200) q);
end $$;

--
-- Name: admin_revenue(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_revenue() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_mrr bigint;
begin
  perform public._assert_platform_admin();
  with latest as (
    select distinct on (sp.property_id) sp.property_id, sp.amount_paise, pl.period_months, pl.kind, pl.name as plan_name
      from public.subscription_payments sp join public.plans pl on pl.id = sp.plan_id
      join public.subscriptions s on s.property_id = sp.property_id
     where sp.status = 'approved' and s.paid_until > now() and not s.is_complimentary and not coalesce(s.is_suspended, false)
     order by sp.property_id, sp.reviewed_at desc)
  select coalesce(sum(amount_paise::numeric / greatest(period_months, 1)), 0)::bigint into v_mrr from latest;
  return jsonb_build_object(
    'mrr_paise', v_mrr, 'arr_paise', v_mrr * 12,
    'paying', (select count(*) from public.subscriptions s where s.paid_until > now() and not s.is_complimentary and not coalesce(s.is_suspended, false)),
    'trials', (select count(*) from public.subscriptions s where s.trial_ends_at > now() and (s.paid_until is null or s.paid_until < now()) and not s.is_complimentary),
    'complimentary', (select count(*) from public.subscriptions s where s.is_complimentary),
    'churned_30', (select count(*) from public.subscriptions s where s.paid_until between now() - interval '30 days' and now() and not s.is_complimentary),
    'collected_this_month', (select coalesce(sum(amount_paise), 0) from public.subscription_payments
                              where status = 'approved' and date_trunc('month', reviewed_at at time zone 'Asia/Kolkata') = date_trunc('month', now() at time zone 'Asia/Kolkata')),
    'months', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'),
                 'collected_paise', (select coalesce(sum(amount_paise), 0) from public.subscription_payments sp
                                      where sp.status = 'approved' and date_trunc('month', sp.reviewed_at at time zone 'Asia/Kolkata') = m)) order by m), '[]'::jsonb)
               from generate_series(date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '11 months', date_trunc('month', now() at time zone 'Asia/Kolkata'), interval '1 month') m),
    'mix', (select coalesce(jsonb_agg(jsonb_build_object('plan', plan_name, 'kind', kind, 'yearly', period_months >= 12, 'count', n) order by n desc), '[]'::jsonb) from (
              select pl.name plan_name, pl.kind, pl.period_months, count(*) n
                from (select distinct on (sp.property_id) sp.property_id, sp.plan_id from public.subscription_payments sp
                       join public.subscriptions s on s.property_id = sp.property_id
                      where sp.status = 'approved' and s.paid_until > now() order by sp.property_id, sp.reviewed_at desc) l
                join public.plans pl on pl.id = l.plan_id group by pl.name, pl.kind, pl.period_months) z),
    'conversion_90', (select jsonb_build_object('trials', count(*), 'paid', count(*) filter (where exists (select 1 from public.subscription_payments sp where sp.property_id = s.property_id and sp.status = 'approved')))
                        from public.subscriptions s join public.properties p on p.id = s.property_id where p.created_at > now() - interval '90 days' and not s.is_complimentary));
end $$;

--
-- Name: admin_review_subscription_payment(uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_review_subscription_payment(p_id uuid, p_approve boolean, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare sp public.subscription_payments%rowtype; s public.subscriptions%rowtype; v_plan public.plans%rowtype; v_start timestamptz; v_end timestamptz;
begin
  perform public._assert_platform_admin();
  select * into sp from public.subscription_payments where id = p_id for update;
  if not found then raise exception 'Payment not found.'; end if;
  if sp.status <> 'pending' then raise exception 'This payment was already reviewed.'; end if;

  if not p_approve then
    update public.subscription_payments set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
           review_note = nullif(btrim(p_note), '') where id = p_id;
    return jsonb_build_object('status', 'rejected');
  end if;

  select * into s from public.subscriptions where property_id = sp.property_id for update;
  select * into v_plan from public.plans where id = sp.plan_id;
  -- Paying during the trial doesn't lose trial days; renewing early doesn't lose paid days.
  v_start := greatest(now(), coalesce(s.paid_until, now()), s.trial_ends_at);
  v_end := v_start + make_interval(months => v_plan.period_months);
  update public.subscriptions set paid_until = v_end, plan_id = v_plan.id where property_id = sp.property_id;
  update public.subscription_payments set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = nullif(btrim(p_note), ''), period_start = v_start, period_end = v_end where id = p_id;
  insert into public.notifications (property_id, kind, title, body)
  values (sp.property_id, 'subscription', 'Subscription payment confirmed',
          'Paid until ' || to_char(v_end at time zone 'Asia/Kolkata', 'DD Mon YYYY'));
  return jsonb_build_object('status', 'approved', 'paid_until', v_end);
end $$;

--
-- Name: admin_save_billing_settings(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_save_billing_settings(p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare pl jsonb;
begin
  perform public._assert_platform_admin();
  update public.platform_settings set
    upi_id = coalesce(nullif(btrim(p->>'upi_id'), ''), upi_id),
    payee_name = coalesce(nullif(btrim(p->>'payee_name'), ''), payee_name),
    trial_days = coalesce(nullif(p->>'trial_days', '')::int, trial_days),
    grace_days = coalesce(nullif(p->>'grace_days', '')::int, grace_days),
    support_whatsapp = case when p ? 'support_whatsapp' then nullif(btrim(p->>'support_whatsapp'), '') else support_whatsapp end,
    support_email = case when p ? 'support_email' then nullif(btrim(p->>'support_email'), '') else support_email end,
    updated_at = now()
  where id = 1;
  for pl in select * from jsonb_array_elements(coalesce(p->'plans', '[]'::jsonb)) loop
    update public.plans set
      price_paise = coalesce(nullif(pl->>'price_paise', '')::int, price_paise),
      name = coalesce(nullif(btrim(pl->>'name'), ''), name),
      description = case when pl ? 'description' then nullif(btrim(pl->>'description'), '') else description end,
      is_active = coalesce((pl->>'is_active')::boolean, is_active),
      min_units = case when pl ? 'min_units' then nullif(pl->>'min_units', '')::int else min_units end,
      max_units = case when pl ? 'max_units' then nullif(pl->>'max_units', '')::int else max_units end
    where id = pl->>'id';
  end loop;
end $$;

--
-- Name: admin_save_coupon(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_save_coupon(p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_code text := upper(btrim(coalesce(p->>'code', ''))); v_kind text := coalesce(p->>'kind', 'percent'); v_val numeric := nullif(p->>'value', '')::numeric;
begin
  perform public._assert_platform_admin();
  if v_code !~ '^[A-Z0-9-]{3,20}$' then raise exception 'Code: 3–20 letters, numbers or dashes (e.g. LAUNCH20).'; end if;
  if v_val is null or v_val <= 0 then raise exception 'Enter the discount.'; end if;
  if v_kind = 'percent' and v_val > 90 then raise exception 'Percent discounts go up to 90%%.'; end if;
  insert into public.coupons (code, kind, value, plan_ids, max_uses, expires_at, note, is_active)
  values (v_code, v_kind, case when v_kind = 'flat' then round(v_val * 100) else round(v_val) end,
          case when jsonb_typeof(p->'plan_ids') = 'array' and jsonb_array_length(p->'plan_ids') > 0 then array(select jsonb_array_elements_text(p->'plan_ids')) end,
          nullif(p->>'max_uses', '')::int, nullif(p->>'expires_at', '')::timestamptz, nullif(btrim(coalesce(p->>'note', '')), ''), coalesce((p->>'is_active')::boolean, true))
  on conflict (code) do update set kind = excluded.kind, value = excluded.value, plan_ids = excluded.plan_ids, max_uses = excluded.max_uses,
     expires_at = excluded.expires_at, note = excluded.note, is_active = excluded.is_active;
end $_$;

--
-- Name: admin_save_invoice_settings(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_save_invoice_settings(p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_gstin text := nullif(upper(btrim(coalesce(p->>'gstin', ''))), '');
begin
  perform public._assert_platform_admin();
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then raise exception 'Check the GSTIN — 15 characters.'; end if;
  update public.platform_settings set
    legal_name = nullif(left(btrim(coalesce(p->>'legal_name', '')), 120), ''),
    gstin = v_gstin,
    address = nullif(left(btrim(coalesce(p->>'address', '')), 300), ''),
    state_code = coalesce(left(v_gstin, 2), nullif(p->>'state_code', ''), state_code),
    sac = coalesce(nullif(btrim(coalesce(p->>'sac', '')), ''), sac),
    gst_rate = coalesce(nullif(p->>'gst_rate', '')::numeric, gst_rate),
    invoice_prefix = coalesce(nullif(upper(btrim(coalesce(p->>'invoice_prefix', ''))), ''), invoice_prefix),
    updated_at = now()
  where id = 1;
end $_$;

--
-- Name: admin_set_property(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_property(p_property uuid, p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_days int := nullif(p->>'extend_days', '')::int;
begin
  perform public._assert_platform_admin();
  if v_days is not null and (v_days < -3650 or v_days > 3650) then raise exception 'Enter a sensible number of days.'; end if;
  if coalesce((p->>'suspend')::boolean, false) and coalesce(btrim(p->>'suspend_reason'), '') = '' then
    raise exception 'Add a short reason for suspending (the owner sees it).';
  end if;
  update public.subscriptions set
    paid_until = case when v_days is null or v_days = 0 then paid_until
                      else greatest(now(), coalesce(paid_until, now()), trial_ends_at) + make_interval(days => v_days) end,
    is_complimentary = coalesce((p->>'complimentary')::boolean, is_complimentary),
    is_suspended = coalesce((p->>'suspend')::boolean, is_suspended),
    suspended_reason = case when p ? 'suspend' then case when (p->>'suspend')::boolean then left(btrim(p->>'suspend_reason'), 300) end else suspended_reason end,
    suspended_at = case when p ? 'suspend' then case when (p->>'suspend')::boolean then coalesce(suspended_at, now()) end else suspended_at end,
    admin_note = case when p ? 'admin_note' then nullif(left(btrim(p->>'admin_note'), 4000), '') else admin_note end
  where property_id = p_property;
  if not found then raise exception 'Property not found.'; end if;
  if p ? 'suspend' then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'subscription',
            case when (p->>'suspend')::boolean then 'Account suspended' else 'Account reactivated' end,
            case when (p->>'suspend')::boolean then left(btrim(p->>'suspend_reason'), 300) else 'You can take new bookings again.' end);
  end if;
end $$;

--
-- Name: admin_subscriptions(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_subscriptions(p_q text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_q text := nullif(btrim(p_q), '');
begin
  perform public._assert_platform_admin();
  return jsonb_build_object(
    'settings', (select to_jsonb(s) from public.platform_settings s where id = 1),
    'plans', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort), '[]'::jsonb) from public.plans x),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('id', sp.id, 'property_id', sp.property_id, 'property', p.name,
                  'plan_id', sp.plan_id, 'amount_paise', sp.amount_paise, 'utr', sp.utr, 'submitted_at', sp.submitted_at, 'coupon_code', sp.coupon_code,
                  'owner_email', (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1))
                  order by sp.submitted_at), '[]'::jsonb)
                from public.subscription_payments sp join public.properties p on p.id = sp.property_id
               where sp.status = 'pending'),
    'properties', (select coalesce(jsonb_agg(r order by r->>'created_at' desc), '[]'::jsonb) from (
                select jsonb_build_object('property_id', p.id, 'name', p.name, 'city', p.city, 'created_at', p.created_at,
                  'owner_email', (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
                  'owner_name', (select m.display_name from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
                  'beds', (select count(*) from public.beds b where b.property_id = p.id and b.is_active),
                  'state', public._access_state(p.id), 'plan_id', s.plan_id, 'trial_ends_at', s.trial_ends_at,
                  'paid_until', s.paid_until, 'is_complimentary', s.is_complimentary,
                  'last_booking_at', (select max(b.created_at) from public.bookings b where b.property_id = p.id)) r
                  from public.properties p join public.subscriptions s on s.property_id = p.id
                 where v_q is null or p.name ilike '%' || v_q || '%' or p.city ilike '%' || v_q || '%'
                    or exists (select 1 from public.property_members m where m.property_id = p.id and m.email ilike '%' || v_q || '%')
                 limit 500) q));
end $$;

--
-- Name: admin_update_subscription(uuid, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_update_subscription(p_property uuid, p_extend_days integer DEFAULT NULL::integer, p_complimentary boolean DEFAULT NULL::boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  if p_extend_days is not null and (p_extend_days < -3650 or p_extend_days > 3650) then raise exception 'Enter a sensible number of days.'; end if;
  update public.subscriptions
     set paid_until = case when p_extend_days is null then paid_until
                           else greatest(now(), coalesce(paid_until, now()), trial_ends_at) + make_interval(days => p_extend_days) end,
         is_complimentary = coalesce(p_complimentary, is_complimentary)
   where property_id = p_property;
  if not found then raise exception 'Property not found.'; end if;
end $$;

--
-- Name: billing_info(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.billing_info(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return jsonb_build_object(
    'access', public.property_access(p_property),
    'plans', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort), '[]'::jsonb) from public._plans_for(p_property) x),
    'kind', (select kind from public.properties where id = p_property),
    'units', (select count(*) from public.beds where property_id = p_property and is_active),
    'pay_to', (select jsonb_build_object('upi_id', upi_id, 'payee_name', payee_name,
                      'support_whatsapp', support_whatsapp, 'support_email', support_email)
                 from public.platform_settings where id = 1),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'plan_id', plan_id, 'amount_paise', amount_paise, 'utr', utr,
                      'status', status, 'submitted_at', submitted_at, 'review_note', review_note,
                      'period_start', period_start, 'period_end', period_end) order by submitted_at desc), '[]'::jsonb)
                  from (select * from public.subscription_payments where property_id = p_property
                        order by submitted_at desc limit 24) h));
end $$;

--
-- Name: check_coupon(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_coupon(p_property uuid, p_plan text, p_code text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if not exists (select 1 from public._plans_for(p_property) x where x.id = p_plan) then raise exception 'Choose a plan for your property.'; end if;
  return public._coupon_quote(p_plan, p_code);
end $$;

--
-- Name: lead_counts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lead_counts() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v jsonb;
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status, count(*) n from public.leads group by status) s;
  return v || jsonb_build_object('all', (select count(*) from public.leads),
                                 'last_7_days', (select count(*) from public.leads where created_at > now() - interval '7 days'));
end $$;

--
-- Name: leads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    phone text,
    email text,
    property_name text,
    city text,
    property_type text,
    beds integer,
    message text,
    source text,
    status public.lead_status DEFAULT 'new'::public.lead_status NOT NULL,
    notes text,
    contacted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    property_id uuid,
    CONSTRAINT leads_beds_check CHECK (((beds IS NULL) OR ((beds >= 1) AND (beds <= 5000)))),
    CONSTRAINT leads_check CHECK (((phone IS NOT NULL) OR (email IS NOT NULL))),
    CONSTRAINT leads_city_check CHECK ((char_length(city) <= 80)),
    CONSTRAINT leads_email_check CHECK (((email IS NULL) OR (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text))),
    CONSTRAINT leads_message_check CHECK ((char_length(message) <= 1000)),
    CONSTRAINT leads_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 80))),
    CONSTRAINT leads_notes_check CHECK ((char_length(notes) <= 2000)),
    CONSTRAINT leads_phone_check CHECK (((phone IS NULL) OR (phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT leads_property_name_check CHECK ((char_length(property_name) <= 120)),
    CONSTRAINT leads_property_type_check CHECK (((property_type IS NULL) OR (property_type = ANY (ARRAY['hostel'::text, 'homestay'::text, 'hotel'::text, 'other'::text])))),
    CONSTRAINT leads_source_check CHECK ((char_length(source) <= 300))
);

--
-- Name: list_leads(text, text, timestamp with time zone, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_leads(p_status text DEFAULT NULL::text, p_q text DEFAULT NULL::text, p_cursor_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50) RETURNS SETOF public.leads
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_q text := nullif(btrim(p_q), ''); v_d text;
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  v_d := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  return query
  select * from public.leads l
   where (p_status is null or l.status = p_status::public.lead_status)
     and (v_q is null or l.name ilike '%' || v_q || '%' or l.email ilike '%' || v_q || '%'
          or l.property_name ilike '%' || v_q || '%' or l.city ilike '%' || v_q || '%'
          or (length(v_d) >= 4 and l.phone like '%' || v_d || '%'))
     and (p_cursor_at is null or (l.created_at, l.id) < (p_cursor_at, p_cursor_id))
   order by l.created_at desc, l.id desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;

--
-- Name: mark_reminders_emailed(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_reminders_emailed(p_ids uuid[]) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  update public.billing_reminders set emailed_at = now() where id = any (p_ids)
$$;

--
-- Name: my_billing_details(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_billing_details(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select jsonb_build_object('bill_name', bill_name, 'bill_gstin', bill_gstin, 'bill_address', bill_address, 'bill_state', bill_state, 'name', name)
            from public.properties where id = p_property);
end $$;

--
-- Name: my_platform_invoices(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_platform_invoices(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object('number', number, 'issued_at', issued_at, 'total_paise', total_paise, 'doc', doc)
            order by issued_at desc), '[]'::jsonb) from public.platform_invoices where property_id = p_property);
end $$;

--
-- Name: property_access(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.property_access(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare s public.subscriptions%rowtype; v_state text; v_end timestamptz;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select * into s from public.subscriptions where property_id = p_property;
  v_state := public._access_state(p_property);
  v_end := case v_state when 'trial' then s.trial_ends_at
                        when 'active' then s.paid_until
                        else greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at)) end;
  return jsonb_build_object(
    'state', v_state, 'plan_id', s.plan_id, 'trial_ends_at', s.trial_ends_at, 'paid_until', s.paid_until,
    'ends_at', v_end,
    'days_left', case when v_state in ('trial','active') then greatest(0, ceil(extract(epoch from (v_end - now())) / 86400))::int end,
    'grace_days', (select grace_days from public.platform_settings where id = 1),
    'pending_payment', exists (select 1 from public.subscription_payments where property_id = p_property and status = 'pending'));
end $$;

--
-- Name: property_suspension(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.property_suspension(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return (select jsonb_build_object('suspended', is_suspended, 'reason', suspended_reason, 'since', suspended_at)
            from public.subscriptions where property_id = p_property);
end $$;

--
-- Name: reminders_to_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reminders_to_email() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'kind', b.kind, 'ends_at', b.ends_at, 'property', p.name,
           'email', m.email, 'name', coalesce(m.display_name, 'there'), 'text', public._reminder_text(b.kind, b.ends_at))), '[]'::jsonb)
    from public.billing_reminders b join public.properties p on p.id = b.property_id
    join lateral (select email, display_name from public.property_members where property_id = p.id and role = 'owner' and email is not null order by created_at limit 1) m on true
   where b.emailed_at is null and b.created_at > now() - interval '3 days'
$$;

--
-- Name: run_billing_reminders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.run_billing_reminders() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare r record; v_kind text; v_days int; v_id uuid; n int := 0; v_txt jsonb;
begin
  if auth.uid() is not null then perform public._assert_platform_admin(); end if;      -- cron (no user) or an admin
  for r in
    select s.property_id, s.trial_ends_at, s.paid_until,
           (s.paid_until is not null and s.paid_until >= s.trial_ends_at) as paid,
           greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at)) as ends_at
      from public.subscriptions s
     where not s.is_complimentary and not coalesce(s.is_suspended, false)
  loop
    v_days := (r.ends_at at time zone 'Asia/Kolkata')::date - (now() at time zone 'Asia/Kolkata')::date;
    v_kind := case
      when not r.paid and v_days between 2 and 3 then 'trial_3d'
      when not r.paid and v_days between 0 and 1 and r.ends_at > now() then 'trial_1d'
      when not r.paid and r.ends_at <= now() and v_days >= -6 then 'trial_ended'
      when r.paid and v_days between 4 and 7 then 'renew_7d'
      when r.paid and v_days between 0 and 1 and r.ends_at > now() then 'renew_1d'
      when r.paid and r.ends_at <= now() and v_days >= -6 then 'expired'
    end;
    continue when v_kind is null;
    insert into public.billing_reminders (property_id, kind, ends_at) values (r.property_id, v_kind, r.ends_at)
    on conflict (property_id, kind, ends_at) do nothing returning id into v_id;
    if v_id is not null then
      v_txt := public._reminder_text(v_kind, r.ends_at);
      insert into public.notifications (property_id, kind, title, body) values (r.property_id, 'subscription', v_txt->>'title', v_txt->>'body');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

--
-- Name: set_billing_details(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_billing_details(p_property uuid, p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_gstin text := nullif(upper(btrim(coalesce(p->>'bill_gstin', ''))), '');
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then raise exception 'Check the GSTIN — 15 characters, e.g. 33ABCDE1234F1Z5.'; end if;
  update public.properties set
    bill_name = nullif(left(btrim(coalesce(p->>'bill_name', '')), 120), ''),
    bill_gstin = v_gstin,
    bill_address = nullif(left(btrim(coalesce(p->>'bill_address', '')), 300), ''),
    bill_state = coalesce(left(v_gstin, 2), nullif(p->>'bill_state', ''))
  where id = p_property;
end $_$;

--
-- Name: submit_lead(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_lead(p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_phone text := public._clean_phone(p->>'phone');
  v_email text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_type  text := nullif(p->>'property_type', '');
  v_beds  int;
begin
  -- Bots fill the hidden "website" field; humans never see it. Pretend success.
  if coalesce(p->>'website', '') <> '' then return jsonb_build_object('ok', true); end if;

  if char_length(v_name) < 2 then raise exception 'Please enter your name.'; end if;
  if v_phone is null and v_email is null then raise exception 'Please enter a phone number or email so we can reach you.'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please check the phone number.'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please check the email address.'; end if;
  if v_type is not null and v_type not in ('hostel','homestay','hotel','other') then v_type := 'other'; end if;
  begin v_beds := nullif(p->>'beds', '')::int; exception when others then v_beds := null; end;
  if v_beds is not null and (v_beds < 1 or v_beds > 5000) then v_beds := null; end if;

  -- Same person again within 10 minutes: accept quietly, don't duplicate
  if exists (select 1 from public.leads
              where created_at > now() - interval '10 minutes'
                and ((v_phone is not null and phone = v_phone) or (v_email is not null and lower(email) = v_email))) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  -- Flood guard for the whole form
  if (select count(*) from public.leads where created_at > now() - interval '1 minute') >= 20 then
    raise exception 'We''re getting a lot of requests right now. Please try again in a minute.';
  end if;

  insert into public.leads (name, phone, email, property_name, city, property_type, beds, message, source)
  values (left(v_name, 80), v_phone, v_email,
          left(nullif(btrim(p->>'property_name'), ''), 120), left(nullif(btrim(p->>'city'), ''), 80),
          v_type, v_beds, left(nullif(btrim(p->>'message'), ''), 1000), left(nullif(btrim(p->>'source'), ''), 300));
  return jsonb_build_object('ok', true);
end $_$;

--
-- Name: submit_subscription_payment(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_plan public.plans%rowtype; v_utr text := upper(regexp_replace(coalesce(p_utr, ''), '\s', '', 'g')); v_id uuid;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select * into v_plan from public._plans_for(p_property) x where x.id = p_plan;
  if not found then raise exception 'Choose a plan for your property.'; end if;
  if v_plan.is_quote then raise exception 'This plan is priced on request. Please contact NammaStay support.'; end if;
  if v_utr !~ '^[0-9A-Z]{6,35}$' then raise exception 'Enter the UPI transaction ID (UTR) from your payment app.'; end if;
  if (select count(*) from public.subscription_payments where property_id = p_property and status = 'pending') >= 3 then
    raise exception 'You already have payments waiting for confirmation. We’ll confirm them shortly.';
  end if;
  begin
    insert into public.subscription_payments (property_id, plan_id, amount_paise, utr)
    values (p_property, v_plan.id, v_plan.price_paise, v_utr) returning id into v_id;
  exception when unique_violation then
    raise exception 'This UPI transaction ID was already submitted.';
  end;
  return jsonb_build_object('id', v_id, 'status', 'pending');
end $_$;

--
-- Name: submit_subscription_payment(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text, p_coupon text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_plan public.plans%rowtype; v_utr text := upper(regexp_replace(coalesce(p_utr, ''), '\s', '', 'g')); v_id uuid; q jsonb;
begin
  if nullif(btrim(coalesce(p_coupon, '')), '') is null then return public.submit_subscription_payment(p_property, p_plan, p_utr); end if;
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select * into v_plan from public._plans_for(p_property) x where x.id = p_plan;
  if not found then raise exception 'Choose a plan for your property.'; end if;
  if v_plan.is_quote then raise exception 'This plan is priced on request. Please contact NammaStay support.'; end if;
  if v_utr !~ '^[0-9A-Z]{6,35}$' then raise exception 'Enter the UPI transaction ID (UTR) from your payment app.'; end if;
  if (select count(*) from public.subscription_payments where property_id = p_property and status = 'pending') >= 3 then
    raise exception 'You already have payments waiting for confirmation. We’ll confirm them shortly.';
  end if;
  q := public._coupon_quote(p_plan, p_coupon);
  begin
    insert into public.subscription_payments (property_id, plan_id, amount_paise, utr, coupon_code, discount_paise)
    values (p_property, v_plan.id, (q->>'amount_paise')::int, v_utr, q->>'code', (q->>'discount_paise')::int) returning id into v_id;
  exception when unique_violation then raise exception 'This UPI transaction ID was already submitted.';
  end;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'amount_paise', (q->>'amount_paise')::int);
end $_$;

--
-- Name: update_lead(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_lead(p_id uuid, p_status text DEFAULT NULL::text, p_notes text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  update public.leads
     set status = coalesce(p_status::public.lead_status, status),
         notes  = coalesce(p_notes, notes),
         contacted_at = case when p_status is not null and p_status <> 'new' and contacted_at is null then now() else contacted_at end
   where id = p_id;
  if not found then raise exception 'Lead not found.'; end if;
end $$;

--
-- Name: admin_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_actions (
    id bigint NOT NULL,
    admin_id uuid,
    admin_email text,
    action text NOT NULL,
    property_id uuid,
    details jsonb,
    at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: admin_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.admin_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: admin_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.admin_actions_id_seq OWNED BY public.admin_actions.id;

--
-- Name: billing_reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_reminders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    kind text NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    emailed_at timestamp with time zone,
    whatsapp_done_at timestamp with time zone,
    CONSTRAINT billing_reminders_kind_check CHECK ((kind = ANY (ARRAY['trial_3d'::text, 'trial_1d'::text, 'trial_ended'::text, 'renew_7d'::text, 'renew_1d'::text, 'expired'::text])))
);

--
-- Name: coupons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coupons (
    code text NOT NULL,
    kind text NOT NULL,
    value integer NOT NULL,
    plan_ids text[],
    max_uses integer,
    used integer DEFAULT 0 NOT NULL,
    expires_at timestamp with time zone,
    is_active boolean DEFAULT true NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT coupons_check CHECK (((kind <> 'percent'::text) OR (value <= 90))),
    CONSTRAINT coupons_code_check CHECK ((code ~ '^[A-Z0-9-]{3,20}$'::text)),
    CONSTRAINT coupons_kind_check CHECK ((kind = ANY (ARRAY['percent'::text, 'flat'::text]))),
    CONSTRAINT coupons_max_uses_check CHECK (((max_uses IS NULL) OR (max_uses > 0))),
    CONSTRAINT coupons_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT coupons_value_check CHECK ((value > 0))
);

--
-- Name: platform_admins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_admins (
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: platform_invoice_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_invoice_counters (
    fy text NOT NULL,
    last_no integer DEFAULT 0 NOT NULL
);

--
-- Name: platform_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    payment_id uuid NOT NULL,
    number text NOT NULL,
    fy text NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    total_paise integer NOT NULL,
    doc jsonb NOT NULL
);

--
-- Name: platform_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_settings (
    id integer DEFAULT 1 NOT NULL,
    upi_id text,
    payee_name text DEFAULT 'NammaStay'::text NOT NULL,
    trial_days integer DEFAULT 15 NOT NULL,
    grace_days integer DEFAULT 3 NOT NULL,
    support_whatsapp text,
    support_email text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    legal_name text,
    gstin text,
    address text,
    state_code text DEFAULT '33'::text NOT NULL,
    sac text DEFAULT '998314'::text NOT NULL,
    gst_rate numeric(5,2) DEFAULT 18 NOT NULL,
    invoice_prefix text DEFAULT 'NS'::text NOT NULL,
    CONSTRAINT platform_settings_address_check CHECK ((char_length(address) <= 300)),
    CONSTRAINT platform_settings_grace_days_check CHECK (((grace_days >= 0) AND (grace_days <= 30))),
    CONSTRAINT platform_settings_gst_rate_check CHECK (((gst_rate >= (0)::numeric) AND (gst_rate <= (28)::numeric))),
    CONSTRAINT platform_settings_gstin_check CHECK (((gstin IS NULL) OR (gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'::text))),
    CONSTRAINT platform_settings_id_check CHECK ((id = 1)),
    CONSTRAINT platform_settings_invoice_prefix_check CHECK ((invoice_prefix ~ '^[A-Z0-9-]{1,10}$'::text)),
    CONSTRAINT platform_settings_legal_name_check CHECK ((char_length(legal_name) <= 120)),
    CONSTRAINT platform_settings_sac_check CHECK ((sac ~ '^[0-9]{4,8}$'::text)),
    CONSTRAINT platform_settings_state_code_check CHECK ((state_code ~ '^[0-9]{2}$'::text)),
    CONSTRAINT platform_settings_trial_days_check CHECK (((trial_days >= 0) AND (trial_days <= 90))),
    CONSTRAINT platform_settings_upi_id_check CHECK (((upi_id IS NULL) OR (upi_id ~ '^[A-Za-z0-9._-]{2,255}@[A-Za-z]{2,64}$'::text)))
);

--
-- Name: subscription_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    plan_id text NOT NULL,
    amount_paise integer NOT NULL,
    utr text NOT NULL,
    status public.sub_payment_status DEFAULT 'pending'::public.sub_payment_status NOT NULL,
    submitted_by uuid DEFAULT auth.uid(),
    submitted_at timestamp with time zone DEFAULT now() NOT NULL,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    review_note text,
    period_start timestamp with time zone,
    period_end timestamp with time zone,
    coupon_code text,
    discount_paise integer DEFAULT 0 NOT NULL,
    CONSTRAINT subscription_payments_amount_paise_check CHECK ((amount_paise >= 0)),
    CONSTRAINT subscription_payments_discount_paise_check CHECK ((discount_paise >= 0)),
    CONSTRAINT subscription_payments_review_note_check CHECK ((char_length(review_note) <= 500)),
    CONSTRAINT subscription_payments_utr_check CHECK ((utr ~ '^[0-9A-Z]{6,35}$'::text))
);

--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    property_id uuid NOT NULL,
    plan_id text,
    trial_ends_at timestamp with time zone NOT NULL,
    paid_until timestamp with time zone,
    is_complimentary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_suspended boolean DEFAULT false NOT NULL,
    suspended_reason text,
    suspended_at timestamp with time zone,
    admin_note text,
    CONSTRAINT subscriptions_admin_note_check CHECK ((char_length(admin_note) <= 4000)),
    CONSTRAINT subscriptions_suspended_reason_check CHECK ((char_length(suspended_reason) <= 300))
);

--
-- Name: admin_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_actions ALTER COLUMN id SET DEFAULT nextval('public.admin_actions_id_seq'::regclass);

--
-- Name: admin_actions admin_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_actions
    ADD CONSTRAINT admin_actions_pkey PRIMARY KEY (id);

--
-- Name: billing_reminders billing_reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_reminders
    ADD CONSTRAINT billing_reminders_pkey PRIMARY KEY (id);

--
-- Name: billing_reminders billing_reminders_property_id_kind_ends_at_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_reminders
    ADD CONSTRAINT billing_reminders_property_id_kind_ends_at_key UNIQUE (property_id, kind, ends_at);

--
-- Name: coupons coupons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupons
    ADD CONSTRAINT coupons_pkey PRIMARY KEY (code);

--
-- Name: leads leads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_pkey PRIMARY KEY (id);

--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT plans_pkey PRIMARY KEY (id);

--
-- Name: platform_admins platform_admins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_admins
    ADD CONSTRAINT platform_admins_pkey PRIMARY KEY (user_id);

--
-- Name: platform_invoice_counters platform_invoice_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoice_counters
    ADD CONSTRAINT platform_invoice_counters_pkey PRIMARY KEY (fy);

--
-- Name: platform_invoices platform_invoices_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoices
    ADD CONSTRAINT platform_invoices_number_key UNIQUE (number);

--
-- Name: platform_invoices platform_invoices_payment_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoices
    ADD CONSTRAINT platform_invoices_payment_id_key UNIQUE (payment_id);

--
-- Name: platform_invoices platform_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoices
    ADD CONSTRAINT platform_invoices_pkey PRIMARY KEY (id);

--
-- Name: platform_settings platform_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_settings
    ADD CONSTRAINT platform_settings_pkey PRIMARY KEY (id);

--
-- Name: subscription_payments subscription_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payments
    ADD CONSTRAINT subscription_payments_pkey PRIMARY KEY (id);

--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (property_id);

--
-- Name: admin_actions_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX admin_actions_at ON public.admin_actions USING btree (at DESC);

--
-- Name: billing_reminders_todo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_reminders_todo ON public.billing_reminders USING btree (created_at DESC);

--
-- Name: leads_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_email ON public.leads USING btree (lower(email));

--
-- Name: leads_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_phone ON public.leads USING btree (phone);

--
-- Name: leads_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_recent ON public.leads USING btree (created_at DESC, id DESC);

--
-- Name: leads_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_status ON public.leads USING btree (status, created_at DESC);

--
-- Name: platform_invoices_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_invoices_prop ON public.platform_invoices USING btree (property_id, issued_at DESC);

--
-- Name: subscription_payments_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_payments_pending ON public.subscription_payments USING btree (status, submitted_at DESC);

--
-- Name: subscription_payments_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscription_payments_property ON public.subscription_payments USING btree (property_id, submitted_at DESC);

--
-- Name: subscription_payments_utr; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscription_payments_utr ON public.subscription_payments USING btree (utr) WHERE (status <> 'rejected'::public.sub_payment_status);

--
-- Name: subscriptions_paid_until; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_paid_until ON public.subscriptions USING btree (paid_until);

--
-- Name: coupons admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.coupons FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: leads admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.leads FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: plans admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.plans FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: platform_admins admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.platform_admins FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: platform_settings admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.platform_settings FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: subscription_payments admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.subscription_payments FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: subscriptions admin_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER admin_audit AFTER INSERT OR DELETE OR UPDATE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION public._admin_audit();

--
-- Name: leads leads_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER leads_touch BEFORE UPDATE ON public.leads FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

--
-- Name: subscription_payments sub_payment_coupon; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sub_payment_coupon AFTER UPDATE OF status ON public.subscription_payments FOR EACH ROW EXECUTE FUNCTION public._coupon_used();

--
-- Name: subscription_payments sub_payment_invoice; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sub_payment_invoice AFTER UPDATE OF status ON public.subscription_payments FOR EACH ROW EXECUTE FUNCTION public._on_sub_payment_approved();

--
-- Name: subscriptions subscriptions_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER subscriptions_touch BEFORE UPDATE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

--
-- Name: billing_reminders billing_reminders_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_reminders
    ADD CONSTRAINT billing_reminders_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: leads leads_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE SET NULL;

--
-- Name: platform_admins platform_admins_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_admins
    ADD CONSTRAINT platform_admins_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

--
-- Name: platform_invoices platform_invoices_payment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoices
    ADD CONSTRAINT platform_invoices_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.subscription_payments(id) ON DELETE CASCADE;

--
-- Name: platform_invoices platform_invoices_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoices
    ADD CONSTRAINT platform_invoices_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: subscription_payments subscription_payments_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payments
    ADD CONSTRAINT subscription_payments_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.plans(id);

--
-- Name: subscription_payments subscription_payments_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_payments
    ADD CONSTRAINT subscription_payments_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: subscriptions subscriptions_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.plans(id);

--
-- Name: subscriptions subscriptions_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: admin_actions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_admins admins_self_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admins_self_select ON public.platform_admins FOR SELECT TO authenticated USING ((user_id = ( SELECT auth.uid() AS uid)));

--
-- Name: billing_reminders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_reminders ENABLE ROW LEVEL SECURITY;

--
-- Name: coupons; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;

--
-- Name: leads; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;

--
-- Name: leads leads_admin_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY leads_admin_select ON public.leads FOR SELECT TO authenticated USING (public.is_platform_admin());

--
-- Name: plans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;

--
-- Name: plans plans_public_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY plans_public_read ON public.plans FOR SELECT TO anon, authenticated USING (is_active);

--
-- Name: platform_admins; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_invoice_counters; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_invoice_counters ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_invoices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_invoices ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_payments subpay_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY subpay_read ON public.subscription_payments FOR SELECT TO authenticated USING (((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) AS my_property_ids)) OR public.is_platform_admin()));

--
-- Name: subscriptions subs_member_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY subs_member_read ON public.subscriptions FOR SELECT TO authenticated USING (((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)) OR public.is_platform_admin()));

--
-- Name: subscription_payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscription_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION _assert_platform_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._assert_platform_admin() FROM PUBLIC;

--
-- Name: FUNCTION _coupon_quote(p_plan text, p_code text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._coupon_quote(p_plan text, p_code text) FROM PUBLIC;

--
-- Name: FUNCTION _issue_platform_invoice(p_payment uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._issue_platform_invoice(p_payment uuid) FROM PUBLIC;

--
-- Name: TABLE plans; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.plans TO anon;
GRANT SELECT ON TABLE public.plans TO authenticated;

--
-- Name: FUNCTION _plans_for(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._plans_for(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _reminder_text(p_kind text, p_ends timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._reminder_text(p_kind text, p_ends timestamp with time zone) FROM PUBLIC;

--
-- Name: FUNCTION admin_actions_list(p_limit integer, p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_actions_list(p_limit integer, p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_actions_list(p_limit integer, p_property uuid) TO authenticated;

--
-- Name: FUNCTION admin_backfill_invoices(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_backfill_invoices() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_backfill_invoices() TO authenticated;

--
-- Name: FUNCTION admin_coupons(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_coupons() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_coupons() TO authenticated;

--
-- Name: FUNCTION admin_create_property(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_create_property(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_create_property(p jsonb) TO authenticated;

--
-- Name: FUNCTION admin_health(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_health() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_health() TO authenticated;

--
-- Name: FUNCTION admin_invoice_settings(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_invoice_settings() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_invoice_settings() TO authenticated;

--
-- Name: FUNCTION admin_lead_converted(p_lead uuid, p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_lead_converted(p_lead uuid, p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_lead_converted(p_lead uuid, p_property uuid) TO authenticated;

--
-- Name: FUNCTION admin_mark_reminder(p_id uuid, p_done boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_mark_reminder(p_id uuid, p_done boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_mark_reminder(p_id uuid, p_done boolean) TO authenticated;

--
-- Name: FUNCTION admin_mfa_info(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_mfa_info() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_mfa_info() TO authenticated;

--
-- Name: FUNCTION admin_overview(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_overview() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_overview() TO authenticated;

--
-- Name: FUNCTION admin_platform_invoices(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_platform_invoices(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_platform_invoices(p_property uuid) TO authenticated;

--
-- Name: FUNCTION admin_property(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_property(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_property(p_property uuid) TO authenticated;

--
-- Name: FUNCTION admin_property_invites(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_property_invites(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_property_invites(p_property uuid) TO authenticated;

--
-- Name: FUNCTION admin_reminders(p_all boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_reminders(p_all boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_reminders(p_all boolean) TO authenticated;

--
-- Name: FUNCTION admin_revenue(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_revenue() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_revenue() TO authenticated;

--
-- Name: FUNCTION admin_review_subscription_payment(p_id uuid, p_approve boolean, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_review_subscription_payment(p_id uuid, p_approve boolean, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_review_subscription_payment(p_id uuid, p_approve boolean, p_note text) TO authenticated;

--
-- Name: FUNCTION admin_save_billing_settings(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_save_billing_settings(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_save_billing_settings(p jsonb) TO authenticated;

--
-- Name: FUNCTION admin_save_coupon(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_save_coupon(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_save_coupon(p jsonb) TO authenticated;

--
-- Name: FUNCTION admin_save_invoice_settings(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_save_invoice_settings(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_save_invoice_settings(p jsonb) TO authenticated;

--
-- Name: FUNCTION admin_set_property(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_property(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_property(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION admin_subscriptions(p_q text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_subscriptions(p_q text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_subscriptions(p_q text) TO authenticated;

--
-- Name: FUNCTION admin_update_subscription(p_property uuid, p_extend_days integer, p_complimentary boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_update_subscription(p_property uuid, p_extend_days integer, p_complimentary boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_update_subscription(p_property uuid, p_extend_days integer, p_complimentary boolean) TO authenticated;

--
-- Name: FUNCTION billing_info(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.billing_info(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.billing_info(p_property uuid) TO authenticated;

--
-- Name: FUNCTION check_coupon(p_property uuid, p_plan text, p_code text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_coupon(p_property uuid, p_plan text, p_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_coupon(p_property uuid, p_plan text, p_code text) TO authenticated;

--
-- Name: FUNCTION lead_counts(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.lead_counts() FROM PUBLIC;
GRANT ALL ON FUNCTION public.lead_counts() TO authenticated;

--
-- Name: TABLE leads; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.leads TO authenticated;

--
-- Name: FUNCTION list_leads(p_status text, p_q text, p_cursor_at timestamp with time zone, p_cursor_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_leads(p_status text, p_q text, p_cursor_at timestamp with time zone, p_cursor_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_leads(p_status text, p_q text, p_cursor_at timestamp with time zone, p_cursor_id uuid, p_limit integer) TO authenticated;

--
-- Name: FUNCTION mark_reminders_emailed(p_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.mark_reminders_emailed(p_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_reminders_emailed(p_ids uuid[]) TO service_role;

--
-- Name: FUNCTION my_billing_details(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_billing_details(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_billing_details(p_property uuid) TO authenticated;

--
-- Name: FUNCTION my_platform_invoices(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.my_platform_invoices(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.my_platform_invoices(p_property uuid) TO authenticated;

--
-- Name: FUNCTION property_access(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.property_access(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.property_access(p_property uuid) TO authenticated;

--
-- Name: FUNCTION property_suspension(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.property_suspension(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.property_suspension(p_property uuid) TO authenticated;

--
-- Name: FUNCTION reminders_to_email(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reminders_to_email() FROM PUBLIC;
GRANT ALL ON FUNCTION public.reminders_to_email() TO service_role;

--
-- Name: FUNCTION run_billing_reminders(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.run_billing_reminders() FROM PUBLIC;
GRANT ALL ON FUNCTION public.run_billing_reminders() TO authenticated;
GRANT ALL ON FUNCTION public.run_billing_reminders() TO service_role;

--
-- Name: FUNCTION set_billing_details(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_billing_details(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_billing_details(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION submit_lead(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_lead(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_lead(p jsonb) TO anon;
GRANT ALL ON FUNCTION public.submit_lead(p jsonb) TO authenticated;

--
-- Name: FUNCTION submit_subscription_payment(p_property uuid, p_plan text, p_utr text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text) TO authenticated;

--
-- Name: FUNCTION submit_subscription_payment(p_property uuid, p_plan text, p_utr text, p_coupon text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text, p_coupon text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_subscription_payment(p_property uuid, p_plan text, p_utr text, p_coupon text) TO authenticated;

--
-- Name: FUNCTION update_lead(p_id uuid, p_status text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_lead(p_id uuid, p_status text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_lead(p_id uuid, p_status text, p_notes text) TO authenticated;

--
-- Name: TABLE platform_admins; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.platform_admins TO authenticated;

--
-- Name: TABLE subscription_payments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.subscription_payments TO authenticated;

--
-- Name: TABLE subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.subscriptions TO authenticated;


--
-- PostgreSQL database dump complete
--

-- ---------------------------------------------------------------- storage, realtime & default rows
-- default plans and platform settings (prices can be changed later in the admin panel)
INSERT INTO public.plans VALUES ('hotel_l_quote', 'Large hotels', 1, 0, '50+ rooms — custom pricing', true, 24, 'hotel', 51, NULL, true) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('monthly', 'Monthly', 1, 399900, 'Billed every month', true, 10, 'hostel', NULL, NULL, false) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('yearly', 'Yearly', 12, 2799900, 'Save ₹19,989 a year', true, 11, 'hostel', NULL, NULL, false) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('homestay_monthly', 'Monthly', 1, 199900, 'Homestays up to 6 rooms', true, 1, 'homestay', NULL, 6, false) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('homestay_yearly', 'Yearly', 12, 1299900, 'Homestays · save ₹10,989 a year', true, 2, 'homestay', NULL, 6, false) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('hotel_s_monthly', 'Monthly', 1, 399900, 'Hotels up to 20 rooms', true, 20, 'hotel', NULL, 20, false) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('hotel_s_yearly', 'Yearly', 12, 2799900, 'Up to 20 rooms · save ₹19,989 a year', true, 21, 'hotel', NULL, 20, false) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('hotel_m_monthly', 'Monthly', 1, 699900, 'Hotels with 21–50 rooms', true, 22, 'hotel', 21, 50, false) ON CONFLICT DO NOTHING;
INSERT INTO public.plans VALUES ('hotel_m_yearly', 'Yearly', 12, 4599900, '21–50 rooms · save ₹37,989 a year', true, 23, 'hotel', 21, 50, false) ON CONFLICT DO NOTHING;
INSERT INTO public.platform_settings VALUES (1, NULL, 'NammaStay', 15, 3, NULL, NULL, '2026-10-16 14:02:12.951301+05:30', NULL, NULL, NULL, '33', '998314', 18.00, 'NS') ON CONFLICT DO NOTHING;
