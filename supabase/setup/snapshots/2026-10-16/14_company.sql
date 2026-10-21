-- =====================================================================
-- NammaStay · company
-- Company: NammaStay's own business numbers (platform admins only)
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
-- Name: _co_area(text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._co_area(p_key text, p_status text, p_value text, p_detail text, p_todo text, p_link text) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
  select jsonb_build_object('key', p_key, 'status', p_status, 'value', p_value, 'detail', p_detail, 'todo', p_todo, 'link', p_link,
           'score', case p_status when 'good' then 100 when 'watch' then 60 when 'act' then 20 end)
$$;

--
-- Name: _co_month0(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._co_month0() RETURNS date
    LANGUAGE sql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select date_trunc('month', now() at time zone 'Asia/Kolkata')::date
$$;

--
-- Name: _co_month_costs(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._co_month_costs(p_month date) RETURNS bigint
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(sum(case
           when c.every = 'once'  then case when date_trunc('month', c.starts_on)::date = p_month then c.amount_paise else 0 end
           when c.every = 'month' then c.amount_paise
           else round(c.amount_paise / 12.0) end), 0)::bigint
    from public.company_costs c
   where (c.every = 'once' and date_trunc('month', c.starts_on)::date = p_month)
      or (c.every <> 'once' and c.starts_on <= (p_month + interval '1 month - 1 day')::date
          and (c.ends_on is null or c.ends_on >= p_month))
$$;

--
-- Name: _co_net(numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._co_net(p_paise numeric) RETURNS bigint
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select round(coalesce(p_paise, 0) * 100.0 / (100 + coalesce((select case when gstin is not null then gst_rate else 0 end from public.platform_settings where id = 1), 0)))::bigint
$$;

--
-- Name: _co_next_due(date, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._co_next_due(p_due date, p_repeat text) RETURNS date
    LANGUAGE sql IMMUTABLE
    AS $$
  select case p_repeat when 'month' then (p_due + interval '1 month')::date
                       when 'quarter' then (p_due + interval '3 months')::date
                       when 'year' then (p_due + interval '1 year')::date end
$$;

--
-- Name: _co_paying_at(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._co_paying_at(p_at timestamp with time zone, OUT mrr_paise bigint, OUT paying integer) RETURNS record
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(sum(x.amount_paise::numeric / greatest(x.period_months, 1)), 0)::bigint, count(*)::int
    from (select distinct on (sp.property_id) sp.property_id, sp.amount_paise, pl.period_months
            from public.subscription_payments sp
            join public.plans pl on pl.id = sp.plan_id
            join public.subscriptions s on s.property_id = sp.property_id and not s.is_complimentary
           where sp.status = 'approved'
             and coalesce(sp.period_start, sp.reviewed_at) <= p_at
             and coalesce(sp.period_end, coalesce(sp.period_start, sp.reviewed_at) + make_interval(months => greatest(pl.period_months, 1))) > p_at
           order by sp.property_id, sp.reviewed_at desc) x
$$;

--
-- Name: _co_renewals(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._co_renewals() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'kind', r.kind, 'title', r.title, 'due_on', r.due_on, 'repeat', r.repeat, 'amount_paise', r.amount_paise,
           'done_on', r.done_on, 'note', r.note,
           'days_left', case when r.due_on is not null then r.due_on - (now() at time zone 'Asia/Kolkata')::date end,
           'state', case when r.done_on is not null then 'done'
                         when r.due_on is null then 'pending'
                         when r.due_on < (now() at time zone 'Asia/Kolkata')::date then 'overdue'
                         when r.due_on <= (now() at time zone 'Asia/Kolkata')::date + 7 then 'soon'
                         else 'ok' end)
         order by (r.done_on is not null), r.due_on nulls last, r.title), '[]'::jsonb)
    from public.company_renewals r
$$;

--
-- Name: company_badge(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_badge() RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if not public.is_platform_admin() then return 0; end if;
  return (select count(*) from public.company_renewals where done_on is null and due_on is not null
           and due_on <= (now() at time zone 'Asia/Kolkata')::date + 7)::int;
end $$;

--
-- Name: company_cost_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_cost_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin perform public._assert_platform_admin(); delete from public.company_costs where id = p_id; end $$;

--
-- Name: company_cost_save(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_cost_save(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := nullif(p->>'amount_paise', '')::bigint;
        v_from date := nullif(p->>'starts_on', '')::date; v_to date := nullif(p->>'ends_on', '')::date;
        v_cat text := coalesce(nullif(p->>'category', ''), 'other'); v_every text := coalesce(nullif(p->>'every', ''), 'month');
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Give the cost a name, e.g. "Supabase".'; end if;
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_from is null then raise exception 'Pick the start date.'; end if;
  if v_to is not null and v_to < v_from then raise exception 'The stop date is before the start date.'; end if;
  if v_cat not in ('salaries', 'marketing', 'servers', 'tools', 'office', 'compliance', 'other') then raise exception 'Unknown category.'; end if;
  if v_every not in ('month', 'year', 'once') then raise exception 'Choose how often it is paid.'; end if;
  if v_every = 'once' then v_to := null; end if;
  if v_id is null then
    insert into public.company_costs (name, category, every, amount_paise, starts_on, ends_on, note)
    values (btrim(p->>'name'), v_cat, v_every, v_amt, v_from, v_to, nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_costs set name = btrim(p->>'name'), category = v_cat, every = v_every, amount_paise = v_amt,
           starts_on = v_from, ends_on = v_to, note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Cost not found.'; end if;
  end if;
  return v_id;
end $$;

--
-- Name: company_founder_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_founder_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  perform public._assert_platform_admin();
  delete from public.company_founders where id = p_id;    -- money they put in stays (no longer linked)
end $$;

--
-- Name: company_founder_save(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_founder_save(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_share numeric := coalesce(nullif(p->>'share_pct', '')::numeric, 0);
        v_me boolean := coalesce((p->>'is_me')::boolean, false); v_other numeric;
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the founder''s name.'; end if;
  if v_share < 0 or v_share > 100 then raise exception 'Share: between 0 and 100%%.'; end if;
  if v_me and exists (select 1 from public.company_founders where is_me and id is distinct from v_id) then raise exception 'You are already in the list.'; end if;
  select coalesce(sum(share_pct), 0) into v_other from public.company_founders where id is distinct from v_id;
  if v_other + v_share > 100 then raise exception 'Shares would add up to % %%. Keep the total at 100%% or less.', v_other + v_share; end if;
  if v_id is null then
    insert into public.company_founders (name, role, share_pct, is_me) values (btrim(p->>'name'), nullif(btrim(p->>'role'), ''), v_share, v_me) returning id into v_id;
  else
    update public.company_founders set name = btrim(p->>'name'), role = nullif(btrim(p->>'role'), ''), share_pct = v_share, is_me = v_me where id = v_id;
    if not found then raise exception 'Founder not found.'; end if;
  end if;
  return v_id;
end $$;

--
-- Name: company_health(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_health() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  s jsonb; v_rev jsonb; a jsonb := '[]'::jsonb; v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_week date := (date_trunc('week', now() at time zone 'Asia/Kolkata'))::date;
  v_mrr bigint; v_prev bigint; v_g numeric; v_paying int; v_churn int; v_ct int; v_cp int; v_n int; v_k int;
  v_pend int; v_grace int; v_profit bigint; v_months numeric; v_goal int; v_over int; v_soon int; v_ren int;
  v_score int; v_hist jsonb; v_last int;
begin
  perform public._assert_platform_admin();
  s := public.company_summary();
  v_rev := public.admin_revenue();
  v_mrr := (s->'income'->>'mrr_net_paise')::bigint; v_prev := (s->'income'->>'mrr_prev_net_paise')::bigint;
  v_paying := (s->'customers'->>'paying')::int;

  -- 1 growth: monthly income now vs 30 days ago
  if v_prev = 0 and v_mrr = 0 then
    a := a || public._co_area('growth', null, null, 'No paying properties yet.', 'Get your first paying property.', 'leads.html');
  else
    v_g := case when v_prev > 0 then round((v_mrr - v_prev) * 100.0 / v_prev, 1) else 100 end;
    a := a || public._co_area('growth', case when v_g >= 5 then 'good' when v_g >= 0 then 'watch' else 'act' end,
               case when v_g >= 0 then '+' else '' end || v_g || '%', 'Monthly income now vs 30 days ago (target: 5%+ a month).',
               case when v_g < 0 then 'Monthly income went down — call properties that stopped paying.' when v_g < 5 then 'Growth is slow — follow up your open leads this week.' end,
               case when v_g < 0 then 'subscribers.html' else 'leads.html' end);
  end if;

  -- 2 customers leaving (30 days)
  v_churn := coalesce((v_rev->>'churned_30')::int, 0);
  if v_paying + v_churn = 0 then
    a := a || public._co_area('churn', null, null, 'No paying properties yet.', null, 'subscribers.html');
  else
    v_g := round(v_churn * 100.0 / (v_paying + v_churn), 1);
    a := a || public._co_area('churn', case when v_g <= 3 then 'good' when v_g <= 7 then 'watch' else 'act' end, v_churn || ' left · ' || v_g || '%',
               'Properties whose paid period ended in the last 30 days without renewing (target: 3% or less).',
               case when v_g > 3 then 'Call the ' || v_churn || ' that left — ask why, offer help or a coupon.' end, 'subscribers.html');
  end if;

  -- 3 trial → paid (properties added in the last 90 days)
  v_ct := coalesce((v_rev->'conversion_90'->>'trials')::int, 0); v_cp := coalesce((v_rev->'conversion_90'->>'paid')::int, 0);
  if v_ct < 3 then
    a := a || public._co_area('conversion', null, null, 'Needs at least 3 trials in the last 90 days.', null, 'admin.html');
  else
    v_g := round(v_cp * 100.0 / v_ct);
    a := a || public._co_area('conversion', case when v_g >= 30 then 'good' when v_g >= 15 then 'watch' else 'act' end, v_g || '% (' || v_cp || ' of ' || v_ct || ')',
               'Trials from the last 90 days that went on to pay (target: 30%+).',
               case when v_g < 30 then 'Call trials ending this week and help them set up.' end, 'admin.html');
  end if;

  -- 4 getting started: properties added 7–60 days ago with at least one booking
  select count(*), count(*) filter (where exists (select 1 from public.bookings b where b.property_id = p.id))
    into v_n, v_k from public.properties p join public.subscriptions su on su.property_id = p.id and not su.is_complimentary
   where p.created_at between now() - interval '60 days' and now() - interval '7 days';
  if v_n < 3 then
    a := a || public._co_area('activation', null, null, 'Needs at least 3 properties added 1–8 weeks ago.', null, 'admin.html');
  else
    v_g := round(v_k * 100.0 / v_n);
    a := a || public._co_area('activation', case when v_g >= 70 then 'good' when v_g >= 40 then 'watch' else 'act' end, v_g || '% (' || v_k || ' of ' || v_n || ')',
               'New properties (1–8 weeks old) that have added at least one booking (target: 70%+).',
               case when v_g < 70 then (v_n - v_k) || ' new properties have no bookings yet — offer a setup call.' end, 'admin.html');
  end if;

  -- 5 inactive paying customers: no booking added in 14 days
  if v_paying = 0 then
    a := a || public._co_area('inactive', null, null, 'No paying properties yet.', null, 'admin.html');
  else
    select count(*) into v_k from public.subscriptions su
     where su.paid_until > now() and not su.is_complimentary and not coalesce(su.is_suspended, false)
       and not exists (select 1 from public.bookings b where b.property_id = su.property_id and b.created_at > now() - interval '14 days');
    v_g := round(v_k * 100.0 / v_paying);
    a := a || public._co_area('inactive', case when v_g <= 10 then 'good' when v_g <= 25 then 'watch' else 'act' end, v_k || ' of ' || v_paying,
               'Paying properties that haven''t added a booking in 14 days (target: 10% or less). Quiet customers leave next.',
               case when v_g > 10 then 'Check on the ' || v_k || ' quiet properties before renewal time.' end, 'admin.html');
  end if;

  -- 6 money to collect: payments waiting for review > 2 days, properties past due (grace)
  select count(*) into v_pend from public.subscription_payments where status = 'pending' and submitted_at < now() - interval '2 days';
  select count(*) into v_grace from public.subscriptions su where public._access_state(su.property_id) = 'grace';
  a := a || public._co_area('collections', case when v_pend = 0 and v_grace = 0 then 'good' when v_pend <= 1 and v_grace <= 2 then 'watch' else 'act' end,
             case when v_pend + v_grace = 0 then 'All clear' else v_pend || ' to review · ' || v_grace || ' past due' end,
             'Payments owners sent that you haven''t checked for 2+ days, and properties past their paid date.',
             case when v_pend > 0 then 'Review ' || v_pend || ' payment' || case when v_pend = 1 then '' else 's' end || ' waiting more than 2 days.'
                  when v_grace > 0 then 'Remind ' || v_grace || ' propert' || case when v_grace = 1 then 'y' else 'ies' end || ' whose payment is due.' end, 'subscribers.html');

  -- 7 runway
  v_profit := (s->'run_rate'->>'profit_paise')::bigint; v_months := nullif(s->'runway'->>'months', '')::numeric; v_goal := (s->'runway'->>'goal_months')::int;
  if not exists (select 1 from public.company_costs) then
    a := a || public._co_area('runway', null, null, 'Add your monthly costs to see runway.', 'Add your monthly costs (salaries, servers, tools…).', 'company.html#costs');
  elsif v_profit >= 0 then
    a := a || public._co_area('runway', 'good', 'Self-funding', 'Income covers costs every month.', null, 'company.html');
  elsif v_months is null then
    a := a || public._co_area('runway', null, null, 'Spending more than earning — enter cash in bank to see how long it lasts.', 'Enter cash in bank to see your runway.', 'company.html#cash');
  else
    a := a || public._co_area('runway', case when v_months >= v_goal then 'good' when v_months >= 3 then 'watch' else 'act' end, v_months || ' months',
               'How long cash in bank lasts at today''s monthly loss (goal: ' || v_goal || ' months).',
               case when v_months < v_goal then 'Cut a cost or raise money — under ' || v_goal || ' months of cash left.' end, 'company.html');
  end if;

  -- 8 filings & renewals
  select count(*), count(*) filter (where due_on < v_today), count(*) filter (where due_on between v_today and v_today + 7)
    into v_ren, v_over, v_soon from public.company_renewals where done_on is null;
  if v_ren = 0 then
    a := a || public._co_area('filings', null, null, 'No filings or renewals added yet.', 'Add GST, ROC, domain and other due dates.', 'company.html#renewals');
  else
    a := a || public._co_area('filings', case when v_over > 0 then 'act' when v_soon > 0 then 'watch' else 'good' end,
               case when v_over > 0 then v_over || ' overdue' when v_soon > 0 then v_soon || ' due this week' else 'All on time' end,
               'GST, TDS, ROC, income tax, domain, trademark and other due dates you added.',
               case when v_over > 0 then 'File or renew the ' || v_over || ' overdue item' || case when v_over = 1 then '' else 's' end || ' — late fees add up.'
                    when v_soon > 0 then v_soon || ' due within 7 days — keep the documents ready.' end, 'company.html#renewals');
  end if;

  select round(avg((x->>'score')::int)) into v_score from jsonb_array_elements(a) x where x->>'status' is not null;
  if v_score is not null then
    insert into public.company_health_snapshots (week_start, score, areas) values (v_week, v_score, a)
    on conflict (week_start) do update set score = excluded.score, areas = excluded.areas, created_at = now();
  end if;
  select score into v_last from public.company_health_snapshots where week_start < v_week order by week_start desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('week', week_start, 'score', score) order by week_start), '[]'::jsonb) into v_hist
    from (select * from public.company_health_snapshots order by week_start desc limit 12) z;

  return jsonb_build_object('score', v_score,
    'verdict', case when v_score is null then null when v_score >= 75 then 'healthy' when v_score >= 50 then 'attention' else 'risk' end,
    'last_week', v_last, 'areas', a, 'history', v_hist,
    'counts', jsonb_build_object('good', (select count(*) from jsonb_array_elements(a) x where x->>'status' = 'good'),
                                 'watch', (select count(*) from jsonb_array_elements(a) x where x->>'status' = 'watch'),
                                 'act', (select count(*) from jsonb_array_elements(a) x where x->>'status' = 'act'),
                                 'nodata', (select count(*) from jsonb_array_elements(a) x where x->>'status' is null)));
end $$;

--
-- Name: company_income_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_income_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin perform public._assert_platform_admin(); delete from public.company_income where id = p_id; end $$;

--
-- Name: company_income_save(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_income_save(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := nullif(p->>'amount_paise', '')::bigint; v_on date := nullif(p->>'received_on', '')::date;
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'source', ''))) < 2 then raise exception 'Where did the money come from? e.g. "Setup fee — Hotel Arya".'; end if;
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_on is null then raise exception 'Pick the date.'; end if;
  if v_on > (now() at time zone 'Asia/Kolkata')::date then raise exception 'The date can''t be in the future.'; end if;
  if v_id is null then
    insert into public.company_income (received_on, amount_paise, source, note) values (v_on, v_amt, btrim(p->>'source'), nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_income set received_on = v_on, amount_paise = v_amt, source = btrim(p->>'source'), note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Entry not found.'; end if;
  end if;
  return v_id;
end $$;

--
-- Name: company_investment_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_investment_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin perform public._assert_platform_admin(); delete from public.company_investments where id = p_id; end $$;

--
-- Name: company_investment_save(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_investment_save(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_amt bigint := nullif(p->>'amount_paise', '')::bigint; v_on date := nullif(p->>'made_on', '')::date;
        v_src text := coalesce(nullif(p->>'source', ''), 'founder'); v_f uuid := nullif(p->>'founder_id', '')::uuid;
begin
  perform public._assert_platform_admin();
  if v_amt is null or v_amt < 100 then raise exception 'Enter the amount.'; end if;
  if v_on is null then raise exception 'Pick the date.'; end if;
  if v_on > (now() at time zone 'Asia/Kolkata')::date then raise exception 'The date can''t be in the future.'; end if;
  if v_src not in ('founder', 'investor', 'loan', 'grant', 'other') then raise exception 'Unknown source.'; end if;
  if v_f is not null and not exists (select 1 from public.company_founders where id = v_f) then raise exception 'Founder not found.'; end if;
  if v_id is null then
    insert into public.company_investments (made_on, amount_paise, source, founder_id, note)
    values (v_on, v_amt, v_src, v_f, nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_investments set made_on = v_on, amount_paise = v_amt, source = v_src, founder_id = v_f, note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Entry not found.'; end if;
  end if;
  return v_id;
end $$;

--
-- Name: company_profile_save(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_profile_save(p jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_cash bigint := nullif(p->>'cash_paise', '')::bigint; v_goal int := coalesce(nullif(p->>'runway_goal_months', '')::int, 6);
        v_started date := nullif(p->>'started_on', '')::date;
begin
  perform public._assert_platform_admin();
  if v_started is not null and v_started > (now() at time zone 'Asia/Kolkata')::date then raise exception 'The start date can''t be in the future.'; end if;
  if v_goal not between 1 and 36 then raise exception 'Runway goal: between 1 and 36 months.'; end if;
  if v_cash is not null and v_cash < 0 then raise exception 'Cash in bank can''t be negative.'; end if;
  insert into public.company_profile as c (id, started_on, cash_paise, cash_updated_on, runway_goal_months, updated_at)
  values (1, v_started, v_cash, case when v_cash is not null then (now() at time zone 'Asia/Kolkata')::date end, v_goal, now())
  on conflict (id) do update set started_on = excluded.started_on, runway_goal_months = excluded.runway_goal_months, updated_at = now(),
    cash_paise = excluded.cash_paise,
    cash_updated_on = case when excluded.cash_paise is distinct from c.cash_paise then excluded.cash_updated_on else c.cash_updated_on end;
end $$;

--
-- Name: company_renewal_delete(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_renewal_delete(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin perform public._assert_platform_admin(); delete from public.company_renewals where id = p_id; end $$;

--
-- Name: company_renewal_done(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_renewal_done(p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare r public.company_renewals%rowtype;
begin
  perform public._assert_platform_admin();
  select * into r from public.company_renewals where id = p_id for update;
  if not found then raise exception 'Item not found.'; end if;
  if r.repeat <> 'none' then
    update public.company_renewals set due_on = public._co_next_due(r.due_on, r.repeat) where id = p_id returning * into r;
  else
    update public.company_renewals set done_on = (now() at time zone 'Asia/Kolkata')::date where id = p_id returning * into r;
  end if;
  return jsonb_build_object('due_on', r.due_on, 'done_on', r.done_on);
end $$;

--
-- Name: company_renewal_save(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_renewal_save(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_kind text := coalesce(nullif(p->>'kind', ''), 'other');
        v_rep text := coalesce(nullif(p->>'repeat', ''), 'none'); v_due date := nullif(p->>'due_on', '')::date;
        v_amt bigint := nullif(p->>'amount_paise', '')::bigint;
begin
  perform public._assert_platform_admin();
  if char_length(btrim(coalesce(p->>'title', ''))) < 2 then raise exception 'Give it a name, e.g. "GSTR-3B".'; end if;
  if v_kind not in ('gst', 'tds', 'roc', 'itr', 'domain', 'ssl', 'trademark', 'server', 'licence', 'other') then raise exception 'Unknown type.'; end if;
  if v_rep not in ('none', 'month', 'quarter', 'year') then raise exception 'Choose how often it repeats.'; end if;
  if v_rep <> 'none' and v_due is null then raise exception 'A repeating item needs its next due date.'; end if;
  if v_id is null then
    insert into public.company_renewals (kind, title, due_on, repeat, amount_paise, note)
    values (v_kind, btrim(p->>'title'), v_due, v_rep, v_amt, nullif(btrim(p->>'note'), '')) returning id into v_id;
  else
    update public.company_renewals set kind = v_kind, title = btrim(p->>'title'), due_on = v_due, repeat = v_rep, amount_paise = v_amt,
           note = nullif(btrim(p->>'note'), '') where id = v_id;
    if not found then raise exception 'Item not found.'; end if;
  end if;
  return v_id;
end $$;

--
-- Name: company_summary(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.company_summary() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_rev jsonb; prof public.company_profile%rowtype;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_m0 date := public._co_month0(); v_start date;
  v_mrr bigint; v_mrr_net bigint; v_paying int; v_prev record;
  v_invested bigint; v_cum bigint := 0; v_pace bigint; v_costs_now bigint; v_other3 bigint; v_profit_now bigint;
  v_months jsonb; v_left bigint; v_be date; v_runway numeric; v_firsts date[]; v_ms jsonb;
  v_new30 int; v_new_m int; v_new90 int; v_mkt90 bigint; v_srv bigint; v_gst boolean;
begin
  perform public._assert_platform_admin();
  v_rev := public.admin_revenue();
  select * into prof from public.company_profile where id = 1;
  v_mrr := coalesce((v_rev->>'mrr_paise')::bigint, 0); v_mrr_net := public._co_net(v_mrr);
  v_paying := coalesce((v_rev->>'paying')::int, 0);
  select * into v_prev from public._co_paying_at(now() - interval '30 days');
  select coalesce(sum(amount_paise), 0) into v_invested from public.company_investments;
  v_gst := exists (select 1 from public.platform_settings where id = 1 and gstin is not null);

  -- first month counted for payback
  v_start := coalesce(date_trunc('month', prof.started_on)::date,
               least((select date_trunc('month', min(made_on))::date from public.company_investments),
                     (select date_trunc('month', min(starts_on))::date from public.company_costs),
                     (select date_trunc('month', min(reviewed_at at time zone 'Asia/Kolkata'))::date from public.subscription_payments where status = 'approved')),
               v_m0);
  v_start := greatest(least(v_start, v_m0), (v_m0 - interval '10 years')::date);

  -- month by month since the start (income after GST, other income, costs)
  with mm as (
    select g::date m,
           public._co_net((select coalesce(sum(sp.amount_paise), 0) from public.subscription_payments sp
                            where sp.status = 'approved' and date_trunc('month', sp.reviewed_at at time zone 'Asia/Kolkata')::date = g::date)) sub,
           (select coalesce(sum(i.amount_paise), 0) from public.company_income i where date_trunc('month', i.received_on)::date = g::date) oth,
           public._co_month_costs(g::date) cost
      from generate_series(v_start, v_m0, interval '1 month') g)
  select coalesce((select sum(sub + oth - cost) from mm), 0),
         (select round(avg(sub + oth - cost)) from (select * from mm where m < v_m0 order by m desc limit 3) z),
         coalesce((select sum(oth) from mm where m < v_m0 and m >= (v_m0 - interval '3 months')::date), 0),
         (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'income_paise', sub + oth, 'subscriptions_paise', sub,
                   'other_paise', oth, 'costs_paise', cost, 'profit_paise', sub + oth - cost) order by m), '[]'::jsonb)
            from (select * from mm order by m desc limit 12) z)
    into v_cum, v_pace, v_other3, v_months;

  -- run rate today: MRR (after GST) + average other income − monthly costs
  select coalesce(sum(case when every = 'month' then amount_paise else round(amount_paise / 12.0) end), 0)
    into v_costs_now from public.company_costs
   where every <> 'once' and starts_on <= v_today and (ends_on is null or ends_on >= v_today);
  v_profit_now := v_mrr_net + round(v_other3 / 3.0)::bigint - v_costs_now;
  v_pace := coalesce(v_pace, v_profit_now);

  v_left := greatest(v_invested - greatest(v_cum, 0), 0);
  if v_invested > 0 and v_left = 0 then v_be := v_today;
  elsif v_left > 0 and greatest(v_pace, v_profit_now) > 0 then
    v_be := (v_m0 + make_interval(months => ceil(v_left::numeric / greatest(v_pace, v_profit_now))::int))::date;
  end if;
  v_runway := case when v_profit_now >= 0 then null when prof.cash_paise is null then null
                   else round(prof.cash_paise::numeric / (-v_profit_now), 1) end;

  -- milestones: the day the Nth property first paid
  select array_agg(f order by f) into v_firsts from (
    select min(sp.reviewed_at at time zone 'Asia/Kolkata')::date f from public.subscription_payments sp
      join public.subscriptions s on s.property_id = sp.property_id and not s.is_complimentary
     where sp.status = 'approved' group by sp.property_id) z;
  select jsonb_agg(jsonb_build_object('target', t, 'reached_on', v_firsts[t], 'kind', 'properties') order by t) into v_ms
    from unnest(array[1, 10, 25, 50, 100, 250, 500, 1000]) t;
  v_new30 := (select count(*) from unnest(coalesce(v_firsts, '{}')) f where f > v_today - 30);
  v_new_m := (select count(*) from unnest(coalesce(v_firsts, '{}')) f where f >= v_m0);
  v_new90 := (select count(*) from unnest(coalesce(v_firsts, '{}')) f where f > v_today - 90);
  -- marketing spent in the last 90 days (for cost to win one customer)
  select coalesce(sum(case when c.every = 'once' then case when c.starts_on > v_today - 90 then c.amount_paise else 0 end
                           else (case when c.every = 'month' then c.amount_paise else c.amount_paise / 12.0 end)
                                * greatest(0, least(3.0, ((least(coalesce(c.ends_on, v_today), v_today) - greatest(c.starts_on, v_today - 90)) + 1) / 30.0)) end), 0)::bigint
    into v_mkt90 from public.company_costs c where c.category = 'marketing';
  select coalesce(sum(case when every = 'month' then amount_paise else round(amount_paise / 12.0) end), 0) into v_srv
    from public.company_costs where category = 'servers' and every <> 'once' and starts_on <= v_today and (ends_on is null or ends_on >= v_today);

  return jsonb_build_object(
    'profile', jsonb_build_object('started_on', prof.started_on, 'counted_from', v_start, 'cash_paise', prof.cash_paise,
                 'cash_updated_on', prof.cash_updated_on, 'runway_goal_months', coalesce(prof.runway_goal_months, 6)),
    'gst_registered', v_gst,
    'income', jsonb_build_object('mrr_paise', v_mrr, 'mrr_net_paise', v_mrr_net, 'mrr_prev_net_paise', public._co_net(v_prev.mrr_paise),
                 'other_avg_paise', round(v_other3 / 3.0)::bigint),
    'customers', jsonb_build_object('paying', v_paying, 'paying_prev', v_prev.paying, 'trials', coalesce((v_rev->>'trials')::int, 0),
                 'new_this_month', v_new_m, 'new_30d', v_new30, 'new_90d', v_new90, 'churned_30d', coalesce((v_rev->>'churned_30')::int, 0)),
    'run_rate', jsonb_build_object('income_paise', v_mrr_net + round(v_other3 / 3.0)::bigint, 'costs_paise', v_costs_now, 'profit_paise', v_profit_now),
    'payback', jsonb_build_object('invested_paise', v_invested, 'recovered_paise', least(greatest(v_cum, 0), v_invested),
                 'profit_so_far_paise', v_cum, 'left_paise', v_left, 'pace_paise', v_pace,
                 'pct', case when v_invested > 0 then least(100, floor(greatest(v_cum, 0) * 100.0 / v_invested)) else 0 end,
                 'break_even_on', v_be),
    'runway', jsonb_build_object('self_funding', v_profit_now >= 0, 'months', v_runway, 'burn_paise', greatest(-v_profit_now, 0),
                 'cash_paise', prof.cash_paise, 'goal_months', coalesce(prof.runway_goal_months, 6)),
    'months', v_months,
    'milestones', v_ms,
    'costs', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'category', c.category, 'every', c.every,
                 'amount_paise', c.amount_paise, 'starts_on', c.starts_on, 'ends_on', c.ends_on, 'note', c.note,
                 'running', c.every <> 'once' and c.starts_on <= v_today and (c.ends_on is null or c.ends_on >= v_today))
                 order by (c.every <> 'once' and (c.ends_on is null or c.ends_on >= v_today)) desc, c.category, c.amount_paise desc), '[]'::jsonb)
              from public.company_costs c where c.every <> 'once' or c.starts_on > v_today - 365),
    'cost_split', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'monthly_paise', amt) order by amt desc), '[]'::jsonb) from (
                 select category, sum(case when every = 'month' then amount_paise else round(amount_paise / 12.0) end)::bigint amt
                   from public.company_costs where every <> 'once' and starts_on <= v_today and (ends_on is null or ends_on >= v_today)
                  group by category) z),
    'income_list', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'received_on', i.received_on, 'amount_paise', i.amount_paise,
                 'source', i.source, 'note', i.note) order by i.received_on desc), '[]'::jsonb)
              from public.company_income i where i.received_on > v_today - 365),
    'investments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'made_on', x.made_on, 'amount_paise', x.amount_paise, 'source', x.source,
                 'founder_id', x.founder_id, 'founder', f.name, 'note', x.note) order by x.made_on desc), '[]'::jsonb)
              from public.company_investments x left join public.company_founders f on f.id = x.founder_id),
    'founders', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'role', f.role, 'share_pct', f.share_pct, 'is_me', f.is_me,
                 'invested_paise', (select coalesce(sum(amount_paise), 0) from public.company_investments x where x.founder_id = f.id))
                 order by f.is_me desc, f.share_pct desc, f.name), '[]'::jsonb) from public.company_founders f),
    'renewals', public._co_renewals(),
    'unit', jsonb_build_object(
                 'arpu_paise', case when v_paying > 0 then v_mrr_net / v_paying end,
                 'cost_per_property_paise', case when v_paying > 0 then v_costs_now / v_paying end,
                 'server_per_property_paise', case when v_paying > 0 then v_srv / v_paying end,
                 'cac_paise', case when v_new90 > 0 then v_mkt90 / v_new90 end,
                 'cac_payback_months', case when v_new90 > 0 and v_paying > 0 and v_mrr_net > 0 then round((v_mkt90::numeric / v_new90) / (v_mrr_net::numeric / v_paying), 1) end,
                 'marketing_90d_paise', v_mkt90)
  );
