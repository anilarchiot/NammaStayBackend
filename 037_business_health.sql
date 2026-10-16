-- =====================================================================
-- NammaStay · 037_business_health.sql — Business health (report card)
--
-- One score out of 100 from the property's own data, 8 areas with green / amber / red,
-- and the top things to do:
--   occupancy · pricing · profit · cash (unpaid dues) · booking mix (direct vs OTA)
--   guests (cancellations, no-shows, repeat guests) · compliance (documents, 036) · payback (036)
-- Mostly compares the property with ITSELF (last 30 days vs the 30 before, and vs last year).
-- Areas without enough data say "unknown" and are left out of the score.
--
-- Owner: every area. Manager: an operations view (occupancy, cash, booking mix, guests) — no
-- profit, payback or documents. Others: refused.
-- A snapshot is kept per week (trend), and once a week the owners get a summary in the bell.
--
-- ADD-ON ONLY — new table + functions; reads existing tables; nothing existing is changed.
-- Works with or without 036_investment.sql (then compliance and payback are skipped).
-- Safe to run more than once. Rollback: rollback_037_business_health.sql
-- =====================================================================

create table if not exists public.business_health_snapshots (
  property_id uuid not null references public.properties(id) on delete cascade,
  week_start  date not null,
  score       int check (score between 0 and 100),
  areas       jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (property_id, week_start)
);
alter table public.business_health_snapshots enable row level security;
revoke all on public.business_health_snapshots from anon, authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function public._bh_tz(p_property uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata')
$$;

-- Occupied bed/room-nights in [p_from, p_to] (bookings + OTA calendar blocks + PG tenancies), units, full nights.
create or replace function public._bh_occ(p_property uuid, p_from date, p_to date,
  out units int, out available bigint, out occupied bigint, out full_nights int, out ota_nights bigint, out direct_nights bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
end $$;

-- Money received in [p_from, p_to] (payments − refunds, + PG rent, + resort day visitors).
create or replace function public._bh_income(p_property uuid, p_from date, p_to date) returns bigint
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
end $$;

create or replace function public._bh_area(p_key text, p_title text, p_status text, p_value text, p_detail text, p_how text, p_tip text, p_weight int)
returns jsonb language sql immutable as $$
  select jsonb_build_object('key', p_key, 'title', p_title, 'status', p_status, 'value', p_value, 'detail', p_detail,
           'how', p_how, 'tip', case when p_status in ('amber', 'red', 'unknown') then p_tip end, 'weight', p_weight)
$$;

-- ---------------------------------------------------------------- the report card
create or replace function public.business_health(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

-- ---------------------------------------------------------------- grants
do $$
declare f text;
begin
  execute 'revoke execute on function public.business_health(uuid) from public, anon';
  execute 'grant execute on function public.business_health(uuid) to authenticated';
  foreach f in array array['_bh_tz(uuid)', '_bh_occ(uuid,date,date)', '_bh_income(uuid,date,date)',
    '_bh_area(text,text,text,text,text,text,text,integer)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

select to_regprocedure('public.business_health(uuid)') is not null as business_health_installed;
