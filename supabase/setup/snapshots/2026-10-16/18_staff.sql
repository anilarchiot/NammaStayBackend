-- =====================================================================
-- NammaStay · staff
-- Staff (pack 042): attendance, shifts, salary, leave, documents  -- NOT INTEGRATED YET, hold back
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
-- Name: _st_busy(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_busy(p_property uuid, p_day date) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select case when b.n = 0 then 0 else round(100.0 * (
           select count(*) from public.bookings k where k.property_id = p_property and k.status in ('pending', 'confirmed', 'checked_in', 'checked_out')
              and k.stay @> ((p_day + time '20:00') at time zone public._st_tz(p_property))) / b.n)::int end
    from (select count(*) n from public.beds where property_id = p_property and is_active) b
$$;

--
-- Name: _st_can_salary(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_can_salary(p_property uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select exists (select 1 from public.property_members m where m.property_id = p_property and m.user_id = auth.uid()
                   and (m.role = 'owner' or (m.role = 'manager' and coalesce((select managers_see_salary from public.staff_settings s where s.property_id = p_property), false))))
$$;

--
-- Name: _st_check(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_check(p_property uuid, p_owner_only boolean) RETURNS public.member_role
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  return public._assert_role(p_property, case when p_owner_only then array['owner']::public.member_role[] else array['owner', 'manager']::public.member_role[] end);
end $$;

--
-- Name: _st_client_key(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_client_key() RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare h json; ip text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  ip := coalesce(h->>'cf-connecting-ip', split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1), h->>'x-real-ip');
  return md5('nammastay-staff:' || coalesce(nullif(btrim(ip), ''), 'unknown'));
end $$;

--
-- Name: _st_day(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_day(p_staff uuid, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare m public.staff_members; a public.staff_attendance; sh public.staff_shifts; v_tz text; v_today date; v_lv text; v_status text; v_start timestamptz;
        v_late int;
begin
  select * into m from public.staff_members where id = p_staff;
  v_tz := public._st_tz(m.property_id); v_today := (now() at time zone v_tz)::date;
  select * into sh from public.staff_shifts where id = public._st_shift(p_staff, p_day);
  select * into a from public.staff_attendance where staff_id = p_staff and day = p_day;
  select kind into v_lv from public.staff_leave where staff_id = p_staff and status = 'approved' and p_day between date_from and date_to limit 1;
  v_start := case when sh.id is not null then (p_day + sh.starts) at time zone v_tz end;
  select late_after_min into v_late from public.staff_settings where property_id = m.property_id;
  v_status := case
    when (m.joined_on is not null and p_day < m.joined_on) or (m.left_on is not null and p_day > m.left_on) then 'not_employed'
    when a.staff_id is not null then a.status
    when v_lv is not null then 'leave'
    when not public._st_works(p_staff, p_day) then 'off'
    when m.live_in and p_day <= v_today then 'present'
    when p_day < v_today then 'absent'
    when p_day = v_today and (v_start is null or now() < v_start + make_interval(mins => coalesce(v_late, 15))) then 'later'
    when p_day = v_today then 'not_in'
    else 'upcoming' end;
  return jsonb_build_object('day', p_day, 'status', v_status, 'leave_kind', v_lv,
    'shift_id', sh.id, 'shift', sh.name, 'starts', sh.starts, 'ends', sh.ends,
    'in_at', a.in_at, 'out_at', a.out_at, 'source', a.source, 'note', a.note,
    'late_min', case when a.in_at is not null and v_start is not null then greatest(0, floor(extract(epoch from a.in_at - v_start) / 60))::int end);
end $$;

--
-- Name: _st_salary(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_salary(p_staff uuid, p_month date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare m public.staff_members; v_m0 date := date_trunc('month', p_month)::date; v_m1 date; v_days int; d date; x jsonb;
        v_work numeric := 0; v_absent numeric := 0; v_unpaid numeric := 0; v_out numeric := 0; v_hours numeric := 0; v_paid numeric := 0;
        v_gross bigint := 0; v_ded bigint := 0; v_adv_due bigint; v_adv bigint; v_slip public.staff_payslips; v_today date;
        v_len numeric; sh public.staff_shifts;
begin
  select * into m from public.staff_members where id = p_staff;
  v_m1 := (v_m0 + interval '1 month - 1 day')::date; v_days := v_m1 - v_m0 + 1;
  v_today := public._st_today(m.property_id);
  for d in select g::date from generate_series(v_m0, v_m1, interval '1 day') g loop
    x := public._st_day(p_staff, d);
    case x->>'status'
      when 'not_employed' then v_out := v_out + 1;
      when 'present', 'late' then v_work := v_work + 1;
      when 'half' then v_work := v_work + 0.5; v_absent := v_absent + 0.5;
      when 'absent' then v_absent := v_absent + 1;
      when 'leave' then if x->>'leave_kind' = 'unpaid' then v_unpaid := v_unpaid + 1; else v_paid := v_paid + 1; end if;
      when 'not_in' then v_absent := v_absent + 1;
      else null;   -- off, later, upcoming: not deducted
    end case;
    if m.pay_type = 'hour' and x->>'status' in ('present', 'late', 'half') then
      select * into sh from public.staff_shifts where id = (x->>'shift_id')::uuid;
      v_len := case when sh.id is null then 8 else extract(epoch from (case when sh.ends > sh.starts then sh.ends - sh.starts else sh.ends - sh.starts + interval '24 hours' end)) / 3600 end;
      v_hours := v_hours + coalesce(extract(epoch from ((x->>'out_at')::timestamptz - (x->>'in_at')::timestamptz)) / 3600, v_len * case when x->>'status' = 'half' then 0.5 else 1 end);
    end if;
  end loop;
  if m.pay_type = 'month' then
    v_gross := m.pay_paise;
    v_ded := round(m.pay_paise::numeric / v_days * (v_absent + v_unpaid + v_out));
  elsif m.pay_type = 'day' then v_gross := round(m.pay_paise * v_work);
  elsif m.pay_type = 'hour' then v_gross := round(m.pay_paise * v_hours);
  end if;
  v_ded := least(v_ded, v_gross);
  select * into v_slip from public.staff_payslips where staff_id = p_staff and month = v_m0;
  -- advances still to recover: given up to this month's end, less what earlier payslips already recovered
  v_adv_due := coalesce((select sum(amount_paise) from public.staff_advances where staff_id = p_staff and given_on <= v_m1), 0)
             - coalesce((select sum(advance_paise) from public.staff_payslips where staff_id = p_staff and month < v_m0), 0);
  v_adv := case when v_slip.id is not null then v_slip.advance_paise else least(greatest(v_adv_due, 0), v_gross - v_ded) end;
  return jsonb_build_object('staff_id', p_staff, 'month', v_m0, 'pay_type', m.pay_type, 'pay_paise', m.pay_paise,
    'days_in_month', v_days, 'worked', v_work, 'absent', v_absent, 'unpaid_leave', v_unpaid, 'paid_leave', v_paid, 'not_employed', v_out,
    'hours', round(v_hours, 1), 'gross_paise', v_gross, 'deduction_paise', v_ded, 'advance_paise', v_adv,
    'advance_left_paise', greatest(v_adv_due - v_adv, 0), 'net_paise', v_gross - v_ded - v_adv,
    'complete', v_m1 < v_today,
    'paid', case when v_slip.id is null then null else jsonb_build_object('id', v_slip.id, 'net_paise', v_slip.net_paise, 'paid_on', v_slip.paid_on, 'method', v_slip.method) end);
end $$;

--
-- Name: staff_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_settings (
    property_id uuid NOT NULL,
    leave_days_year integer DEFAULT 12 NOT NULL,
    late_after_min integer DEFAULT 15 NOT NULL,
    managers_see_salary boolean DEFAULT false NOT NULL,
    qr_token uuid DEFAULT gen_random_uuid() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_settings_late_after_min_check CHECK (((late_after_min >= 0) AND (late_after_min <= 120))),
    CONSTRAINT staff_settings_leave_days_year_check CHECK (((leave_days_year >= 0) AND (leave_days_year <= 60)))
);

--
-- Name: _st_settings(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_settings(p_property uuid) RETURNS public.staff_settings
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare s public.staff_settings;
begin
  insert into public.staff_settings (property_id) values (p_property) on conflict do nothing;
  select * into s from public.staff_settings where property_id = p_property;
  return s;
end $$;

--
-- Name: _st_shift(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_shift(p_staff uuid, p_day date) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select case when exists (select 1 from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              then (select r.shift_id from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              when extract(dow from p_day)::smallint = any (coalesce((select weekly_off from public.staff_members where id = p_staff), '{}'::smallint[])) then null
              else (select shift_id from public.staff_members where id = p_staff) end
$$;

--
-- Name: _st_today(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_today(p_property uuid) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (now() at time zone public._st_tz(p_property))::date
$$;

--
-- Name: _st_tz(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_tz(p_property uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce((select nullif(timezone, '') from public.properties where id = p_property), 'Asia/Kolkata')
$$;

--
-- Name: _st_works(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._st_works(p_staff uuid, p_day date) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select case when exists (select 1 from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              then (select r.shift_id is not null from public.staff_roster r where r.staff_id = p_staff and r.day = p_day)
              else not (extract(dow from p_day)::smallint = any (coalesce((select weekly_off from public.staff_members where id = p_staff), '{}'::smallint[]))) end
$$;

--
-- Name: staff_advance_delete(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_advance_delete(p_property uuid, p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, false);
  if not public._st_can_salary(p_property) then raise exception 'Only the owner can do this.'; end if;
  if exists (select 1 from public.staff_advances a join public.staff_payslips s on s.staff_id = a.staff_id and s.month = date_trunc('month', a.given_on)::date where a.id = p_id) then
    raise exception 'That month’s salary is already paid — undo the payment first.';
  end if;
  delete from public.staff_advances where id = p_id and property_id = p_property;
end $$;

--
-- Name: staff_advance_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_advance_save(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid; v_amt int := nullif(p->>'amount_paise', '')::int; v_on date := coalesce(nullif(p->>'given_on', '')::date, public._st_today(p_property));
begin
  perform public._st_check(p_property, false);
  if not public._st_can_salary(p_property) then raise exception 'Only the owner can do this.'; end if;
  if not exists (select 1 from public.staff_members where id = (p->>'staff_id')::uuid and property_id = p_property) then raise exception 'Choose the person.'; end if;
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_on > public._st_today(p_property) then raise exception 'The date can’t be in the future.'; end if;
  if exists (select 1 from public.staff_payslips where staff_id = (p->>'staff_id')::uuid and month = date_trunc('month', v_on)::date) then
    raise exception 'That month’s salary is already paid — give the advance with a date in the next month.';
  end if;
  insert into public.staff_advances (property_id, staff_id, given_on, amount_paise, note)
  values (p_property, (p->>'staff_id')::uuid, v_on, v_amt, nullif(btrim(p->>'note'), '')) returning id into v_id;
  return v_id;
end $$;

--
-- Name: staff_counts(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_counts(p_property uuid) RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if not exists (select 1 from public.property_members m where m.property_id = p_property and m.user_id = auth.uid() and m.role in ('owner', 'manager')) then return 0; end if;
  return (select count(*) from public.staff_leave where property_id = p_property and status = 'pending')::int
       + (select count(*) from public.staff_members where property_id = p_property and (left_on is null or left_on >= public._st_today(p_property))
            and (id_doc is null or (needs_police and police_doc is null)))::int;
end $$;

--
-- Name: staff_delete(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_delete(p_property uuid, p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, true);
  if exists (select 1 from public.staff_payslips where staff_id = p_id) then
    raise exception 'This person has salary records. Set a leaving date instead, so the records stay.';
  end if;
  delete from public.staff_members where id = p_id and property_id = p_property;
end $$;

--
-- Name: staff_doc_set(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_doc_set(p_property uuid, p_staff uuid, p_kind text, p_path text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, false);
  if p_kind not in ('id', 'police') then raise exception 'Unknown document.'; end if;
  if p_path is not null and p_path not like p_property::text || '/' || p_staff::text || '/%' then raise exception 'Upload the file again.'; end if;
  if p_kind = 'id' then update public.staff_members set id_doc = p_path where id = p_staff and property_id = p_property;
  else update public.staff_members set police_doc = p_path where id = p_staff and property_id = p_property; end if;
  if not found then raise exception 'Staff member not found.'; end if;
end $$;

--
-- Name: staff_get(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_get(p_property uuid, p_month date DEFAULT NULL::date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare st public.staff_settings; v_today date; v_role public.member_role; v_sal boolean; v_month date; v_kind text;
begin
  v_role := public._st_check(p_property, false);
  st := public._st_settings(p_property);
  v_today := public._st_today(p_property);
  v_sal := public._st_can_salary(p_property);
  v_month := date_trunc('month', coalesce(p_month, v_today))::date;
  v_kind := (select kind::text from public.properties where id = p_property);
  if to_regclass('public.pg_properties') is not null and exists (select 1 from public.pg_properties where property_id = p_property) then v_kind := 'pg'; end if;
  if to_regclass('public.resort_properties') is not null and exists (select 1 from public.resort_properties where property_id = p_property) then v_kind := 'resort'; end if;
  return jsonb_build_object(
    'today', v_today, 'now', now(), 'kind', v_kind, 'role', v_role, 'can_salary', v_sal, 'month', v_month,
    'settings', jsonb_build_object('leave_days_year', st.leave_days_year, 'late_after_min', st.late_after_min,
                  'managers_see_salary', st.managers_see_salary, 'qr_token', st.qr_token),
    'shifts', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'starts', starts, 'ends', ends, 'sort', sort) order by sort, starts), '[]'::jsonb)
                 from public.staff_shifts where property_id = p_property),
    'members', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', m.id, 'name', m.name, 'phone', m.phone, 'role', m.role, 'live_in', m.live_in,
                   'pay_type', m.pay_type, 'pay_paise', case when v_sal then m.pay_paise end,
                   'weekly_off', m.weekly_off, 'shift_id', m.shift_id, 'joined_on', m.joined_on, 'left_on', m.left_on,
                   'has_pin', m.pin_hash is not null, 'id_kind', m.id_kind, 'id_last4', m.id_last4, 'id_doc', m.id_doc,
                   'needs_police', m.needs_police, 'police_doc', m.police_doc, 'address', m.address,
                   'emergency_name', m.emergency_name, 'emergency_phone', m.emergency_phone, 'note', m.note,
                   'active', m.left_on is null or m.left_on >= v_today,
                   'leave_used', (select coalesce(sum(least(l.date_to, (date_trunc('year', v_today) + interval '1 year - 1 day')::date)
                                                      - greatest(l.date_from, date_trunc('year', v_today)::date) + 1), 0)
                                    from public.staff_leave l where l.staff_id = m.id and l.status = 'approved' and l.kind in ('paid', 'sick')
                                     and l.date_to >= date_trunc('year', v_today)::date and l.date_from < (date_trunc('year', v_today) + interval '1 year')::date),
                   'today', public._st_day(m.id, v_today),
                   'week', (select jsonb_agg(public._st_day(m.id, d::date) order by d) from generate_series(v_today, v_today + 6, interval '1 day') d))
                 order by (m.left_on is not null and m.left_on < v_today), m.name), '[]'::jsonb)
                 from public.staff_members m
                where m.property_id = p_property and (m.left_on is null or m.left_on >= v_today - 60)),
    'leave', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'staff_id', l.staff_id, 'name', m.name, 'role', m.role,
                 'date_from', l.date_from, 'date_to', l.date_to, 'days', l.date_to - l.date_from + 1, 'kind', l.kind, 'reason', l.reason,
                 'status', l.status, 'busy_pct', (select max(public._st_busy(p_property, d::date)) from generate_series(l.date_from, l.date_to, interval '1 day') d),
                 'others_off', (select count(distinct l2.staff_id) from public.staff_leave l2 where l2.property_id = p_property and l2.id <> l.id
                                  and l2.status = 'approved' and l2.date_from <= l.date_to and l2.date_to >= l.date_from))
                 order by (l.status = 'pending') desc, l.date_from), '[]'::jsonb)
                from public.staff_leave l join public.staff_members m on m.id = l.staff_id
               where l.property_id = p_property and (l.status = 'pending' or (l.status = 'approved' and l.date_to >= v_today - 31))),
    'salary', case when v_sal then (select coalesce(jsonb_agg(public._st_salary(m.id, v_month) || jsonb_build_object('name', m.name, 'role', m.role) order by m.name), '[]'::jsonb)
                 from public.staff_members m where m.property_id = p_property
                  and (m.joined_on is null or m.joined_on <= (v_month + interval '1 month - 1 day')::date)
                  and (m.left_on is null or m.left_on >= v_month)) end,
    'advances', case when v_sal then (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'staff_id', a.staff_id, 'name', m.name, 'given_on', a.given_on,
                 'amount_paise', a.amount_paise, 'note', a.note) order by a.given_on desc), '[]'::jsonb)
                 from public.staff_advances a join public.staff_members m on m.id = a.staff_id
                where a.property_id = p_property and a.given_on >= v_month - 62) end);
end $$;

--
-- Name: staff_leave_decide(uuid, uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_leave_decide(p_property uuid, p_id uuid, p_approve boolean, p_kind text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, false);
  if p_kind is not null and p_kind not in ('paid', 'sick', 'unpaid') then raise exception 'Choose paid, sick or unpaid leave.'; end if;
  update public.staff_leave set status = case when p_approve then 'approved' else 'declined' end, kind = coalesce(p_kind, kind),
         decided_by = auth.uid(), decided_at = now()
   where id = p_id and property_id = p_property;
  if not found then raise exception 'Leave request not found.'; end if;
end $$;

--
-- Name: staff_leave_delete(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_leave_delete(p_property uuid, p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, false);
  delete from public.staff_leave where id = p_id and property_id = p_property;
end $$;

--
-- Name: staff_leave_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_leave_save(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid; v_from date := nullif(p->>'date_from', '')::date; v_to date := coalesce(nullif(p->>'date_to', '')::date, nullif(p->>'date_from', '')::date);
        v_kind text := coalesce(nullif(p->>'kind', ''), 'paid'); v_ok boolean := coalesce((p->>'approve')::boolean, false);
begin
  perform public._st_check(p_property, false);
  if not exists (select 1 from public.staff_members where id = (p->>'staff_id')::uuid and property_id = p_property) then raise exception 'Choose the person.'; end if;
  if v_from is null then raise exception 'Pick the first day.'; end if;
  if v_to < v_from then raise exception 'The last day is before the first day.'; end if;
  if v_to - v_from > 60 then raise exception 'Up to 61 days at a time.'; end if;
  if v_kind not in ('paid', 'sick', 'unpaid') then raise exception 'Choose paid, sick or unpaid leave.'; end if;
  if exists (select 1 from public.staff_leave where staff_id = (p->>'staff_id')::uuid and status <> 'declined' and date_from <= v_to and date_to >= v_from) then
    raise exception 'There is already leave on some of these days.';
  end if;
  insert into public.staff_leave (property_id, staff_id, date_from, date_to, kind, reason, status, decided_by, decided_at)
  values (p_property, (p->>'staff_id')::uuid, v_from, v_to, v_kind, nullif(btrim(p->>'reason'), ''),
          case when v_ok then 'approved' else 'pending' end, case when v_ok then auth.uid() end, case when v_ok then now() end)
  returning id into v_id;
  return v_id;
end $$;

--
-- Name: staff_mark(uuid, uuid, date, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_mark(p_property uuid, p_staff uuid, p_day date, p_status text, p_in text DEFAULT NULL::text, p_out text DEFAULT NULL::text, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_tz text := public._st_tz(p_property); v_in timestamptz; v_out timestamptz; sh public.staff_shifts;
begin
  perform public._st_check(p_property, false);
  if not exists (select 1 from public.staff_members where id = p_staff and property_id = p_property) then raise exception 'Staff member not found.'; end if;
  if p_day > public._st_today(p_property) then raise exception 'You can mark today or earlier days only.'; end if;
  if p_status is null then delete from public.staff_attendance where staff_id = p_staff and day = p_day; return public._st_day(p_staff, p_day); end if;
  if p_status not in ('present', 'late', 'half', 'absent', 'off') then raise exception 'Choose present, late, half day, absent or off.'; end if;
  v_in := case when nullif(p_in, '') is not null then (p_day + p_in::time) at time zone v_tz end;
  select * into sh from public.staff_shifts where id = public._st_shift(p_staff, p_day);
  v_out := case when nullif(p_out, '') is not null then (p_day + p_out::time + case when p_out::time < coalesce(p_in::time, sh.starts, '00:00') then interval '1 day' else interval '0' end) at time zone v_tz end;
  insert into public.staff_attendance (property_id, staff_id, day, status, in_at, out_at, source, note, marked_by, updated_at)
  values (p_property, p_staff, p_day, p_status, v_in, v_out, 'manual', nullif(btrim(p_note), ''), auth.uid(), now())
  on conflict (staff_id, day) do update set status = excluded.status, in_at = coalesce(excluded.in_at, staff_attendance.in_at),
    out_at = coalesce(excluded.out_at, staff_attendance.out_at), note = coalesce(excluded.note, staff_attendance.note),
    source = 'manual', marked_by = auth.uid(), updated_at = now();
  return public._st_day(p_staff, p_day);
end $$;

--
-- Name: staff_pay(uuid, uuid, date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_pay(p_property uuid, p_staff uuid, p_month date, p_method text DEFAULT 'cash'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare s jsonb; m public.staff_members; v_exp uuid; v_id uuid; v_m0 date := date_trunc('month', p_month)::date; v_today date := public._st_today(p_property);
begin
  perform public._st_check(p_property, false);
  if not public._st_can_salary(p_property) then raise exception 'Only the owner can do this.'; end if;
  select * into m from public.staff_members where id = p_staff and property_id = p_property;
  if not found then raise exception 'Staff member not found.'; end if;
  if coalesce(p_method, '') not in ('cash', 'upi', 'card', 'bank') then raise exception 'Choose how you paid: cash, UPI, card or bank.'; end if;
  if v_m0 > date_trunc('month', v_today)::date then raise exception 'That month hasn’t started yet.'; end if;
  if exists (select 1 from public.staff_payslips where staff_id = p_staff and month = v_m0) then raise exception 'Already paid for this month.'; end if;
  s := public._st_salary(p_staff, v_m0);
  if (s->>'net_paise')::int <= 0 then raise exception 'Nothing to pay for this month.'; end if;
  insert into public.expenses (property_id, spent_on, category, amount_paise, method, vendor, note, created_by)
  values (p_property, v_today, 'salaries', (s->>'net_paise')::int + (s->>'advance_paise')::int, p_method, left(m.name, 80),   -- the month's full salary cost (advances were cash given earlier)
          'Salary ' || to_char(v_m0, 'Mon YYYY') || ' · ' || m.role || case when (s->>'advance_paise')::int > 0 then ' (incl. advance ₹' || ((s->>'advance_paise')::int / 100) || ' given earlier)' else '' end,
          auth.uid())
  returning id into v_exp;
  insert into public.staff_payslips (property_id, staff_id, month, gross_paise, deduction_paise, advance_paise, net_paise, days_worked, paid_on, method, expense_id)
  values (p_property, p_staff, v_m0, (s->>'gross_paise')::int, (s->>'deduction_paise')::int, (s->>'advance_paise')::int, (s->>'net_paise')::int,
          (s->>'worked')::numeric, v_today, p_method, v_exp)
  returning id into v_id;
  return public._st_salary(p_staff, v_m0) || jsonb_build_object('payslip_id', v_id, 'name', m.name, 'role', m.role, 'phone', m.phone);
end $$;

--
-- Name: staff_qr_info(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_qr_info(p_token uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare st public.staff_settings; v_today date;
begin
  select * into st from public.staff_settings where qr_token = p_token;
  if not found or public._access_state(st.property_id) in ('expired', 'suspended') then raise exception 'This check-in QR is not valid any more. Ask the owner for the new one.'; end if;
  v_today := public._st_today(st.property_id);
  return jsonb_build_object('property', (select name from public.properties where id = st.property_id), 'today', v_today,
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', split_part(m.name, ' ', 1) || coalesce(' ' || left(nullif(split_part(m.name, ' ', 2), ''), 1) || '.', ''),
                'role', m.role, 'has_pin', m.pin_hash is not null,
                'state', case when exists (select 1 from public.staff_attendance a where a.staff_id = m.id and a.in_at is not null and a.out_at is null and a.day >= v_today - 1) then 'in'
                              when exists (select 1 from public.staff_attendance a where a.staff_id = m.id and a.day = v_today and a.out_at is not null) then 'done'
                              else 'out' end) order by m.name), '[]'::jsonb)
                from public.staff_members m where m.property_id = st.property_id and not m.live_in
                 and (m.left_on is null or m.left_on >= v_today) and (m.joined_on is null or m.joined_on <= v_today)));
end $$;

--
-- Name: staff_qr_punch(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_qr_punch(p_token uuid, p_staff uuid, p_pin text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare st public.staff_settings; m public.staff_members; v_key text := public._st_client_key(); v_today date; v_tz text; a public.staff_attendance;
        sh public.staff_shifts; v_start timestamptz; v_status text;
begin
  select * into st from public.staff_settings where qr_token = p_token;
  if not found or public._access_state(st.property_id) in ('expired', 'suspended') then raise exception 'This check-in QR is not valid any more. Ask the owner for the new one.'; end if;
  delete from public.staff_qr_tries where at < now() - interval '1 day';
  if (select count(*) from public.staff_qr_tries where key in (v_key, 'staff:' || p_staff::text) and at > now() - interval '10 minutes') >= 8 then
    raise exception 'Too many tries. Wait 10 minutes and try again, or ask the manager to mark you.';
  end if;
  select * into m from public.staff_members where id = p_staff and property_id = st.property_id;
  if not found or m.pin_hash is null or coalesce(p_pin, '') !~ '^[0-9]{4}$' or md5(m.id::text || p_pin) <> m.pin_hash then
    insert into public.staff_qr_tries (key) values (v_key), ('staff:' || p_staff::text);
    raise exception 'Wrong PIN. Try again — or ask the manager to set your PIN.';
  end if;
  v_tz := public._st_tz(st.property_id); v_today := (now() at time zone v_tz)::date;
  -- still checked in (today, or a night shift from yesterday)? → check out
  select * into a from public.staff_attendance where staff_id = p_staff and in_at is not null and out_at is null and day >= v_today - 1 order by day desc limit 1;
  if found then
    if now() - a.in_at < interval '2 minutes' then raise exception 'You checked in just now.'; end if;
    update public.staff_attendance set out_at = now(), updated_at = now() where staff_id = p_staff and day = a.day;
    return jsonb_build_object('action', 'out', 'name', m.name, 'at', now(), 'hours', round(extract(epoch from now() - a.in_at)::numeric / 3600, 1));
  end if;
  if exists (select 1 from public.staff_attendance where staff_id = p_staff and day = v_today and out_at is not null) then
    raise exception 'You already checked out today.';
  end if;
  select * into sh from public.staff_shifts where id = public._st_shift(p_staff, v_today);
  v_start := case when sh.id is not null then (v_today + sh.starts) at time zone v_tz end;
  v_status := case when v_start is not null and now() > v_start + make_interval(mins => st.late_after_min) then 'late' else 'present' end;
  insert into public.staff_attendance (property_id, staff_id, day, status, in_at, source, updated_at)
  values (st.property_id, p_staff, v_today, v_status, now(), 'qr', now())
  on conflict (staff_id, day) do update set status = case when staff_attendance.status in ('absent', 'off') then excluded.status else staff_attendance.status end,
    in_at = coalesce(staff_attendance.in_at, excluded.in_at), source = 'qr', updated_at = now();
  return jsonb_build_object('action', 'in', 'name', m.name, 'at', now(), 'late', v_status = 'late',
    'late_min', case when v_start is not null then greatest(0, floor(extract(epoch from now() - v_start) / 60))::int end, 'shift', sh.name);
end $_$;

--
-- Name: staff_roster_set(uuid, uuid, date, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_roster_set(p_property uuid, p_staff uuid, p_day date, p_mode text, p_shift uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, false);
  if not exists (select 1 from public.staff_members where id = p_staff and property_id = p_property) then raise exception 'Staff member not found.'; end if;
  if p_mode = 'usual' then delete from public.staff_roster where staff_id = p_staff and day = p_day;
  elsif p_mode = 'off' then
    insert into public.staff_roster (property_id, staff_id, day, shift_id) values (p_property, p_staff, p_day, null)
    on conflict (staff_id, day) do update set shift_id = null;
  elsif p_mode = 'shift' then
    if not exists (select 1 from public.staff_shifts where id = p_shift and property_id = p_property) then raise exception 'Unknown shift.'; end if;
    insert into public.staff_roster (property_id, staff_id, day, shift_id) values (p_property, p_staff, p_day, p_shift)
    on conflict (staff_id, day) do update set shift_id = excluded.shift_id;
  else raise exception 'Choose a shift, day off or usual.';
  end if;
  return public._st_day(p_staff, p_day);
end $$;

--
-- Name: staff_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_save(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_pin text := nullif(btrim(p->>'pin'), ''); v_pay text := coalesce(nullif(p->>'pay_type', ''), 'month');
        v_amt int := coalesce(nullif(p->>'pay_paise', '')::int, 0); v_sal boolean; v_shift uuid := nullif(p->>'shift_id', '')::uuid; v_off smallint[];
        v_join date := nullif(p->>'joined_on', '')::date; v_left date := nullif(p->>'left_on', '')::date;
begin
  perform public._st_check(p_property, false);
  perform public._st_settings(p_property);
  v_sal := public._st_can_salary(p_property);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the name.'; end if;
  if char_length(btrim(coalesce(p->>'role', ''))) < 2 then raise exception 'Choose or type the job, e.g. "Reception".'; end if;
  if nullif(p->>'phone', '') is not null and (p->>'phone') !~ '^\+?[0-9]{8,15}$' then raise exception 'Phone: digits only, e.g. 9876543210.'; end if;
  if v_pay not in ('month', 'day', 'hour', 'none') then raise exception 'Choose how they are paid.'; end if;
  if v_pay <> 'none' and v_sal and v_amt <= 0 then raise exception 'Enter the salary.'; end if;
  if v_pay = 'none' then v_amt := 0; end if;
  if v_pin is not null and v_pin !~ '^[0-9]{4}$' then raise exception 'PIN: 4 digits.'; end if;
  if v_shift is not null and not exists (select 1 from public.staff_shifts where id = v_shift and property_id = p_property) then raise exception 'Unknown shift.'; end if;
  if v_left is not null and v_join is not null and v_left < v_join then raise exception 'The leaving date is before the joining date.'; end if;
  v_off := case when jsonb_typeof(p->'weekly_off') = 'array' then array(select (x)::smallint from jsonb_array_elements_text(p->'weekly_off') x) else '{}' end;
  if v_id is null then
    insert into public.staff_members (property_id, name, phone, role, live_in, pay_type, pay_paise, weekly_off, shift_id, joined_on, left_on,
                                      id_kind, id_last4, needs_police, address, emergency_name, emergency_phone, note)
    values (p_property, btrim(p->>'name'), nullif(p->>'phone', ''), btrim(p->>'role'), coalesce((p->>'live_in')::boolean, false), v_pay,
            case when v_sal then v_amt else 0 end, v_off, v_shift, v_join, v_left,
            nullif(p->>'id_kind', ''), nullif(upper(right(regexp_replace(coalesce(p->>'id_number', ''), '\s', '', 'g'), 4)), ''),
            coalesce((p->>'needs_police')::boolean, false), nullif(btrim(p->>'address'), ''), nullif(btrim(p->>'emergency_name'), ''),
            nullif(p->>'emergency_phone', ''), nullif(btrim(p->>'note'), ''))
    returning id into v_id;
  else
    update public.staff_members set name = btrim(p->>'name'), phone = nullif(p->>'phone', ''), role = btrim(p->>'role'),
           live_in = coalesce((p->>'live_in')::boolean, false), pay_type = v_pay,
           pay_paise = case when v_sal then v_amt else pay_paise end,
           weekly_off = v_off, shift_id = v_shift, joined_on = v_join, left_on = v_left,
           id_kind = nullif(p->>'id_kind', ''),
           id_last4 = coalesce(nullif(upper(right(regexp_replace(coalesce(p->>'id_number', ''), '\s', '', 'g'), 4)), ''), case when nullif(p->>'id_kind', '') is null then null else id_last4 end),
           needs_police = coalesce((p->>'needs_police')::boolean, false), address = nullif(btrim(p->>'address'), ''),
           emergency_name = nullif(btrim(p->>'emergency_name'), ''), emergency_phone = nullif(p->>'emergency_phone', ''), note = nullif(btrim(p->>'note'), '')
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Staff member not found.'; end if;
  end if;
  if v_pin is not null then update public.staff_members set pin_hash = md5(v_id::text || v_pin) where id = v_id; end if;
  return v_id;
exception when check_violation then raise exception 'Check the details — phone numbers digits only, ID: last 4 letters or digits.';
end $_$;

--
-- Name: staff_settings_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_settings_save(p_property uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, true);
  perform public._st_settings(p_property);
  update public.staff_settings set
    leave_days_year = coalesce(nullif(p->>'leave_days_year', '')::int, leave_days_year),
    late_after_min = coalesce(nullif(p->>'late_after_min', '')::int, late_after_min),
    managers_see_salary = coalesce((p->>'managers_see_salary')::boolean, managers_see_salary),
    qr_token = case when coalesce((p->>'new_qr')::boolean, false) then gen_random_uuid() else qr_token end,
    updated_at = now()
   where property_id = p_property;
  return (select jsonb_build_object('qr_token', qr_token) from public.staff_settings where property_id = p_property);
exception when check_violation then raise exception 'Leave days: 0–60 a year. Late after: 0–120 minutes.';
end $$;

--
-- Name: staff_shift_delete(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_shift_delete(p_property uuid, p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._st_check(p_property, false);
  delete from public.staff_shifts where id = p_id and property_id = p_property;     -- usual shifts using it become "no shift"; roster days using it are cleared
end $$;

--
-- Name: staff_shift_save(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_shift_save(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_s time := nullif(p->>'starts', '')::time; v_e time := nullif(p->>'ends', '')::time;
begin
  perform public._st_check(p_property, false);
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Name the shift, e.g. "Morning".'; end if;
  if v_s is null or v_e is null then raise exception 'Enter the start and end time.'; end if;
  if v_s = v_e then raise exception 'Start and end can’t be the same time.'; end if;
  if v_id is null then
    if (select count(*) from public.staff_shifts where property_id = p_property) >= 12 then raise exception 'Up to 12 shifts.'; end if;
    insert into public.staff_shifts (property_id, name, starts, ends, sort)
    values (p_property, btrim(p->>'name'), v_s, v_e, coalesce(nullif(p->>'sort', '')::int, (select coalesce(max(sort), 0) + 1 from public.staff_shifts where property_id = p_property)))
    returning id into v_id;
  else
    update public.staff_shifts set name = btrim(p->>'name'), starts = v_s, ends = v_e where id = v_id and property_id = p_property;
    if not found then raise exception 'Shift not found.'; end if;
  end if;
  return v_id;
end $$;

--
-- Name: staff_unpay(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_unpay(p_property uuid, p_payslip uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_exp uuid;
begin
  perform public._st_check(p_property, true);
  delete from public.staff_payslips where id = p_payslip and property_id = p_property returning expense_id into v_exp;
  if not found then raise exception 'Payment not found.'; end if;
  delete from public.expenses where id = v_exp and property_id = p_property and category = 'salaries';
end $$;

--
-- Name: staff_advances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_advances (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    staff_id uuid NOT NULL,
    given_on date NOT NULL,
    amount_paise integer NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_advances_amount_paise_check CHECK (((amount_paise >= 100) AND (amount_paise <= 100000000))),
    CONSTRAINT staff_advances_note_check CHECK ((char_length(note) <= 200))
);

--
-- Name: staff_attendance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_attendance (
    property_id uuid NOT NULL,
    staff_id uuid NOT NULL,
    day date NOT NULL,
    status text NOT NULL,
    in_at timestamp with time zone,
    out_at timestamp with time zone,
    source text DEFAULT 'manual'::text NOT NULL,
    note text,
    marked_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_attendance_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT staff_attendance_source_check CHECK ((source = ANY (ARRAY['qr'::text, 'manual'::text]))),
    CONSTRAINT staff_attendance_status_check CHECK ((status = ANY (ARRAY['present'::text, 'late'::text, 'half'::text, 'absent'::text, 'off'::text])))
);

--
-- Name: staff_leave; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_leave (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    staff_id uuid NOT NULL,
    date_from date NOT NULL,
    date_to date NOT NULL,
    kind text DEFAULT 'paid'::text NOT NULL,
    reason text,
    status text DEFAULT 'pending'::text NOT NULL,
    decided_by uuid,
    decided_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_leave_check CHECK (((date_to >= date_from) AND ((date_to - date_from) <= 60))),
    CONSTRAINT staff_leave_kind_check CHECK ((kind = ANY (ARRAY['paid'::text, 'sick'::text, 'unpaid'::text]))),
    CONSTRAINT staff_leave_reason_check CHECK ((char_length(reason) <= 200)),
    CONSTRAINT staff_leave_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'declined'::text])))
);

--
-- Name: staff_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    phone text,
    role text NOT NULL,
    live_in boolean DEFAULT false NOT NULL,
    pay_type text DEFAULT 'month'::text NOT NULL,
    pay_paise integer DEFAULT 0 NOT NULL,
    weekly_off smallint[] DEFAULT '{}'::smallint[] NOT NULL,
    shift_id uuid,
    joined_on date,
    left_on date,
    pin_hash text,
    id_kind text,
    id_last4 text,
    id_doc text,
    needs_police boolean DEFAULT false NOT NULL,
    police_doc text,
    address text,
    emergency_name text,
    emergency_phone text,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_members_address_check CHECK ((char_length(address) <= 200)),
    CONSTRAINT staff_members_check CHECK (((left_on IS NULL) OR (joined_on IS NULL) OR (left_on >= joined_on))),
    CONSTRAINT staff_members_emergency_name_check CHECK ((char_length(emergency_name) <= 60)),
    CONSTRAINT staff_members_emergency_phone_check CHECK (((emergency_phone IS NULL) OR (emergency_phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT staff_members_id_kind_check CHECK (((id_kind IS NULL) OR (id_kind = ANY (ARRAY['aadhaar'::text, 'voter_id'::text, 'driving_licence'::text, 'pan'::text, 'passport'::text, 'other'::text])))),
    CONSTRAINT staff_members_id_last4_check CHECK (((id_last4 IS NULL) OR (id_last4 ~ '^[0-9A-Za-z]{1,4}$'::text))),
    CONSTRAINT staff_members_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 60))),
    CONSTRAINT staff_members_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT staff_members_pay_paise_check CHECK (((pay_paise >= 0) AND (pay_paise <= 100000000))),
    CONSTRAINT staff_members_pay_type_check CHECK ((pay_type = ANY (ARRAY['month'::text, 'day'::text, 'hour'::text, 'none'::text]))),
    CONSTRAINT staff_members_phone_check CHECK (((phone IS NULL) OR (phone ~ '^\+?[0-9]{8,15}$'::text))),
    CONSTRAINT staff_members_role_check CHECK (((char_length(btrim(role)) >= 2) AND (char_length(btrim(role)) <= 40))),
    CONSTRAINT staff_members_weekly_off_check CHECK ((weekly_off <@ ARRAY[(0)::smallint, (1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint]))
);

--
-- Name: staff_payslips; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_payslips (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    staff_id uuid NOT NULL,
    month date NOT NULL,
    gross_paise integer NOT NULL,
    deduction_paise integer DEFAULT 0 NOT NULL,
    advance_paise integer DEFAULT 0 NOT NULL,
    net_paise integer NOT NULL,
    days_worked numeric(6,2),
    paid_on date NOT NULL,
    method text NOT NULL,
    expense_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_payslips_method_check CHECK ((method = ANY (ARRAY['cash'::text, 'upi'::text, 'card'::text, 'bank'::text]))),
    CONSTRAINT staff_payslips_month_check CHECK ((EXTRACT(day FROM month) = (1)::numeric))
);

--
-- Name: staff_qr_tries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_qr_tries (
    key text NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: staff_roster; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_roster (
    property_id uuid NOT NULL,
    staff_id uuid NOT NULL,
    day date NOT NULL,
    shift_id uuid
);

--
-- Name: staff_shifts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_shifts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    name text NOT NULL,
    starts time without time zone NOT NULL,
    ends time without time zone NOT NULL,
    sort integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_shifts_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 30)))
);

--
-- Name: staff_advances staff_advances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_advances
    ADD CONSTRAINT staff_advances_pkey PRIMARY KEY (id);

--
-- Name: staff_attendance staff_attendance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_attendance
    ADD CONSTRAINT staff_attendance_pkey PRIMARY KEY (staff_id, day);

--
-- Name: staff_leave staff_leave_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_leave
    ADD CONSTRAINT staff_leave_pkey PRIMARY KEY (id);

--
-- Name: staff_members staff_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_members
    ADD CONSTRAINT staff_members_pkey PRIMARY KEY (id);

--
-- Name: staff_payslips staff_payslips_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_payslips
    ADD CONSTRAINT staff_payslips_pkey PRIMARY KEY (id);

--
-- Name: staff_payslips staff_payslips_staff_id_month_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_payslips
    ADD CONSTRAINT staff_payslips_staff_id_month_key UNIQUE (staff_id, month);

--
-- Name: staff_roster staff_roster_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_roster
    ADD CONSTRAINT staff_roster_pkey PRIMARY KEY (staff_id, day);

--
-- Name: staff_settings staff_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_settings
    ADD CONSTRAINT staff_settings_pkey PRIMARY KEY (property_id);

--
-- Name: staff_shifts staff_shifts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_shifts
    ADD CONSTRAINT staff_shifts_pkey PRIMARY KEY (id);

--
-- Name: staff_advances_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX staff_advances_property ON public.staff_advances USING btree (property_id, given_on);

--
-- Name: staff_attendance_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX staff_attendance_property ON public.staff_attendance USING btree (property_id, day);

--
-- Name: staff_leave_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX staff_leave_property ON public.staff_leave USING btree (property_id, date_from);

--
-- Name: staff_members_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX staff_members_property ON public.staff_members USING btree (property_id);

--
-- Name: staff_payslips_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX staff_payslips_property ON public.staff_payslips USING btree (property_id, month);

--
-- Name: staff_qr_tries_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX staff_qr_tries_key ON public.staff_qr_tries USING btree (key, at);

--
-- Name: staff_settings_qr; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX staff_settings_qr ON public.staff_settings USING btree (qr_token);

--
-- Name: staff_shifts_property; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX staff_shifts_property ON public.staff_shifts USING btree (property_id, sort);

--
-- Name: staff_advances staff_advances_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_advances
    ADD CONSTRAINT staff_advances_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_advances staff_advances_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_advances
    ADD CONSTRAINT staff_advances_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_members(id) ON DELETE CASCADE;

--
-- Name: staff_attendance staff_attendance_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_attendance
    ADD CONSTRAINT staff_attendance_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_attendance staff_attendance_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_attendance
    ADD CONSTRAINT staff_attendance_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_members(id) ON DELETE CASCADE;

--
-- Name: staff_leave staff_leave_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_leave
    ADD CONSTRAINT staff_leave_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_leave staff_leave_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_leave
    ADD CONSTRAINT staff_leave_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_members(id) ON DELETE CASCADE;

--
-- Name: staff_members staff_members_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_members
    ADD CONSTRAINT staff_members_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_members staff_members_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_members
    ADD CONSTRAINT staff_members_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES public.staff_shifts(id) ON DELETE SET NULL;

--
-- Name: staff_payslips staff_payslips_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_payslips
    ADD CONSTRAINT staff_payslips_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_payslips staff_payslips_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_payslips
    ADD CONSTRAINT staff_payslips_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_members(id) ON DELETE CASCADE;

--
-- Name: staff_roster staff_roster_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_roster
    ADD CONSTRAINT staff_roster_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_roster staff_roster_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_roster
    ADD CONSTRAINT staff_roster_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES public.staff_shifts(id) ON DELETE CASCADE;

--
-- Name: staff_roster staff_roster_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_roster
    ADD CONSTRAINT staff_roster_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_members(id) ON DELETE CASCADE;

--
-- Name: staff_settings staff_settings_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_settings
    ADD CONSTRAINT staff_settings_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_shifts staff_shifts_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_shifts
    ADD CONSTRAINT staff_shifts_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: staff_advances; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_advances ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_attendance; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_attendance ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_leave; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_leave ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_members ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_payslips; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_payslips ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_qr_tries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_qr_tries ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_roster; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_roster ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_shifts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_shifts ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION _st_busy(p_property uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_busy(p_property uuid, p_day date) FROM PUBLIC;

--
-- Name: FUNCTION _st_can_salary(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_can_salary(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _st_check(p_property uuid, p_owner_only boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_check(p_property uuid, p_owner_only boolean) FROM PUBLIC;

--
-- Name: FUNCTION _st_client_key(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_client_key() FROM PUBLIC;

--
-- Name: FUNCTION _st_day(p_staff uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_day(p_staff uuid, p_day date) FROM PUBLIC;

--
-- Name: FUNCTION _st_salary(p_staff uuid, p_month date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_salary(p_staff uuid, p_month date) FROM PUBLIC;

--
-- Name: FUNCTION _st_settings(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_settings(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _st_shift(p_staff uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_shift(p_staff uuid, p_day date) FROM PUBLIC;

--
-- Name: FUNCTION _st_today(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_today(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _st_tz(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_tz(p_property uuid) FROM PUBLIC;

--
-- Name: FUNCTION _st_works(p_staff uuid, p_day date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._st_works(p_staff uuid, p_day date) FROM PUBLIC;

--
-- Name: FUNCTION staff_advance_delete(p_property uuid, p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_advance_delete(p_property uuid, p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_advance_delete(p_property uuid, p_id uuid) TO authenticated;

--
-- Name: FUNCTION staff_advance_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_advance_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_advance_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION staff_counts(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_counts(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_counts(p_property uuid) TO authenticated;

--
-- Name: FUNCTION staff_delete(p_property uuid, p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_delete(p_property uuid, p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_delete(p_property uuid, p_id uuid) TO authenticated;

--
-- Name: FUNCTION staff_doc_set(p_property uuid, p_staff uuid, p_kind text, p_path text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_doc_set(p_property uuid, p_staff uuid, p_kind text, p_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_doc_set(p_property uuid, p_staff uuid, p_kind text, p_path text) TO authenticated;

--
-- Name: FUNCTION staff_get(p_property uuid, p_month date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_get(p_property uuid, p_month date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_get(p_property uuid, p_month date) TO authenticated;

--
-- Name: FUNCTION staff_leave_decide(p_property uuid, p_id uuid, p_approve boolean, p_kind text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_leave_decide(p_property uuid, p_id uuid, p_approve boolean, p_kind text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_leave_decide(p_property uuid, p_id uuid, p_approve boolean, p_kind text) TO authenticated;

--
-- Name: FUNCTION staff_leave_delete(p_property uuid, p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_leave_delete(p_property uuid, p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_leave_delete(p_property uuid, p_id uuid) TO authenticated;

--
-- Name: FUNCTION staff_leave_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_leave_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_leave_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION staff_mark(p_property uuid, p_staff uuid, p_day date, p_status text, p_in text, p_out text, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_mark(p_property uuid, p_staff uuid, p_day date, p_status text, p_in text, p_out text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_mark(p_property uuid, p_staff uuid, p_day date, p_status text, p_in text, p_out text, p_note text) TO authenticated;

--
-- Name: FUNCTION staff_pay(p_property uuid, p_staff uuid, p_month date, p_method text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_pay(p_property uuid, p_staff uuid, p_month date, p_method text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_pay(p_property uuid, p_staff uuid, p_month date, p_method text) TO authenticated;

--
-- Name: FUNCTION staff_qr_info(p_token uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_qr_info(p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_qr_info(p_token uuid) TO anon;
GRANT ALL ON FUNCTION public.staff_qr_info(p_token uuid) TO authenticated;

--
-- Name: FUNCTION staff_qr_punch(p_token uuid, p_staff uuid, p_pin text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_qr_punch(p_token uuid, p_staff uuid, p_pin text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_qr_punch(p_token uuid, p_staff uuid, p_pin text) TO anon;
GRANT ALL ON FUNCTION public.staff_qr_punch(p_token uuid, p_staff uuid, p_pin text) TO authenticated;

--
-- Name: FUNCTION staff_roster_set(p_property uuid, p_staff uuid, p_day date, p_mode text, p_shift uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_roster_set(p_property uuid, p_staff uuid, p_day date, p_mode text, p_shift uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_roster_set(p_property uuid, p_staff uuid, p_day date, p_mode text, p_shift uuid) TO authenticated;

--
-- Name: FUNCTION staff_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION staff_settings_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_settings_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_settings_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION staff_shift_delete(p_property uuid, p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_shift_delete(p_property uuid, p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_shift_delete(p_property uuid, p_id uuid) TO authenticated;

--
-- Name: FUNCTION staff_shift_save(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_shift_save(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_shift_save(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION staff_unpay(p_property uuid, p_payslip uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_unpay(p_property uuid, p_payslip uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_unpay(p_property uuid, p_payslip uuid) TO authenticated;

-- ---------------------------------------------------------------- storage, realtime & default rows
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values ('staff-docs', 'staff-docs', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf']) on conflict (id) do nothing;

drop policy if exists "staff-docs: delete" on storage.objects;
create policy "staff-docs: delete" on storage.objects for delete to authenticated
  using (((bucket_id = 'staff-docs'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));

drop policy if exists "staff-docs: read" on storage.objects;
create policy "staff-docs: read" on storage.objects for select to authenticated
  using (((bucket_id = 'staff-docs'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));

drop policy if exists "staff-docs: upload" on storage.objects;
create policy "staff-docs: upload" on storage.objects for insert to authenticated
  with check (((bucket_id = 'staff-docs'::text) AND (EXISTS ( SELECT 1 FROM public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role]) pid(pid) WHERE ((pid.pid)::text = (storage.foldername(objects.name))[1])))));