end $$;

--
-- Name: company_costs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_costs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    category text NOT NULL,
    every text NOT NULL,
    amount_paise bigint NOT NULL,
    starts_on date NOT NULL,
    ends_on date,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_costs_amount_paise_check CHECK (((amount_paise >= 100) AND (amount_paise <= '100000000000'::bigint))),
    CONSTRAINT company_costs_category_check CHECK ((category = ANY (ARRAY['salaries'::text, 'marketing'::text, 'servers'::text, 'tools'::text, 'office'::text, 'compliance'::text, 'other'::text]))),
    CONSTRAINT company_costs_check CHECK (((ends_on IS NULL) OR (ends_on >= starts_on))),
    CONSTRAINT company_costs_every_check CHECK ((every = ANY (ARRAY['month'::text, 'year'::text, 'once'::text]))),
    CONSTRAINT company_costs_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 80))),
    CONSTRAINT company_costs_note_check CHECK ((char_length(note) <= 200))
);

--
-- Name: company_founders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_founders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    role text,
    share_pct numeric(5,2) NOT NULL,
    is_me boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_founders_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 60))),
    CONSTRAINT company_founders_role_check CHECK ((char_length(role) <= 60)),
    CONSTRAINT company_founders_share_pct_check CHECK (((share_pct >= (0)::numeric) AND (share_pct <= (100)::numeric)))
);

