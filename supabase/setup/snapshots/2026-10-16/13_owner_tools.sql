-- =====================================================================
-- NammaStay · owner tools
-- Owner tools: my investment, licences & documents, business health, my business
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
-- Name: _bh_area(text, text, text, text, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._bh_area(p_key text, p_title text, p_status text, p_value text, p_detail text, p_how text, p_tip text, p_weight integer) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
  select jsonb_build_object('key', p_key, 'title', p_title, 'status', p_status, 'value', p_value, 'detail', p_detail,
           'how', p_how, 'tip', case when p_status in ('amber', 'red', 'unknown') then p_tip end, 'weight', p_weight)
$$;

--
-- Name: _bh_income(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._bh_income(p_property uuid, p_from date, p_to date) RETURNS bigint
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_tz text := public._bh_tz(p_property); v_sql text; v bigint; t text;
begin
  v_sql := 'select coalesce(sum(case when kind::text = ''refund'' then -amount_paise else amount_paise end), 0)::bigint from (
              select kind::text kind, amount_paise, received_at from public.payments where property_id = $1';
  foreach t in array array['pg_rent_payments', 'rent_payments', 'resort_payments'] loop
    if to_regclass('public.' || t) is not null then
      v_sql := v_sql || ' union all select kind::text, amount_paise, received_at from public.' || t || ' where property_id = $1';
    end if;
  end loop;
  v_sql := v_sql || ') x where (received_at at time zone $4)::date between $2 and $3';
  execute v_sql into v using p_property, p_from, p_to, v_tz;
  return v;
end $_$;

--
-- Name: _bh_occ(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._bh_occ(p_property uuid, p_from date, p_to date, OUT units integer, OUT available bigint, OUT occupied bigint, OUT full_nights integer, OUT ota_nights bigint, OUT direct_nights bigint) RETURNS record
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_tz text := public._bh_tz(p_property); v_pg text := '';
begin
  select count(*) into units from public.beds where property_id = p_property and is_active;
  available := units::bigint * (p_to - p_from + 1);
  if to_regclass('public.pg_tenancies') is not null then
    v_pg := ' union select d, t.bed_id, ''pg'' from nights n join public.pg_tenancies t on t.property_id = $1
               and t.start_date <= n.d and (t.move_out_on is null or n.d < t.move_out_on) and t.status <> ''moved_out''';
  elsif to_regclass('public.tenancies') is not null then
    v_pg := ' union select d, t.bed_id, ''pg'' from nights n join public.tenancies t on t.property_id = $1
               and t.start_date <= n.d and (t.move_out_on is null or n.d < t.move_out_on) and t.booking_id is null';
  end if;
  execute
   'with nights as (select generate_series($2::date, $3::date, interval ''1 day'')::date d),
         occ as (
           select n.d, b.bed_id, case when b.source = ''ota'' then ''ota'' else ''direct'' end src
             from nights n join public.bookings b on b.property_id = $1
              and b.status in (''confirmed'', ''checked_in'', ''checked_out'')
              and (b.check_in_at at time zone $4)::date <= n.d and n.d < (b.check_out_at at time zone $4)::date
           union
           select n.d, k.bed_id, ''ota'' from nights n join public.bed_blocks k on k.property_id = $1 and k.feed_id is not null
              and (k.starts_at at time zone $4)::date <= n.d and n.d < (k.ends_at at time zone $4)::date' || v_pg || '),
         per_night as (select d, count(distinct bed_id) c from occ group by d)
    select (select count(*) from (select distinct d, bed_id from occ) x),
           (select count(*) from per_night where c >= greatest(1, ceil($5 * 0.95))),
           (select count(*) from (select distinct d, bed_id from occ where src = ''ota'') x),
           (select count(*) from (select distinct d, bed_id from occ where src <> ''ota'') x)'
    into occupied, full_nights, ota_nights, direct_nights
    using p_property, p_from, p_to, v_tz, units;
  if units = 0 then full_nights := 0; end if;
end $_$;

--
-- Name: _bh_tz(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._bh_tz(p_property uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata')
$$;

--
-- Name: business_lease; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_lease (
    property_id uuid NOT NULL,
    landlord text,
    start_on date NOT NULL,
    end_on date NOT NULL,
    rent_paise bigint NOT NULL,
    increase_pct numeric(5,2) DEFAULT 0 NOT NULL,
    increase_every_months integer DEFAULT 12 NOT NULL,
    deposit_paise bigint DEFAULT 0 NOT NULL,
    lock_in_months integer DEFAULT 0 NOT NULL,
    notice_months integer DEFAULT 0 NOT NULL,
    note text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT business_lease_check CHECK ((end_on > start_on)),
    CONSTRAINT business_lease_deposit_paise_check CHECK ((deposit_paise >= 0)),
    CONSTRAINT business_lease_increase_every_months_check CHECK (((increase_every_months >= 1) AND (increase_every_months <= 120))),
    CONSTRAINT business_lease_increase_pct_check CHECK (((increase_pct >= (0)::numeric) AND (increase_pct <= (50)::numeric))),
    CONSTRAINT business_lease_landlord_check CHECK ((char_length(landlord) <= 80)),
    CONSTRAINT business_lease_lock_in_months_check CHECK (((lock_in_months >= 0) AND (lock_in_months <= 240))),
    CONSTRAINT business_lease_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT business_lease_notice_months_check CHECK (((notice_months >= 0) AND (notice_months <= 24))),
    CONSTRAINT business_lease_rent_paise_check CHECK (((rent_paise >= 0) AND (rent_paise <= '100000000000'::bigint)))
);

--
-- Name: _biz_lease(public.business_lease, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._biz_lease(b public.business_lease, p_today date) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_steps int; v_rent numeric; v_next date; v_lock date; v_notice date; v_left int; v_to_end numeric := 0; d date; s int;
begin
  v_steps := case when p_today < b.start_on then 0 else floor(public._biz_months(b.start_on, p_today) / b.increase_every_months::numeric)::int end;
  v_rent := b.rent_paise * power(1 + b.increase_pct / 100.0, v_steps);
  v_next := (b.start_on + make_interval(months => (v_steps + 1) * b.increase_every_months))::date;
  if v_next >= b.end_on or b.increase_pct = 0 then v_next := null; end if;
  v_lock := case when b.lock_in_months > 0 then (b.start_on + make_interval(months => b.lock_in_months))::date end;
  v_notice := case when b.notice_months > 0 then (b.end_on - make_interval(months => b.notice_months))::date end;
  v_left := greatest(public._biz_months(p_today, b.end_on), 0);
  d := date_trunc('month', greatest(p_today, b.start_on))::date;
  while d < b.end_on and d < p_today + 3660 loop                       -- rent still to pay until the lease ends
    s := floor(public._biz_months(b.start_on, d) / b.increase_every_months::numeric)::int;
    v_to_end := v_to_end + b.rent_paise * power(1 + b.increase_pct / 100.0, greatest(s, 0));
    d := (d + interval '1 month')::date;
  end loop;
  return jsonb_build_object('landlord', b.landlord, 'start_on', b.start_on, 'end_on', b.end_on, 'rent_start_paise', b.rent_paise,
    'increase_pct', b.increase_pct, 'increase_every_months', b.increase_every_months, 'deposit_paise', b.deposit_paise,
    'lock_in_months', b.lock_in_months, 'notice_months', b.notice_months, 'note', b.note,
    'rent_now_paise', round(v_rent)::bigint, 'next_increase_on', v_next,
    'next_rent_paise', case when v_next is null then null else round(v_rent * (1 + b.increase_pct / 100.0))::bigint end,
    'lock_in_until', v_lock, 'notice_by', v_notice, 'months_left', v_left, 'days_left', b.end_on - p_today,
    'rent_to_end_paise', round(v_to_end)::bigint, 'ended', b.end_on <= p_today);
end $$;

--
-- Name: business_loans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_loans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    lender text NOT NULL,
    principal_paise bigint NOT NULL,
    rate_pct numeric(5,2) NOT NULL,
    tenure_months integer NOT NULL,
    emi_paise bigint,
    first_emi_on date NOT NULL,
    closed_on date,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT business_loans_emi_paise_check CHECK (((emi_paise IS NULL) OR (emi_paise > 0))),
    CONSTRAINT business_loans_lender_check CHECK (((char_length(btrim(lender)) >= 2) AND (char_length(btrim(lender)) <= 80))),
    CONSTRAINT business_loans_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT business_loans_principal_paise_check CHECK (((principal_paise >= 100) AND (principal_paise <= '100000000000'::bigint))),
    CONSTRAINT business_loans_rate_pct_check CHECK (((rate_pct >= (0)::numeric) AND (rate_pct <= (60)::numeric))),
    CONSTRAINT business_loans_tenure_months_check CHECK (((tenure_months >= 1) AND (tenure_months <= 360)))
);

--
-- Name: _biz_loan(public.business_loans, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._biz_loan(l public.business_loans, p_today date) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  r numeric := l.rate_pct / 1200.0; n int := l.tenure_months; p numeric := l.principal_paise;
  emi numeric; k int; bal numeric; f numeric; paid_int numeric; tot_int numeric; asof date;
begin
  emi := coalesce(l.emi_paise::numeric, case when r = 0 then p / n else p * r * power(1 + r, n) / (power(1 + r, n) - 1) end);
  asof := least(p_today, coalesce(l.closed_on, p_today));
  k := (select count(*) from generate_series(0, n - 1) i where (l.first_emi_on + make_interval(months => i))::date <= asof);
  f := power(1 + r, k);
  bal := case when r = 0 then greatest(p - emi * k, 0) else greatest(p * f - emi * (f - 1) / r, 0) end;
  paid_int := greatest(emi * k - (p - bal), 0);
  tot_int := greatest(emi * n - p, 0);
  return jsonb_build_object(
    'id', l.id, 'lender', l.lender, 'principal_paise', l.principal_paise, 'rate_pct', l.rate_pct, 'tenure_months', n,
    'emi_paise', round(emi)::bigint, 'emi_entered', l.emi_paise is not null, 'first_emi_on', l.first_emi_on, 'closed_on', l.closed_on, 'note', l.note,
    'emis_paid', k, 'emis_left', case when l.closed_on is not null then 0 else n - k end,
    'outstanding_paise', case when l.closed_on is not null then 0 else round(bal)::bigint end,
    'interest_paid_paise', round(paid_int)::bigint,
    'interest_total_paise', case when l.closed_on is not null then round(paid_int)::bigint else round(tot_int)::bigint end,
    'interest_left_paise', case when l.closed_on is not null then 0 else round(greatest(tot_int - paid_int, 0))::bigint end,
    'interest_this_month_paise', case when l.closed_on is not null or k >= n then 0 else round(bal * r)::bigint end,
    'next_emi_on', case when l.closed_on is not null or k >= n then null else (l.first_emi_on + make_interval(months => k))::date end,
    'last_emi_on', (l.first_emi_on + make_interval(months => n - 1))::date,
    'done', l.closed_on is not null or k >= n);
end $$;

--
-- Name: _biz_months(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._biz_months(p_from date, p_to date) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
  select (extract(year from age(p_to, p_from)) * 12 + extract(month from age(p_to, p_from)))::int
$$;

--
-- Name: _biz_notify(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._biz_notify(p_property uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_today date := public._inv_today(p_property); l public.business_loans; j jsonb; b public.business_lease; x jsonb; n int := 0; lvl int; v_left int;
begin
  for l in select * from public.business_loans where property_id = p_property and closed_on is null loop
    j := public._biz_loan(l, v_today);
    if (j->>'next_emi_on') is not null and (j->>'next_emi_on')::date - v_today between 0 and 3 then
      n := n + public._biz_remind(p_property, 'emi:' || l.id || ':' || (j->>'next_emi_on'),
        'EMI ' || to_char((j->>'emi_paise')::bigint / 100.0, 'FM₹99,99,99,990') || ' due ' || to_char((j->>'next_emi_on')::date, 'DD Mon'),
        l.lender || ' loan — keep the money in the account to avoid a bounce charge.');
    end if;
  end loop;
  select * into b from public.business_lease where property_id = p_property;
  if b.property_id is not null and coalesce((select is_rented from public.business_profile where property_id = p_property), true) then
    x := public._biz_lease(b, v_today);
    v_left := b.end_on - v_today;
    lvl := case when v_left < 0 then null when v_left <= 30 then 30 when v_left <= 90 then 90 when v_left <= 180 then 180 end;
    if lvl is not null then
      n := n + public._biz_remind(p_property, 'lease_end:' || b.end_on || ':' || lvl,
        'Lease ends in ' || v_left || ' days (' || to_char(b.end_on, 'DD Mon YYYY') || ')',
        'Talk to your landlord about renewing — see My business → Loans, partners & lease.');
    end if;
    if (x->>'notice_by') is not null and (x->>'notice_by')::date - v_today between 0 and 30 then
      n := n + public._biz_remind(p_property, 'notice:' || (x->>'notice_by'),
        'Lease notice deadline ' || to_char((x->>'notice_by')::date, 'DD Mon YYYY'),
        'Your lease needs ' || b.notice_months || ' month(s) notice before it ends. Decide to renew or leave before this date.');
    end if;
    if (x->>'next_increase_on') is not null and (x->>'next_increase_on')::date - v_today between 0 and 30 then
      n := n + public._biz_remind(p_property, 'rent_up:' || (x->>'next_increase_on'),
        'Rent goes up on ' || to_char((x->>'next_increase_on')::date, 'DD Mon'),
        'New rent about ' || to_char((x->>'next_rent_paise')::bigint / 100.0, 'FM₹99,99,99,990') || ' a month (+' || b.increase_pct || '%).');
    end if;
  end if;
  return n;
end $$;

--
-- Name: _biz_remind(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._biz_remind(p_property uuid, p_key text, p_title text, p_body text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  insert into public.business_reminders (property_id, key) values (p_property, p_key) on conflict do nothing;
  if not found then return 0; end if;
  insert into public.notifications (property_id, user_id, kind, title, body)
  select p_property, m.user_id, 'my_business', p_title, p_body from public.property_members m where m.property_id = p_property and m.role = 'owner';
  return 1;
end $$;

--
-- Name: _inv_months(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._inv_months(p_property uuid, p_from date) RETURNS TABLE(month date, revenue_paise bigint, expenses_paise bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_tz text; v_to date; v_extra text := '';
begin
  select coalesce(timezone, 'Asia/Kolkata') into v_tz from public.properties where id = p_property;
  v_to := public._inv_today(p_property);
  if to_regclass('public.pg_rent_payments') is not null then
    v_extra := v_extra || ' union all select (received_at at time zone $2)::date, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint
                 from public.pg_rent_payments where property_id = $1';
  end if;
  if to_regclass('public.rent_payments') is not null then      -- PG rent (NammaStay 031 naming)
    v_extra := v_extra || ' union all select (received_at at time zone $2)::date, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint
                 from public.rent_payments where property_id = $1';
  end if;
  if to_regclass('public.resort_payments') is not null then
    v_extra := v_extra || ' union all select (received_at at time zone $2)::date, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint
                 from public.resort_payments where property_id = $1';
  end if;
  return query execute
    'with inc as (
       select (received_at at time zone $2)::date d, case when kind = ''refund'' then -amount_paise else amount_paise end::bigint a
         from public.payments where property_id = $1' || v_extra || '),
     m as (select generate_series(date_trunc(''month'', $3)::date, date_trunc(''month'', $4)::date, interval ''1 month'')::date as month)
     select m.month,
            coalesce((select sum(a) from inc where d >= $3 and date_trunc(''month'', d)::date = m.month), 0)::bigint,
            coalesce((select sum(amount_paise) from public.expenses e where e.property_id = $1 and e.spent_on >= $3
                        and date_trunc(''month'', e.spent_on)::date = m.month), 0)::bigint
       from m order by m.month'
    using p_property, v_tz, p_from, v_to;
end $_$;

--
-- Name: _inv_opened_on(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._inv_opened_on(p_property uuid) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(
    (select opened_on from public.investment_settings where property_id = p_property),
    (select min(check_in_at)::date from public.bookings where property_id = p_property),
    (select created_at::date from public.properties where id = p_property))
$$;

--
-- Name: _inv_owner(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._inv_owner(p_property uuid) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if p_property is null then raise exception 'Property missing.'; end if;
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
end $$;

--
-- Name: _inv_today(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._inv_today(p_property uuid) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (now() at time zone coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata'))::date
$$;

--
-- Name: _legal_docs_notify(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._legal_docs_notify(p_property uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare r record; v_today date := public._inv_today(p_property); v_left int; v_level smallint; n int := 0;
begin
  for r in select * from public.legal_documents where property_id = p_property and expires_on is not null loop
    v_left := r.expires_on - v_today;
    v_level := case when v_left < 0 then -1 when v_left <= 3 then 3 when v_left <= 15 then 15 when v_left <= 30 then 30 else 0 end;
    if v_level <> 0 and v_level is distinct from r.reminded_level
       and (r.reminded_level = 0 or v_level = -1 or v_level < r.reminded_level) then
      insert into public.notifications (property_id, user_id, kind, title, body)
      select p_property, m.user_id, 'legal_doc',
             case when v_left < 0 then r.title || ' has expired'
                  when v_left = 0 then r.title || ' expires today'
                  else r.title || ' expires in ' || v_left || ' day' || case when v_left = 1 then '' else 's' end end,
             'Expiry date ' || to_char(r.expires_on, 'DD Mon YYYY') || '. Renew it and update the date in My investment → Legal documents.'
        from public.property_members m where m.property_id = p_property and m.role = 'owner';
      update public.legal_documents set reminded_level = v_level where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

--
-- Name: biz_investment_partner(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_investment_partner(p_investment uuid, p_partner uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.investments where id = p_investment;
  if v_prop is null then raise exception 'Investment not found.'; end if;
  perform public._inv_owner(v_prop);
  if p_partner is not null and not exists (select 1 from public.business_partners where id = p_partner and property_id = v_prop) then
    raise exception 'Partner not found.';
  end if;
  update public.investments set partner_id = p_partner where id = p_investment;
  return public.biz_summary(v_prop);
end $$;

--
-- Name: biz_lease_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_lease_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_start date; v_end date;
begin
  perform public._inv_owner(p_property);
  begin v_start := (p->>'start_on')::date; v_end := (p->>'end_on')::date;
  exception when others then raise exception 'Check the lease dates.'; end;
  if v_start is null or v_end is null then raise exception 'Enter when the lease started and when it ends.'; end if;
  if v_end <= v_start then raise exception 'The lease end must be after the start.'; end if;
  if coalesce((p->>'rent_paise')::bigint, -1) < 0 then raise exception 'Enter the monthly rent at the start of the lease.'; end if;
  insert into public.business_lease as bl (property_id, landlord, start_on, end_on, rent_paise, increase_pct, increase_every_months, deposit_paise, lock_in_months, notice_months, note)
  values (p_property, nullif(btrim(p->>'landlord'), ''), v_start, v_end, (p->>'rent_paise')::bigint, coalesce(nullif(p->>'increase_pct', '')::numeric, 0),
          coalesce(nullif(p->>'increase_every_months', '')::int, 12), coalesce(nullif(p->>'deposit_paise', '')::bigint, 0),
          coalesce(nullif(p->>'lock_in_months', '')::int, 0), coalesce(nullif(p->>'notice_months', '')::int, 0), nullif(btrim(p->>'note'), ''))
  on conflict (property_id) do update set landlord = excluded.landlord, start_on = excluded.start_on, end_on = excluded.end_on, rent_paise = excluded.rent_paise,
     increase_pct = excluded.increase_pct, increase_every_months = excluded.increase_every_months, deposit_paise = excluded.deposit_paise,
     lock_in_months = excluded.lock_in_months, notice_months = excluded.notice_months, note = excluded.note, updated_at = now();
  insert into public.business_profile (property_id, is_rented) values (p_property, true)
  on conflict (property_id) do update set is_rented = true, updated_at = now();
  return public.biz_summary(p_property);
end $$;

--
-- Name: biz_loan_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_loan_delete(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.business_loans where id = p_id;
  if v_prop is null then raise exception 'Loan not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.business_loans where id = p_id;
  return public.biz_summary(v_prop);
end $$;

--
-- Name: biz_loan_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_loan_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_first date; v_closed date;
begin
  perform public._inv_owner(p_property);
  if char_length(btrim(coalesce(p->>'lender', ''))) < 2 then raise exception 'Who gave the loan? (e.g. SBI, HDFC, family)'; end if;
  if coalesce((p->>'principal_paise')::bigint, 0) < 100 then raise exception 'Enter the loan amount.'; end if;
  if (p->>'rate_pct') is null or (p->>'rate_pct')::numeric not between 0 and 60 then raise exception 'Interest rate should be between 0 and 60%% a year.'; end if;
  if coalesce((p->>'tenure_months')::int, 0) not between 1 and 360 then raise exception 'Loan period: 1 to 360 months.'; end if;
  begin v_first := (p->>'first_emi_on')::date; v_closed := nullif(p->>'closed_on', '')::date;
  exception when others then raise exception 'Check the dates.'; end;
  if v_first is null then raise exception 'When was (or is) the first EMI?'; end if;
  if v_closed is not null and v_closed < v_first - 31 then raise exception 'The closing date is before the loan started.'; end if;
  if v_id is null then
    insert into public.business_loans (property_id, lender, principal_paise, rate_pct, tenure_months, emi_paise, first_emi_on, closed_on, note)
    values (p_property, btrim(p->>'lender'), (p->>'principal_paise')::bigint, (p->>'rate_pct')::numeric, (p->>'tenure_months')::int,
            nullif(p->>'emi_paise', '')::bigint, v_first, v_closed, nullif(btrim(p->>'note'), ''));
  else
    update public.business_loans set lender = btrim(p->>'lender'), principal_paise = (p->>'principal_paise')::bigint, rate_pct = (p->>'rate_pct')::numeric,
           tenure_months = (p->>'tenure_months')::int, emi_paise = nullif(p->>'emi_paise', '')::bigint, first_emi_on = v_first, closed_on = v_closed,
           note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Loan not found.'; end if;
  end if;
  insert into public.business_profile (property_id, has_loan) values (p_property, true)
  on conflict (property_id) do update set has_loan = true, updated_at = now();
  return public.biz_summary(p_property);
end $$;

--
-- Name: biz_partner_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_partner_delete(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.business_partners where id = p_id;
  if v_prop is null then raise exception 'Partner not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.business_partners where id = p_id;          -- payouts go with them; their investments become "unassigned"
  return public.biz_summary(v_prop);
end $$;

--
-- Name: biz_partner_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_partner_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_phone text; v_share numeric; v_other numeric;
begin
  perform public._inv_owner(p_property);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the partner''s name.'; end if;
  v_share := nullif(p->>'share_pct', '')::numeric;
  if v_share is null or v_share <= 0 or v_share > 100 then raise exception 'Profit share should be between 1 and 100%%.'; end if;
  if coalesce((p->>'is_me')::boolean, false) and exists (select 1 from public.business_partners where property_id = p_property and is_me and id is distinct from v_id) then
    raise exception 'You are already in the list.';
  end if;
  select coalesce(sum(share_pct), 0) into v_other from public.business_partners where property_id = p_property and id is distinct from v_id;
  if v_other + v_share > 100 then raise exception 'Shares would add up to %, more than 100%%. Lower someone''s share first.', (v_other + v_share)::text || '%'; end if;
  v_phone := public._clean_phone(p->>'phone');
  if v_phone ~ '^[6-9][0-9]{9}$' then v_phone := '+91' || v_phone; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the phone number.'; end if;
  if v_id is null then
    insert into public.business_partners (property_id, name, phone, share_pct, is_me, note)
    values (p_property, btrim(p->>'name'), v_phone, v_share, coalesce((p->>'is_me')::boolean, false), nullif(btrim(p->>'note'), ''));
  else
    update public.business_partners set name = btrim(p->>'name'), phone = v_phone, share_pct = v_share, note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Partner not found.'; end if;
  end if;
  insert into public.business_profile (property_id, has_partners) values (p_property, true)
  on conflict (property_id) do update set has_partners = true, updated_at = now();
  return public.biz_summary(p_property);
end $_$;

--
-- Name: biz_payout_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_payout_delete(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.partner_payouts where id = p_id;
  if v_prop is null then raise exception 'Payout not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.partner_payouts where id = p_id;
  return public.biz_summary(v_prop);
end $$;

--
-- Name: biz_payout_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_payout_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_on date;
begin
  perform public._inv_owner(p_property);
  if not exists (select 1 from public.business_partners where id = (p->>'partner_id')::uuid and property_id = p_property) then raise exception 'Choose the partner.'; end if;
  if coalesce((p->>'amount_paise')::bigint, 0) < 100 then raise exception 'Enter the amount paid.'; end if;
  v_on := coalesce(nullif(p->>'paid_on', '')::date, public._inv_today(p_property));
  if v_on > public._inv_today(p_property) then raise exception 'The date can''t be in the future.'; end if;
  if v_id is null then
    insert into public.partner_payouts (property_id, partner_id, amount_paise, paid_on, note)
    values (p_property, (p->>'partner_id')::uuid, (p->>'amount_paise')::bigint, v_on, nullif(btrim(p->>'note'), ''));
  else
    update public.partner_payouts set amount_paise = (p->>'amount_paise')::bigint, paid_on = v_on, note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Payout not found.'; end if;
  end if;
  return public.biz_summary(p_property);
end $$;

--
-- Name: biz_profile_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_profile_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._inv_owner(p_property);
  insert into public.business_profile (property_id) values (p_property) on conflict do nothing;
  update public.business_profile set
    has_loan        = case when p ? 'has_loan' then (p->>'has_loan')::boolean else has_loan end,
    has_partners    = case when p ? 'has_partners' then (p->>'has_partners')::boolean else has_partners end,
    is_rented       = case when p ? 'is_rented' then (p->>'is_rented')::boolean else is_rented end,
    emi_in_expenses = case when p ? 'emi_in_expenses' then coalesce((p->>'emi_in_expenses')::boolean, false) else emi_in_expenses end,
    updated_at = now()
  where property_id = p_property;
  return public.biz_summary(p_property);
end $$;

--
-- Name: biz_remind_all(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_remind_all() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare pid uuid; n int := 0;
begin
  for pid in select property_id from public.business_loans where closed_on is null union select property_id from public.business_lease loop
    n := n + public._biz_notify(pid);
  end loop;
  return n;
end $$;

--
-- Name: biz_summary(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.biz_summary(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_today date; s jsonb; pr public.business_profile; l public.business_loans; v_loans jsonb := '[]'::jsonb; j jsonb;
  v_int_paid bigint := 0; v_int_month bigint := 0; v_owed bigint := 0; v_emi bigint := 0;
  v_inv bigint; v_rec bigint; v_real bigint; v_avg bigint; v_ravg bigint; v_left bigint; v_mleft int; v_be text;
  b public.business_lease; v_lease jsonb; v_verdict text; v_parts jsonb; v_share numeric; v_alerts jsonb := '[]'::jsonb;
begin
  perform public._inv_owner(p_property);
  v_today := public._inv_today(p_property);
  perform public._biz_notify(p_property);
  s := public.invest_summary(p_property);
  select * into pr from public.business_profile where property_id = p_property;

  for l in select * from public.business_loans where property_id = p_property order by first_emi_on, created_at loop
    j := public._biz_loan(l, v_today);
    v_loans := v_loans || j;
    v_int_paid := v_int_paid + (j->>'interest_paid_paise')::bigint;
    v_int_month := v_int_month + (j->>'interest_this_month_paise')::bigint;
    v_owed := v_owed + (j->>'outstanding_paise')::bigint;
    if not (j->>'done')::boolean then v_emi := v_emi + (j->>'emi_paise')::bigint; end if;
    if (j->>'next_emi_on') is not null and (j->>'next_emi_on')::date - v_today between 0 and 7 then
      v_alerts := v_alerts || jsonb_build_object('kind', 'emi', 'level', 'amber', 'text',
        format('EMI of %s to %s due %s', to_char((j->>'emi_paise')::bigint / 100.0, 'FM₹99,99,99,990'), l.lender, to_char((j->>'next_emi_on')::date, 'DD Mon')));
    end if;
  end loop;
  if coalesce(pr.emi_in_expenses, false) then v_int_paid := 0; v_int_month := 0; end if;

  -- payback after loan interest
  v_inv := (s->>'invested_paise')::bigint; v_rec := (s->>'recovered_paise')::bigint; v_avg := nullif(s->>'avg3_paise', '')::bigint;
  v_real := v_rec - v_int_paid;
  v_ravg := case when v_avg is null then null else v_avg - v_int_month end;
  v_left := greatest(v_inv - v_real, 0);
  v_mleft := case when v_inv > 0 and v_left > 0 and v_ravg > 0 then ceil(v_left::numeric / v_ravg)::int end;
  v_be := case when v_inv > 0 and v_left = 0 then 'done'
               when v_mleft is not null then to_char(date_trunc('month', v_today) + make_interval(months => v_mleft), 'YYYY-MM') end;

  -- lease
  select * into b from public.business_lease where property_id = p_property;
  if b.property_id is not null then
    v_lease := public._biz_lease(b, v_today);
    v_verdict := case when v_be = 'done' then 'done' when v_be is null then 'unknown'
                      when to_date(v_be, 'YYYY-MM') <= (b.end_on - interval '6 months') then 'ok'
                      when to_date(v_be, 'YYYY-MM') <= b.end_on then 'tight' else 'risk' end;
    v_lease := v_lease || jsonb_build_object('verdict', v_verdict);
    if coalesce(pr.is_rented, true) then
      if b.end_on - v_today between 0 and 180 then
        v_alerts := v_alerts || jsonb_build_object('kind', 'lease', 'level', case when b.end_on - v_today <= 60 then 'red' else 'amber' end,
          'text', format('Lease ends in %s days (%s). Talk to your landlord about renewing.', b.end_on - v_today, to_char(b.end_on, 'DD Mon YYYY')));
      end if;
      if v_verdict = 'risk' then
        v_alerts := v_alerts || jsonb_build_object('kind', 'lease_payback', 'level', 'red',
          'text', format('At this pace you break even around %s — after your lease ends (%s). Ask for a longer lease now.', to_char(to_date(v_be, 'YYYY-MM'), 'Mon YYYY'), to_char(b.end_on, 'Mon YYYY')));
      end if;
      if (v_lease->>'notice_by') is not null and (v_lease->>'notice_by')::date - v_today between 0 and 60 then
        v_alerts := v_alerts || jsonb_build_object('kind', 'notice', 'level', 'amber', 'text',
          format('Lease notice deadline %s — decide to renew or leave before then.', to_char((v_lease->>'notice_by')::date, 'DD Mon YYYY')));
      end if;
      if (v_lease->>'next_increase_on') is not null and (v_lease->>'next_increase_on')::date - v_today between 0 and 60 then
        v_alerts := v_alerts || jsonb_build_object('kind', 'rent_up', 'level', 'amber', 'text',
          format('Rent goes up on %s to about %s a month.', to_char((v_lease->>'next_increase_on')::date, 'DD Mon'), to_char((v_lease->>'next_rent_paise')::bigint / 100.0, 'FM₹99,99,99,990')));
      end if;
    end if;
  end if;

  -- partners
  select coalesce(sum(share_pct), 0) into v_share from public.business_partners where property_id = p_property;
  select coalesce(jsonb_agg(x.j order by x.is_me desc, x.created_at), '[]'::jsonb) into v_parts from (
    select bp.is_me, bp.created_at, jsonb_build_object('id', bp.id, 'name', bp.name, 'phone', bp.phone, 'share_pct', bp.share_pct, 'is_me', bp.is_me, 'note', bp.note,
      'invested_paise', coalesce((select sum(i.amount_paise) from public.investments i where i.property_id = p_property
                                    and (i.partner_id = bp.id or (bp.is_me and i.partner_id is null))), 0),
      'profit_share_paise', round(greatest(v_real, 0) * bp.share_pct / 100.0)::bigint,
      'paid_out_paise', coalesce((select sum(po.amount_paise) from public.partner_payouts po where po.partner_id = bp.id), 0),
      'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', po.id, 'amount_paise', po.amount_paise, 'paid_on', po.paid_on, 'note', po.note) order by po.paid_on desc)
                            from (select * from public.partner_payouts where partner_id = bp.id order by paid_on desc limit 24) po), '[]'::jsonb)) j
      from public.business_partners bp where bp.property_id = p_property) x;
  if jsonb_array_length(v_parts) > 0 and v_share <> 100 then
    v_alerts := v_alerts || jsonb_build_object('kind', 'shares', 'level', 'amber', 'text', format('Partner shares add up to %s%% — they should make 100%%.', v_share));
  end if;

  return jsonb_build_object(
    'today', v_today,
    'profile', jsonb_build_object('has_loan', pr.has_loan, 'has_partners', pr.has_partners, 'is_rented', pr.is_rented, 'emi_in_expenses', coalesce(pr.emi_in_expenses, false)),
    'payback', jsonb_build_object('invested_paise', v_inv, 'profit_paise', v_rec, 'interest_paid_paise', v_int_paid, 'real_recovered_paise', v_real,
       'real_pct', case when v_inv > 0 then round(greatest(v_real, 0) * 100.0 / v_inv, 1) end, 'real_left_paise', v_left,
       'avg3_paise', v_avg, 'interest_this_month_paise', v_int_month, 'real_avg3_paise', v_ravg, 'real_months_left', v_mleft, 'real_breakeven', v_be,
       'plain_breakeven', s->>'breakeven_month'),
    'loans', jsonb_build_object('items', v_loans, 'owed_paise', v_owed, 'emi_month_paise', v_emi, 'interest_paid_paise', v_int_paid),
    'partners', jsonb_build_object('items', v_parts, 'total_share', v_share,
       'unassigned_paise', case when exists (select 1 from public.business_partners where property_id = p_property and is_me) then 0
                                else coalesce((select sum(amount_paise) from public.investments where property_id = p_property and partner_id is null), 0) end,
       'paid_by', coalesce((select jsonb_object_agg(id, partner_id) from public.investments where property_id = p_property and partner_id is not null), '{}'::jsonb)),
    'lease', v_lease,
    'alerts', v_alerts);
end $$;

--
-- Name: business_health(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.business_health(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare
  v_role public.member_role; v_owner boolean; v_today date; v_from date; v_pfrom date; v_pto date;
  o record; op record; oy record; v_occ numeric; v_pocc numeric; v_yocc numeric;
  v_inc bigint; v_pinc bigint; v_exp bigint; v_exp_rows int; v_rev_n numeric; v_prev_n numeric;
  v_due bigint := 0; v_due_old bigint := 0; v_due_guests int := 0; v_pg_due bigint := 0;
  m record; v_ota_share numeric; v_comm bigint; v_inc90 bigint;
  v_cnt int; v_bad int; v_repeat numeric; v_guests int;
  v_docs int; v_exp_docs int; v_due_docs int; v_inv jsonb;
  areas jsonb := '[]'::jsonb; a jsonb; v_score numeric; v_wsum numeric := 0; v_sum numeric := 0; st text; tip text;
  v_actions jsonb; v_week date; v_trend jsonb; v_snap_score int;
begin
  if auth.uid() is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  select role into v_role from public.property_members where property_id = p_property and user_id = auth.uid();
  if v_role is null or v_role not in ('owner', 'manager') then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  v_owner := v_role = 'owner';
  v_today := (now() at time zone public._bh_tz(p_property))::date;
  v_from := v_today - 29; v_pfrom := v_today - 59; v_pto := v_today - 30;

  -- 1 occupancy
  o := public._bh_occ(p_property, v_from, v_today);
  op := public._bh_occ(p_property, v_pfrom, v_pto);
  oy := public._bh_occ(p_property, (v_from - interval '1 year')::date, (v_today - interval '1 year')::date);
  if o.available > 0 then
    v_occ := round(o.occupied * 100.0 / o.available, 1);
    v_pocc := case when op.available > 0 then round(op.occupied * 100.0 / op.available, 1) end;
    v_yocc := case when oy.available > 0 and oy.occupied > 0 then round(oy.occupied * 100.0 / oy.available, 1) end;
    st := case when v_occ >= 65 or (v_pocc is not null and v_occ >= v_pocc + 5) then 'green'
               when v_occ < 40 and (v_pocc is null or v_occ <= v_pocc) then 'red' else 'amber' end;
    areas := areas || public._bh_area('occupancy', 'Occupancy', st, v_occ || '%',
      'Last 30 days' || coalesce(' · previous 30 days ' || v_pocc || '%', '') || coalesce(' · same time last year ' || v_yocc || '%', ''),
      'Nights sold ÷ nights available (' || o.units || ' units × 30 nights), incl. OTA calendar blocks.',
      case when v_pocc is not null and v_occ < v_pocc then 'Occupancy is falling: run a weekday offer, refresh OTA photos and ask past guests to come back.'
           else 'Fill empty nights: open more OTAs, add weekday / long-stay discounts and share your booking link on WhatsApp.' end, 20);
  else
    areas := areas || public._bh_area('occupancy', 'Occupancy', 'unknown', '—', 'No rooms or beds set up', 'Needs rooms / beds.', 'Add your rooms or beds in Setup.', 20);
  end if;

  -- 2 pricing (owners and managers who see reports)
  v_inc := public._bh_income(p_property, v_from, v_today);
  v_pinc := public._bh_income(p_property, v_pfrom, v_pto);
  if v_owner then
    if o.available > 0 and (v_inc > 0 or v_pinc > 0) then
      v_rev_n := v_inc::numeric / o.available; v_prev_n := case when op.available > 0 then v_pinc::numeric / op.available end;
      st := case when v_prev_n is null or v_prev_n = 0 then (case when v_inc > 0 then 'amber' else 'unknown' end)
                 when v_rev_n >= v_prev_n * 1.03 then 'green' when v_rev_n >= v_prev_n * 0.95 then 'amber' else 'red' end;
      if o.full_nights >= 4 and st = 'green' then st := 'amber'; end if;
      areas := areas || public._bh_area('pricing', 'Pricing', st, '₹' || round(v_rev_n / 100) || ' / night',
        'Money received per available unit-night' || coalesce(', was ₹' || round(v_prev_n / 100), '') || ' · ' || o.full_nights || ' full nights in 30 days',
        'Money received in the last 30 days ÷ nights available.',
        case when o.full_nights >= 4 then 'You were full on ' || o.full_nights || ' nights — raise prices on those days (weekends, holidays).'
             else 'Earnings per night are slipping: check you aren’t discounting too much and add extras (breakfast, tours).' end, 10);
    else
      areas := areas || public._bh_area('pricing', 'Pricing', 'unknown', '—', 'No payments recorded yet', 'Needs payments.', 'Record payments in NammaStay so earnings per night can be tracked.', 10);
    end if;

    -- 3 profit
    select coalesce(sum(amount_paise), 0), count(*) into v_exp, v_exp_rows from public.expenses where property_id = p_property and spent_on between v_from and v_today;
    if v_exp_rows = 0 or v_inc <= 0 then
      areas := areas || public._bh_area('profit', 'Profit', 'unknown', '—', case when v_exp_rows = 0 then 'No expenses recorded in the last 30 days' else 'No income in the last 30 days' end,
        'Money received − expenses, last 30 days.', 'Add rent, salaries and bills in Expenses & profit — without them profit can’t be measured.', 20);
    else
      st := case when (v_inc - v_exp) * 100 >= v_inc * 25 then 'green' when (v_inc - v_exp) * 100 >= v_inc * 10 then 'amber' else 'red' end;
      areas := areas || public._bh_area('profit', 'Profit', st, round((v_inc - v_exp) * 100.0 / v_inc) || '% margin',
        '₹' || to_char(round((v_inc - v_exp) / 100.0), 'FM99,99,99,999') || ' profit on ₹' || to_char(round(v_inc / 100.0), 'FM99,99,99,999') || ' received (30 days)',
        '(Money received − expenses) ÷ money received, last 30 days.',
        'Margin is thin: look at your biggest expense categories and OTA commission; small price rises help most.', 20);
    end if;
  end if;

  -- 4 cash: unpaid dues
  select coalesce(sum(balance_paise), 0), coalesce(sum(balance_paise) filter (where status = 'checked_out' and check_out_at < now() - interval '7 days'), 0),
         count(distinct guest_id) filter (where balance_paise > 0)
    into v_due, v_due_old, v_due_guests
    from public.bookings where property_id = p_property and status in ('checked_in', 'checked_out') and balance_paise > 0;
  if to_regclass('public.pg_rent_dues') is not null then
    execute 'select coalesce(sum(amount_paise - paid_paise), 0) from public.pg_rent_dues where property_id = $1 and amount_paise > paid_paise and due_on < $2'
      into v_pg_due using p_property, v_today - 7;
  elsif to_regclass('public.rent_dues') is not null then
    execute 'select coalesce(sum(amount_paise - paid_paise - coalesce(credit_paise, 0)), 0) from public.rent_dues where property_id = $1 and amount_paise > paid_paise + coalesce(credit_paise, 0) and due_on < $2'
      into v_pg_due using p_property, v_today - 7;
  end if;
  v_due_old := v_due_old + greatest(v_pg_due, 0); v_due := v_due + greatest(v_pg_due, 0);
  st := case when v_due_old = 0 then 'green' when v_due_old * 20 <= greatest(v_inc, 1) then 'amber' else 'red' end;
  areas := areas || public._bh_area('cash', 'Unpaid dues', st, '₹' || to_char(round(v_due / 100.0), 'FM99,99,99,999'),
    case when v_due_old > 0 then '₹' || to_char(round(v_due_old / 100.0), 'FM99,99,99,999') || ' overdue more than 7 days' else 'Nothing overdue' end
      || case when v_due_guests > 0 then ' · ' || v_due_guests || ' guest' || case when v_due_guests > 1 then 's' else '' end || ' owe money' else '' end,
    'Balances of checked-in / checked-out bookings (and PG rent overdue 7+ days).',
    'Send WhatsApp payment reminders today and take advance payments at booking.', 15);

  -- 5 booking mix (last 90 days, nights)
  m := public._bh_occ(p_property, v_today - 89, v_today);
  if m.ota_nights + m.direct_nights > 0 then
    v_ota_share := round(m.ota_nights * 100.0 / (m.ota_nights + m.direct_nights));
    v_inc90 := public._bh_income(p_property, v_today - 89, v_today);
    select coalesce(sum(amount_paise), 0) into v_comm from public.expenses where property_id = p_property and category = 'ota_commission' and spent_on between v_today - 89 and v_today;
    st := case when v_ota_share <= 40 then 'green' when v_ota_share <= 65 then 'amber' else 'red' end;
    areas := areas || public._bh_area('mix', 'Direct vs OTA', st, v_ota_share || '% OTA',
      (100 - v_ota_share) || '% direct / walk-in nights (90 days)' || case when v_owner and v_comm > 0 and v_inc90 > 0 then ' · OTA commission ' || round(v_comm * 100.0 / v_inc90) || '% of income' else '' end,
      'OTA nights (OTA bookings + OTA calendar blocks) ÷ all sold nights, last 90 days.',
      'Most guests come through OTAs: give returning guests a direct-booking discount, add your WhatsApp / booking link to your Google profile.', 10);
  else
    areas := areas || public._bh_area('mix', 'Direct vs OTA', 'unknown', '—', 'No stays in the last 90 days', 'Needs bookings.', 'Add bookings or connect your OTA calendars.', 10);
  end if;

  -- 6 guests: cancellations / no-shows, repeat guests (bookings created in 90 days)
  select count(*), count(*) filter (where status in ('cancelled', 'no_show')) into v_cnt, v_bad
    from public.bookings where property_id = p_property and created_at >= now() - interval '90 days' and status <> 'pending';
  if v_cnt >= 5 then
    select count(distinct b.guest_id), count(distinct b.guest_id) filter (where exists (select 1 from public.bookings e where e.property_id = b.property_id
             and e.guest_id = b.guest_id and e.id <> b.id and e.status in ('checked_out', 'checked_in', 'confirmed')))
      into v_guests, v_cnt from public.bookings b where b.property_id = p_property and b.created_at >= now() - interval '90 days' and b.status in ('confirmed', 'checked_in', 'checked_out');
    v_repeat := case when v_guests > 0 then round(v_cnt * 100.0 / v_guests) end;
    select count(*) into v_cnt from public.bookings where property_id = p_property and created_at >= now() - interval '90 days' and status <> 'pending';
    st := case when v_bad * 100 <= v_cnt * 10 then 'green' when v_bad * 100 <= v_cnt * 20 then 'amber' else 'red' end;
    areas := areas || public._bh_area('guests', 'Cancellations & repeat guests', st, round(v_bad * 100.0 / v_cnt) || '% cancelled / no-show',
      v_bad || ' of ' || v_cnt || ' bookings (90 days)' || coalesce(' · ' || v_repeat || '% repeat guests', ''),
      'Cancelled + no-show ÷ bookings made in the last 90 days; repeat = guests who stayed before.',
      'Many cancellations: take a small advance, confirm 24 hours before arrival on WhatsApp.', 10);
  else
    areas := areas || public._bh_area('guests', 'Cancellations & repeat guests', 'unknown', '—', 'Fewer than 5 bookings in 90 days', 'Needs more bookings.', null, 10);
  end if;

  if v_owner then
    -- 7 compliance (036)
    if to_regclass('public.legal_documents') is not null then
      execute 'select count(*), count(*) filter (where expires_on < $2), count(*) filter (where expires_on between $2 and $2 + 30) from public.legal_documents where property_id = $1'
        into v_docs, v_exp_docs, v_due_docs using p_property, v_today;
      if v_docs = 0 then
        areas := areas || public._bh_area('compliance', 'Licences & documents', 'unknown', '—', 'No documents added', 'Documents in My investment → Legal documents.',
          'Add your licences with expiry dates (My investment → Legal documents) and go through the Licences checklist.', 10);
      else
        st := case when v_exp_docs > 0 then 'red' when v_due_docs > 0 then 'amber' else 'green' end;
        areas := areas || public._bh_area('compliance', 'Licences & documents', st,
          case when v_exp_docs > 0 then v_exp_docs || ' expired' when v_due_docs > 0 then v_due_docs || ' due soon' else 'All valid' end,
          v_docs || ' documents stored' || case when v_due_docs > 0 then ' · ' || v_due_docs || ' expire within 30 days' else '' end,
          'Expiry dates of documents in My investment → Legal documents.',
          'Renew expiring licences now — operating with an expired licence or fire NOC can bring fines or closure.', 10);
      end if;
    end if;
    -- 8 payback (036)
    if to_regprocedure('public.invest_summary(uuid)') is not null then
      execute 'select public.invest_summary($1)' into v_inv using p_property;
      if coalesce((v_inv->>'invested_paise')::bigint, 0) > 0 then
        st := case when (v_inv->>'remaining_paise')::bigint = 0 then 'green'
                   when v_inv->>'breakeven_month' is null then 'red'
                   when (v_inv->>'months_left')::int <= 36 then 'green' else 'amber' end;
        areas := areas || public._bh_area('payback', 'Payback', st, coalesce(floor((v_inv->>'pct')::numeric) || '% paid back', '—'),
          case when (v_inv->>'remaining_paise')::bigint = 0 then 'Investment fully recovered'
               when v_inv->>'breakeven_month' is not null then 'Break-even estimated ' || to_char(to_date(v_inv->>'breakeven_month', 'YYYY-MM'), 'Mon YYYY')
               else 'No break-even estimate yet (needs monthly profit)' end,
          'Profit since opening ÷ money invested (My investment).',
          'Payback is slow: improving occupancy, prices and dues above brings your break-even date closer.', 5);
      end if;
    end if;
  end if;

  -- score + top actions
  for a in select * from jsonb_array_elements(areas) loop
    if a->>'status' <> 'unknown' then
      v_wsum := v_wsum + (a->>'weight')::int;
      v_sum := v_sum + (a->>'weight')::int * case a->>'status' when 'green' then 100 when 'amber' then 60 else 25 end;
    end if;
  end loop;
  v_score := case when v_wsum > 0 then round(v_sum / v_wsum) end;
  if m.ota_nights + m.direct_nights = 0 and coalesce(v_inc, 0) = 0 then v_score := null; end if;   -- brand new: nothing to judge yet
  select coalesce(jsonb_agg(jsonb_build_object('area', x->>'key', 'status', x->>'status', 'text', x->>'tip')
           order by case x->>'status' when 'red' then 0 when 'amber' then 1 else 2 end, (x->>'weight')::int desc), '[]'::jsonb)
    into v_actions from (select x from jsonb_array_elements(areas) x where x->>'tip' is not null limit 20) t;
  v_actions := (select coalesce(jsonb_agg(e), '[]'::jsonb) from (select e from jsonb_array_elements(v_actions) e limit 3) t);

  -- weekly snapshot (owner view only) + Monday summary in the bell
  v_week := date_trunc('week', v_today)::date;
  if v_owner and v_score is not null then
    insert into public.business_health_snapshots (property_id, week_start, score, areas)
    values (p_property, v_week, v_score::int, (select jsonb_object_agg(x->>'key', x->>'status') from jsonb_array_elements(areas) x))
    on conflict (property_id, week_start) do update set score = excluded.score, areas = excluded.areas, updated_at = now();
    if not exists (select 1 from public.notifications where property_id = p_property and kind = 'health_weekly' and created_at >= v_week) then
      insert into public.notifications (property_id, user_id, kind, title, body)
      select p_property, pm.user_id, 'health_weekly', 'Business health this week: ' || v_score::int || '/100',
             coalesce('Top action: ' || (v_actions->0->>'text'), 'All areas look good — keep it up!')
        from public.property_members pm where pm.property_id = p_property and pm.role = 'owner';
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('week_start', week_start, 'score', score) order by week_start), '[]'::jsonb) into v_trend
    from (select week_start, score from public.business_health_snapshots where property_id = p_property order by week_start desc limit 26) t;

  return jsonb_build_object('view', case when v_owner then 'owner' else 'operations' end, 'today', v_today, 'from', v_from,
    'score', v_score::int, 'label', case when v_score is null then 'Not enough data' when v_score >= 75 then 'Healthy' when v_score >= 55 then 'Needs attention' else 'At risk' end,
    'areas', areas, 'actions', v_actions, 'trend', case when v_owner then v_trend else '[]'::jsonb end);
end $_$;

--
-- Name: invest_settings_save(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.invest_settings_save(p_property uuid, p_opened_on date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._inv_owner(p_property);
  if p_opened_on is null or p_opened_on > public._inv_today(p_property) then raise exception 'Choose the date your property opened (not in the future).'; end if;
  if p_opened_on < date '1990-01-01' then raise exception 'That opening date looks wrong.'; end if;
  insert into public.investment_settings (property_id, opened_on) values (p_property, p_opened_on)
  on conflict (property_id) do update set opened_on = excluded.opened_on, updated_at = now();
  return jsonb_build_object('opened_on', p_opened_on);
end $$;

--
-- Name: invest_summary(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.invest_summary(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_open date; v_today date; v_total bigint; v_rec bigint := 0; v_cum bigint := 0;
  v_months jsonb := '[]'::jsonb; v_ms jsonb := '[]'::jsonb; r record;
  v_first_profit date; v_lakh date; v_hit date[] := array[null,null,null,null,null]::date[];
  v_pcts int[] := array[10,25,50,75,100]; i int; v_avg bigint; v_left bigint; v_mleft int; v_est date;
  v_best record; v_first_booking date; v_g100 date; v_g1000 date; v_next text := null;
begin
  perform public._inv_owner(p_property);
  perform public._legal_docs_notify(p_property);
  v_open := public._inv_opened_on(p_property);
  v_today := public._inv_today(p_property);
  select coalesce(sum(amount_paise), 0) into v_total from public.investments where property_id = p_property;

  for r in select * from public._inv_months(p_property, v_open) loop
    v_cum := v_cum + (r.revenue_paise - r.expenses_paise);
    v_months := v_months || jsonb_build_object('month', to_char(r.month, 'YYYY-MM'), 'revenue_paise', r.revenue_paise,
                  'expenses_paise', r.expenses_paise, 'profit_paise', r.revenue_paise - r.expenses_paise, 'cumulative_paise', v_cum);
    if v_first_profit is null and r.revenue_paise - r.expenses_paise > 0 then v_first_profit := r.month; end if;
    if v_lakh is null and r.revenue_paise >= 10000000 then v_lakh := r.month; end if;
    if v_total > 0 then
      for i in 1..5 loop
        if v_hit[i] is null and v_cum * 100 >= v_total * v_pcts[i] then v_hit[i] := r.month; end if;
      end loop;
    end if;
  end loop;
  v_rec := v_cum;

  -- average profit of the last 3 complete months (this month is still running)
  select round(avg(profit))::bigint into v_avg from (
    select (x->>'profit_paise')::bigint profit from jsonb_array_elements(v_months) x
     where (x->>'month') < to_char(v_today, 'YYYY-MM') order by x->>'month' desc limit 3) t;
  v_left := greatest(v_total - v_rec, 0);
  if v_total > 0 and v_left > 0 and coalesce(v_avg, 0) > 0 then
    v_mleft := ceil(v_left::numeric / v_avg)::int;
    v_est := (date_trunc('month', v_today) + make_interval(months => v_mleft))::date;
  end if;

  select x->>'month' as month, (x->>'profit_paise')::bigint as profit into v_best
    from jsonb_array_elements(v_months) x order by (x->>'profit_paise')::bigint desc limit 1;

  select min(check_in_at)::date into v_first_booking from public.bookings
   where property_id = p_property and status not in ('cancelled');
  select created_at::date into v_g100 from public.guests where property_id = p_property order by created_at offset 99 limit 1;
  select created_at::date into v_g1000 from public.guests where property_id = p_property order by created_at offset 999 limit 1;

  v_ms := jsonb_build_array(
    jsonb_build_object('key','first_booking','title','First booking','achieved_on',v_first_booking),
    jsonb_build_object('key','first_profit','title','First month in profit','achieved_on',v_first_profit),
    jsonb_build_object('key','lakh_month','title','First ₹1 lakh month','achieved_on',v_lakh),
    jsonb_build_object('key','p10','title','10% paid back','achieved_on',v_hit[1],'pct',10),
    jsonb_build_object('key','p25','title','25% paid back','achieved_on',v_hit[2],'pct',25),
    jsonb_build_object('key','guests_100','title','100 guests','achieved_on',v_g100),
    jsonb_build_object('key','p50','title','Half way: 50% paid back','achieved_on',v_hit[3],'pct',50),
    jsonb_build_object('key','guests_1000','title','1,000 guests','achieved_on',v_g1000),
    jsonb_build_object('key','p75','title','75% paid back','achieved_on',v_hit[4],'pct',75),
    jsonb_build_object('key','p100','title','Break-even!','achieved_on',v_hit[5],'pct',100));
  if v_total > 0 then
    for i in 1..5 loop
      if v_hit[i] is null then v_next := 'p' || v_pcts[i]; exit; end if;
    end loop;
  end if;

  return jsonb_build_object(
    'opened_on', v_open, 'opened_set', exists (select 1 from public.investment_settings where property_id = p_property),
    'today', v_today,
    'invested_paise', v_total,
    'recovered_paise', v_rec,
    'remaining_paise', v_left,
    'pct', case when v_total > 0 then round(greatest(v_rec, 0) * 100.0 / v_total, 1) else null end,
    'avg3_paise', v_avg,
    'months_left', v_mleft,
    'breakeven_month', case when v_total > 0 and v_left = 0 then to_char(v_hit[5], 'YYYY-MM') else to_char(v_est, 'YYYY-MM') end,
    'best_month', case when v_best.month is not null and v_best.profit > 0 then jsonb_build_object('month', v_best.month, 'profit_paise', v_best.profit) end,
    'months', v_months,
    'milestones', v_ms,
    'next', v_next,
    'next_needed_paise', case when v_next is not null then greatest(ceil(v_total * substr(v_next, 2)::int / 100.0)::bigint - v_rec, 0) end,
    'expenses_this_month', exists (select 1 from public.expenses where property_id = p_property and spent_on >= date_trunc('month', v_today)::date),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'note', note, 'amount_paise', amount_paise,
                'invested_on', invested_on) order by invested_on, created_at), '[]'::jsonb) from public.investments where property_id = p_property));
end $$;

--
-- Name: investment_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.investment_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.investments where id = p_id;
  if v_prop is null then raise exception 'Investment not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.investments where id = p_id;
end $$;

--
-- Name: investment_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.investment_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := (p->>'amount_paise')::bigint; v_on date := nullif(p->>'invested_on', '')::date;
  v_title text := btrim(coalesce(p->>'title', '')); r public.investments;
begin
  perform public._inv_owner(p_property);
  if v_title = '' then raise exception 'Give the investment a name (e.g. Interiors, Beds).'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter the amount invested.'; end if;
  if v_on is null then v_on := public._inv_today(p_property); end if;
  if v_on > public._inv_today(p_property) then raise exception 'The date can''t be in the future.'; end if;
  if v_id is null then
    insert into public.investments (property_id, title, note, amount_paise, invested_on)
    values (p_property, v_title, nullif(btrim(p->>'note'), ''), v_amt, v_on) returning * into r;
  else
    update public.investments set title = v_title, note = nullif(btrim(p->>'note'), ''), amount_paise = v_amt, invested_on = v_on
     where id = v_id and property_id = p_property returning * into r;
    if r.id is null then raise exception 'Investment not found.'; end if;
  end if;
  return to_jsonb(r);
end $$;

--
-- Name: legal_checklist_get(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_checklist_get(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._inv_owner(p_property);
  return jsonb_build_object(
    'state_code', coalesce((select state_code from public.investment_settings where property_id = p_property),
                           (select nullif(bill_state, '') from public.properties where id = p_property)),
    'kind', (select checklist_kind from public.investment_settings where property_id = p_property),
    'marks', (select coalesce(jsonb_object_agg(item_key, status), '{}'::jsonb) from public.legal_checklist where property_id = p_property),
    'doc_types', (select coalesce(jsonb_agg(distinct doc_type), '[]'::jsonb) from public.legal_documents where property_id = p_property));
end $$;

--
-- Name: legal_checklist_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_checklist_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_key text := nullif(p->>'item_key', ''); v_status text := nullif(p->>'status', '');
begin
  perform public._inv_owner(p_property);
  if p ? 'state_code' or p ? 'kind' then
    if p ? 'state_code' and nullif(p->>'state_code', '') !~ '^[0-9]{2}$' then raise exception 'Choose your state.'; end if;
    if p ? 'kind' and coalesce(p->>'kind', '') not in ('hostel','homestay','pg','hotel','resort') then raise exception 'Choose the property type.'; end if;
    insert into public.investment_settings (property_id, opened_on, state_code, checklist_kind)
    values (p_property, public._inv_opened_on(p_property), nullif(p->>'state_code', ''), nullif(p->>'kind', ''))
    on conflict (property_id) do update set
      state_code = case when p ? 'state_code' then excluded.state_code else investment_settings.state_code end,
      checklist_kind = case when p ? 'kind' then excluded.checklist_kind else investment_settings.checklist_kind end,
      updated_at = now();
  end if;
  if v_key is not null then
    if v_key !~ '^[a-z0-9_]{1,40}$' then raise exception 'Unknown checklist item.'; end if;
    if v_status is null then
      delete from public.legal_checklist where property_id = p_property and item_key = v_key;
    elsif v_status in ('not_needed','done') then
      insert into public.legal_checklist (property_id, item_key, status) values (p_property, v_key, v_status)
      on conflict (property_id, item_key) do update set status = excluded.status, updated_at = now();
    else raise exception 'Unknown status.'; end if;
  end if;
  return public.legal_checklist_get(p_property);
end $_$;

--
-- Name: legal_doc_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_doc_delete(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare d public.legal_documents;
begin
  select * into d from public.legal_documents where id = p_id;
  if d.id is null then raise exception 'Document not found.'; end if;
  perform public._inv_owner(d.property_id);
  delete from public.legal_documents where id = p_id;
  return jsonb_build_object('file_path', d.file_path);   -- the app removes the file from storage
end $$;

--
-- Name: legal_doc_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_doc_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_path text := nullif(p->>'file_path', ''); v_exp date := nullif(p->>'expires_on', '')::date;
  v_iss date := nullif(p->>'issued_on', '')::date; v_title text := btrim(coalesce(p->>'title', '')); r public.legal_documents; old public.legal_documents;
begin
  perform public._inv_owner(p_property);
  if v_title = '' then raise exception 'Give the document a name.'; end if;
  if v_exp is not null and v_iss is not null and v_exp < v_iss then raise exception 'The expiry date is before the issue date.'; end if;
  if v_path is not null and (v_path not like p_property::text || '/%' or v_path like '%..%') then raise exception 'File not allowed.'; end if;
  if v_id is null then
    insert into public.legal_documents (property_id, doc_type, title, doc_number, issued_on, expires_on, note, file_path, file_name, file_size)
    values (p_property, coalesce(nullif(p->>'doc_type', ''), 'other'), v_title, nullif(btrim(p->>'doc_number'), ''), v_iss, v_exp,
            nullif(btrim(p->>'note'), ''), v_path, nullif(p->>'file_name', ''), nullif(p->>'file_size', '')::int)
    returning * into r;
  else
    select * into old from public.legal_documents where id = v_id and property_id = p_property;
    if old.id is null then raise exception 'Document not found.'; end if;
    update public.legal_documents set doc_type = coalesce(nullif(p->>'doc_type', ''), doc_type), title = v_title,
           doc_number = nullif(btrim(p->>'doc_number'), ''), issued_on = v_iss, expires_on = v_exp, note = nullif(btrim(p->>'note'), ''),
           file_path = case when p ? 'file_path' then v_path else file_path end,
           file_name = case when p ? 'file_path' then nullif(p->>'file_name', '') else file_name end,
           file_size = case when p ? 'file_path' then nullif(p->>'file_size', '')::int else file_size end,
           reminded_level = case when expires_on is distinct from v_exp then 0 else reminded_level end,   -- renewed: reminders start again
           updated_at = now()
     where id = v_id returning * into r;
  end if;
  return jsonb_build_object('id', r.id, 'old_file_path', case when old.id is not null and old.file_path is distinct from r.file_path then old.file_path end);
end $$;

--
-- Name: legal_docs_alerts(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_docs_alerts(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_today date;
begin
  if not exists (select 1 from public.property_members where property_id = p_property and user_id = auth.uid() and role = 'owner') then
    return jsonb_build_object('count', 0, 'items', '[]'::jsonb);
  end if;
  perform public._legal_docs_notify(p_property);
  v_today := public._inv_today(p_property);
  return (select jsonb_build_object('count', count(*), 'items', coalesce(jsonb_agg(jsonb_build_object('title', title, 'expires_on', expires_on,
            'days_left', expires_on - v_today) order by expires_on) filter (where rn <= 3), '[]'::jsonb))
          from (select title, expires_on, row_number() over (order by expires_on) rn from public.legal_documents
                 where property_id = p_property and expires_on is not null and expires_on - v_today <= 30) t);
end $$;

--
-- Name: legal_docs_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_docs_list(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_today date;
begin
  perform public._inv_owner(p_property);
  perform public._legal_docs_notify(p_property);
  v_today := public._inv_today(p_property);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'doc_type', d.doc_type, 'title', d.title, 'doc_number', d.doc_number,
            'issued_on', d.issued_on, 'expires_on', d.expires_on, 'note', d.note, 'file_path', d.file_path, 'file_name', d.file_name,
            'file_size', d.file_size, 'days_left', d.expires_on - v_today,
            'status', case when d.expires_on is null then 'no_expiry' when d.expires_on < v_today then 'expired'
                           when d.expires_on - v_today <= 30 then 'due' else 'valid' end)
          order by (d.expires_on is null), d.expires_on, d.title), '[]'::jsonb)
          from public.legal_documents d where d.property_id = p_property);
end $$;

--
-- Name: legal_docs_remind_all(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legal_docs_remind_all() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare r record; n int := 0;
begin
  for r in select distinct property_id from public.legal_documents where expires_on is not null loop
    n := n + public._legal_docs_notify(r.property_id);
  end loop;
  return n;
end $$;

--
-- Name: business_health_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_health_snapshots (
    property_id uuid NOT NULL,
    week_start date NOT NULL,
    score integer,
    areas jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT business_health_snapshots_score_check CHECK (((score >= 0) AND (score <= 100)))
);

--
-- Name: business_partners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_partners (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    phone text,
    share_pct numeric(5,2) NOT NULL,
    is_me boolean DEFAULT false NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT business_partners_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 60))),
    CONSTRAINT business_partners_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT business_partners_phone_check CHECK (((phone IS NULL) OR (phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT business_partners_share_pct_check CHECK (((share_pct > (0)::numeric) AND (share_pct <= (100)::numeric)))
);

--
-- Name: business_profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_profile (
    property_id uuid NOT NULL,
    has_loan boolean,
    has_partners boolean,
    is_rented boolean,
    emi_in_expenses boolean DEFAULT false NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: business_reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_reminders (
    property_id uuid NOT NULL,
    key text NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: investment_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investment_settings (
    property_id uuid NOT NULL,
    opened_on date NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    state_code text,
    checklist_kind text,
    CONSTRAINT investment_settings_checklist_kind_check CHECK ((checklist_kind = ANY (ARRAY['hostel'::text, 'homestay'::text, 'pg'::text, 'hotel'::text, 'resort'::text]))),
    CONSTRAINT investment_settings_state_code_check CHECK ((state_code ~ '^[0-9]{2}$'::text))
);

--
-- Name: investments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    title text NOT NULL,
    note text,
    amount_paise bigint NOT NULL,
    invested_on date NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    partner_id uuid,
    CONSTRAINT investments_amount_paise_check CHECK (((amount_paise > 0) AND (amount_paise <= '100000000000'::bigint))),
    CONSTRAINT investments_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT investments_title_check CHECK (((char_length(btrim(title)) >= 1) AND (char_length(btrim(title)) <= 80)))
);

--
-- Name: legal_checklist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_checklist (
    property_id uuid NOT NULL,
    item_key text NOT NULL,
    status text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT legal_checklist_item_key_check CHECK ((item_key ~ '^[a-z0-9_]{1,40}$'::text)),
    CONSTRAINT legal_checklist_status_check CHECK ((status = ANY (ARRAY['not_needed'::text, 'done'::text])))
);

--
-- Name: legal_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    doc_type text NOT NULL,
    title text NOT NULL,
    doc_number text,
    issued_on date,
    expires_on date,
    note text,
    file_path text,
    file_name text,
    file_size integer,
    reminded_level smallint DEFAULT 0 NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT legal_documents_check CHECK (((expires_on IS NULL) OR (issued_on IS NULL) OR (expires_on >= issued_on))),
    CONSTRAINT legal_documents_doc_number_check CHECK ((char_length(doc_number) <= 60)),
    CONSTRAINT legal_documents_doc_type_check CHECK ((doc_type = ANY (ARRAY['trade_licence'::text, 'fire_noc'::text, 'fssai'::text, 'gst'::text, 'police'::text, 'tourism'::text, 'rental_agreement'::text, 'lease_deed'::text, 'insurance'::text, 'building_approval'::text, 'pollution'::text, 'partnership'::text, 'other'::text, 'shops_establishment'::text, 'professional_tax'::text, 'frro'::text, 'music'::text, 'liquor'::text, 'lift'::text, 'labour'::text, 'hostel_licence'::text, 'environment'::text, 'classification'::text, 'rwa_noc'::text]))),
    CONSTRAINT legal_documents_file_name_check CHECK ((char_length(file_name) <= 160)),
    CONSTRAINT legal_documents_file_path_check CHECK ((char_length(file_path) <= 300)),
    CONSTRAINT legal_documents_file_size_check CHECK (((file_size >= 0) AND (file_size <= 10485760))),
    CONSTRAINT legal_documents_note_check CHECK ((char_length(note) <= 300)),
    CONSTRAINT legal_documents_title_check CHECK (((char_length(btrim(title)) >= 1) AND (char_length(btrim(title)) <= 80)))
);

--
-- Name: partner_payouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partner_payouts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    partner_id uuid NOT NULL,
    amount_paise bigint NOT NULL,
    paid_on date NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT partner_payouts_amount_paise_check CHECK (((amount_paise >= 100) AND (amount_paise <= '100000000000'::bigint))),
    CONSTRAINT partner_payouts_note_check CHECK ((char_length(note) <= 200))
);

--
-- Name: business_health_snapshots business_health_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_health_snapshots
    ADD CONSTRAINT business_health_snapshots_pkey PRIMARY KEY (property_id, week_start);

--
-- Name: business_lease business_lease_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_lease
    ADD CONSTRAINT business_lease_pkey PRIMARY KEY (property_id);

--
-- Name: business_loans business_loans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_loans
    ADD CONSTRAINT business_loans_pkey PRIMARY KEY (id);

--
-- Name: business_partners business_partners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_partners
    ADD CONSTRAINT business_partners_pkey PRIMARY KEY (id);

--
-- Name: business_profile business_profile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_profile
    ADD CONSTRAINT business_profile_pkey PRIMARY KEY (property_id);

--
-- Name: business_reminders business_reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_reminders
    ADD CONSTRAINT business_reminders_pkey PRIMARY KEY (property_id, key);

--
-- Name: investment_settings investment_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investment_settings
    ADD CONSTRAINT investment_settings_pkey PRIMARY KEY (property_id);

--
-- Name: investments investments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments
    ADD CONSTRAINT investments_pkey PRIMARY KEY (id);

--
-- Name: legal_checklist legal_checklist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_checklist
    ADD CONSTRAINT legal_checklist_pkey PRIMARY KEY (property_id, item_key);

--
-- Name: legal_documents legal_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents
    ADD CONSTRAINT legal_documents_pkey PRIMARY KEY (id);

--
-- Name: partner_payouts partner_payouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partner_payouts
    ADD CONSTRAINT partner_payouts_pkey PRIMARY KEY (id);

--
-- Name: business_loans_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX business_loans_property ON public.business_loans USING btree (property_id);

--
-- Name: business_partners_one_me; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX business_partners_one_me ON public.business_partners USING btree (property_id) WHERE is_me;

--
-- Name: business_partners_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX business_partners_property ON public.business_partners USING btree (property_id);

--
-- Name: investments_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX investments_property ON public.investments USING btree (property_id, invested_on);

--
-- Name: legal_documents_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX legal_documents_property ON public.legal_documents USING btree (property_id, expires_on);

--
-- Name: partner_payouts_partner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX partner_payouts_partner ON public.partner_payouts USING btree (partner_id, paid_on);

--
-- Name: business_health_snapshots business_health_snapshots_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_health_snapshots
    ADD CONSTRAINT business_health_snapshots_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: business_lease business_lease_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_lease
    ADD CONSTRAINT business_lease_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: business_loans business_loans_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_loans
    ADD CONSTRAINT business_loans_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: business_partners business_partners_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_partners
    ADD CONSTRAINT business_partners_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: business_profile business_profile_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_profile
    ADD CONSTRAINT business_profile_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: business_reminders business_reminders_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_reminders
    ADD CONSTRAINT business_reminders_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: investment_settings investment_settings_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investment_settings
    ADD CONSTRAINT investment_settings_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: investments investments_partner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments
    ADD CONSTRAINT investments_partner_id_fkey FOREIGN KEY (partner_id) REFERENCES public.business_partners(id) ON DELETE SET NULL;

--
-- Name: investments investments_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investments
    ADD CONSTRAINT investments_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: legal_checklist legal_checklist_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_checklist
    ADD CONSTRAINT legal_checklist_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: legal_documents legal_documents_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_documents
    ADD CONSTRAINT legal_documents_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: partner_payouts partner_payouts_partner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partner_payouts
    ADD CONSTRAINT partner_payouts_partner_id_fkey FOREIGN KEY (partner_id) REFERENCES public.business_partners(id) ON DELETE CASCADE;

--
-- Name: partner_payouts partner_payouts_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partner_payouts
    ADD CONSTRAINT partner_payouts_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: business_health_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_health_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: business_lease; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_lease ENABLE ROW LEVEL SECURITY;

--
-- Name: business_loans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_loans ENABLE ROW LEVEL SECURITY;

--
-- Name: business_partners; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_partners ENABLE ROW LEVEL SECURITY;

--
-- Name: business_profile; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_profile ENABLE ROW LEVEL SECURITY;

--
-- Name: business_reminders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_reminders ENABLE ROW LEVEL SECURITY;

--
-- Name: investment_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.investment_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: investments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.investments ENABLE ROW LEVEL SECURITY;

--
-- Name: legal_checklist; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.legal_checklist ENABLE ROW LEVEL SECURITY;

--
-- Name: legal_documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.legal_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: partner_payouts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.partner_payouts ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION _bh_area(p_key text, p_title text, p_status text, p_value text, p_detail text, p_how text, p_tip text, p_weight integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._bh_area(p_key text, p_title text, p_status text, p_value text, p_detail text, p_how text, p_tip text, p_weight integer) FROM PUBLIC;

--
-- Name: FUNCTION _bh_income(p_property uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._bh_income(p_property uuid, p_from date, p_to date) FROM PUBLIC;

--
-- Name: FUNCTION _bh_occ(p_property uuid, p_from date, p_to date, OUT units integer, OUT available bigint, OUT occupied bigint, OUT full_nights integer, OUT ota_nights bigint, OUT direct_nights bigint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._bh_occ(p_property uuid, p_from date, p_to date, OUT units integer, OUT available bigint, OUT occupied bigint, OUT full_nights integer, OUT ota_nights bigint, OUT direct_nights bigint) FROM PUBLIC;

--
-- Name: FUNCTION _bh_tz(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._bh_tz(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _biz_lease(b public.business_lease, p_today date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._biz_lease(b public.business_lease, p_today date) FROM PUBLIC;

--
-- Name: FUNCTION _biz_loan(l public.business_loans, p_today date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._biz_loan(l public.business_loans, p_today date) FROM PUBLIC;

--
-- Name: FUNCTION _biz_months(p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._biz_months(p_from date, p_to date) FROM PUBLIC;

--
-- Name: FUNCTION _biz_notify(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._biz_notify(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _biz_remind(p_property uuid, p_key text, p_title text, p_body text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._biz_remind(p_property uuid, p_key text, p_title text, p_body text) FROM PUBLIC;

--
-- Name: FUNCTION _inv_months(p_property uuid, p_from date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._inv_months(p_property uuid, p_from date) FROM PUBLIC;

--
-- Name: FUNCTION _inv_opened_on(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._inv_opened_on(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _inv_owner(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._inv_owner(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _inv_today(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._inv_today(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _legal_docs_notify(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._legal_docs_notify(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION biz_investment_partner(p_investment uuid, p_partner uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_investment_partner(p_investment uuid, p_partner uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_investment_partner(p_investment uuid, p_partner uuid) TO authenticated;

--
-- Name: FUNCTION biz_lease_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_lease_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_lease_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION biz_loan_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_loan_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_loan_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION biz_loan_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_loan_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_loan_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION biz_partner_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_partner_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_partner_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION biz_partner_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_partner_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_partner_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION biz_payout_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_payout_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_payout_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION biz_payout_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_payout_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_payout_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION biz_profile_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_profile_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_profile_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION biz_remind_all(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_remind_all() FROM PUBLIC;

--
-- Name: FUNCTION biz_summary(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.biz_summary(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.biz_summary(p_property uuid) TO authenticated;

--
-- Name: FUNCTION business_health(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.business_health(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.business_health(p_property uuid) TO authenticated;

--
-- Name: FUNCTION invest_settings_save(p_property uuid, p_opened_on date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.invest_settings_save(p_property uuid, p_opened_on date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invest_settings_save(p_property uuid, p_opened_on date) TO authenticated;

--
-- Name: FUNCTION invest_summary(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.invest_summary(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invest_summary(p_property uuid) TO authenticated;

--
-- Name: FUNCTION investment_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.investment_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.investment_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION investment_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.investment_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.investment_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION legal_checklist_get(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legal_checklist_get(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legal_checklist_get(p_property uuid) TO authenticated;

--
-- Name: FUNCTION legal_checklist_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legal_checklist_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legal_checklist_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION legal_doc_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legal_doc_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legal_doc_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION legal_doc_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legal_doc_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legal_doc_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION legal_docs_alerts(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legal_docs_alerts(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legal_docs_alerts(p_property uuid) TO authenticated;

--
-- Name: FUNCTION legal_docs_list(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legal_docs_list(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legal_docs_list(p_property uuid) TO authenticated;

--
-- Name: FUNCTION legal_docs_remind_all(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legal_docs_remind_all() FROM PUBLIC;

-- ---------------------------------------------------------------- storage, realtime & default rows
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values ('owner-docs', 'owner-docs', false, 10485760, array['application/pdf','image/jpeg','image/png','image/webp']) on conflict (id) do nothing;

drop policy if exists "owner-docs: owner delete" on storage.objects;
create policy "owner-docs: owner delete" on storage.objects for delete to authenticated
  using (((bucket_id = 'owner-docs'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));

drop policy if exists "owner-docs: owner read" on storage.objects;
create policy "owner-docs: owner read" on storage.objects for select to authenticated
  using (((bucket_id = 'owner-docs'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));

drop policy if exists "owner-docs: owner upload" on storage.objects;
create policy "owner-docs: owner upload" on storage.objects for insert to authenticated
  with check (((bucket_id = 'owner-docs'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));