--
-- Name: company_health_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_health_snapshots (
    week_start date NOT NULL,
    score integer NOT NULL,
    areas jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_health_snapshots_score_check CHECK (((score >= 0) AND (score <= 100)))
);

--
-- Name: company_income; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_income (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    received_on date NOT NULL,
    amount_paise bigint NOT NULL,
    source text NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_income_amount_paise_check CHECK (((amount_paise >= 100) AND (amount_paise <= '100000000000'::bigint))),
    CONSTRAINT company_income_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT company_income_source_check CHECK (((char_length(btrim(source)) >= 2) AND (char_length(btrim(source)) <= 80)))
);

--
-- Name: company_investments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_investments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    made_on date NOT NULL,
    amount_paise bigint NOT NULL,
    source text DEFAULT 'founder'::text NOT NULL,
    founder_id uuid,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_investments_amount_paise_check CHECK (((amount_paise >= 100) AND (amount_paise <= '100000000000000'::bigint))),
    CONSTRAINT company_investments_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT company_investments_source_check CHECK ((source = ANY (ARRAY['founder'::text, 'investor'::text, 'loan'::text, 'grant'::text, 'other'::text])))
);

--
-- Name: company_profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_profile (
    id smallint DEFAULT 1 NOT NULL,
    started_on date,
    cash_paise bigint,
    cash_updated_on date,
    runway_goal_months integer DEFAULT 6 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_profile_cash_paise_check CHECK (((cash_paise IS NULL) OR ((cash_paise >= 0) AND (cash_paise <= '100000000000000'::bigint)))),
    CONSTRAINT company_profile_id_check CHECK ((id = 1)),
    CONSTRAINT company_profile_runway_goal_months_check CHECK (((runway_goal_months >= 1) AND (runway_goal_months <= 36)))
);

--
-- Name: company_renewals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_renewals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind text NOT NULL,
    title text NOT NULL,
    due_on date,
    repeat text DEFAULT 'none'::text NOT NULL,
    amount_paise bigint,
    done_on date,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_renewals_amount_paise_check CHECK (((amount_paise IS NULL) OR ((amount_paise >= 0) AND (amount_paise <= '100000000000'::bigint)))),
    CONSTRAINT company_renewals_kind_check CHECK ((kind = ANY (ARRAY['gst'::text, 'tds'::text, 'roc'::text, 'itr'::text, 'domain'::text, 'ssl'::text, 'trademark'::text, 'server'::text, 'licence'::text, 'other'::text]))),
    CONSTRAINT company_renewals_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT company_renewals_repeat_check CHECK ((repeat = ANY (ARRAY['none'::text, 'month'::text, 'quarter'::text, 'year'::text]))),
    CONSTRAINT company_renewals_title_check CHECK (((char_length(btrim(title)) >= 2) AND (char_length(btrim(title)) <= 80)))
);

--
-- Name: company_costs company_costs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_costs
    ADD CONSTRAINT company_costs_pkey PRIMARY KEY (id);

--
-- Name: company_founders company_founders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_founders
    ADD CONSTRAINT company_founders_pkey PRIMARY KEY (id);

--
-- Name: company_health_snapshots company_health_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_health_snapshots
    ADD CONSTRAINT company_health_snapshots_pkey PRIMARY KEY (week_start);

--
-- Name: company_income company_income_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_income
    ADD CONSTRAINT company_income_pkey PRIMARY KEY (id);

--
-- Name: company_investments company_investments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_investments
    ADD CONSTRAINT company_investments_pkey PRIMARY KEY (id);

--
-- Name: company_profile company_profile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_profile
    ADD CONSTRAINT company_profile_pkey PRIMARY KEY (id);

--
-- Name: company_renewals company_renewals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_renewals
    ADD CONSTRAINT company_renewals_pkey PRIMARY KEY (id);

--
-- Name: company_investments company_investments_founder_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_investments
    ADD CONSTRAINT company_investments_founder_id_fkey FOREIGN KEY (founder_id) REFERENCES public.company_founders(id) ON DELETE SET NULL;

--
-- Name: company_costs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_costs ENABLE ROW LEVEL SECURITY;

--
-- Name: company_founders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_founders ENABLE ROW LEVEL SECURITY;

--
-- Name: company_health_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_health_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: company_income; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_income ENABLE ROW LEVEL SECURITY;

--
-- Name: company_investments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_investments ENABLE ROW LEVEL SECURITY;

--
-- Name: company_profile; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_profile ENABLE ROW LEVEL SECURITY;

--
-- Name: company_renewals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.company_renewals ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION _co_area(p_key text, p_status text, p_value text, p_detail text, p_todo text, p_link text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._co_area(p_key text, p_status text, p_value text, p_detail text, p_todo text, p_link text) FROM PUBLIC;

--
-- Name: FUNCTION _co_month0(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._co_month0() FROM PUBLIC;

--
-- Name: FUNCTION _co_month_costs(p_month date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._co_month_costs(p_month date) FROM PUBLIC;

--
-- Name: FUNCTION _co_net(p_paise numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._co_net(p_paise numeric) FROM PUBLIC;

--
-- Name: FUNCTION _co_next_due(p_due date, p_repeat text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._co_next_due(p_due date, p_repeat text) FROM PUBLIC;

--
-- Name: FUNCTION _co_paying_at(p_at timestamp with time zone, OUT mrr_paise bigint, OUT paying integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._co_paying_at(p_at timestamp with time zone, OUT mrr_paise bigint, OUT paying integer) FROM PUBLIC;

--
-- Name: FUNCTION _co_renewals(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._co_renewals() FROM PUBLIC;

--
-- Name: FUNCTION company_badge(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_badge() FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_badge() TO authenticated;

--
-- Name: FUNCTION company_cost_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_cost_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_cost_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION company_cost_save(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_cost_save(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_cost_save(p jsonb) TO authenticated;

--
-- Name: FUNCTION company_founder_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_founder_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_founder_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION company_founder_save(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_founder_save(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_founder_save(p jsonb) TO authenticated;

--
-- Name: FUNCTION company_health(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_health() FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_health() TO authenticated;

--
-- Name: FUNCTION company_income_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_income_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_income_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION company_income_save(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_income_save(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_income_save(p jsonb) TO authenticated;

--
-- Name: FUNCTION company_investment_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_investment_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_investment_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION company_investment_save(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_investment_save(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_investment_save(p jsonb) TO authenticated;

--
-- Name: FUNCTION company_profile_save(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_profile_save(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_profile_save(p jsonb) TO authenticated;

--
-- Name: FUNCTION company_renewal_delete(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_renewal_delete(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_renewal_delete(p_id uuid) TO authenticated;

--
-- Name: FUNCTION company_renewal_done(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_renewal_done(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_renewal_done(p_id uuid) TO authenticated;

--
-- Name: FUNCTION company_renewal_save(p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_renewal_save(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_renewal_save(p jsonb) TO authenticated;

--
-- Name: FUNCTION company_summary(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.company_summary() FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_summary() TO authenticated;
