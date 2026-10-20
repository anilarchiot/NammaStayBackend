-- =====================================================================
-- NammaStay · 039_my_business.sql — My business: loans, partners, lease (owner only)
--
-- Adds three cards to My investment (now called "My business"). Each card only shows if the
-- owner answers "yes" to its question:
--   • Loans & EMIs   EMI, interest paid so far, amount still owed, payoff date, reminder before each EMI.
--                    Payback is shown AFTER loan interest ("real payback"), unless the owner says the
--                    EMIs are already entered as expenses (then nothing is counted twice).
--   • Partners       who put in what, profit share %, each partner's share of profit so far, payouts,
--                    balance due, statement to share.
--   • Lease          start / end, rent increase every N months, deposit, lock-in, notice period;
--                    compares break-even with the lease end ("break even before you have to leave?");
--                    reminders 180 / 90 / 30 days before the lease ends, before a rent increase and
--                    before the notice deadline.
--
-- Needs 036_investment.sql (My investment). OWNER ONLY, like 036.
-- ADD-ON ONLY — new tables and functions, plus one nullable column investments.partner_id (036's own
-- table, "who paid for this"). Nothing in the live app's own tables changes.
-- Safe to run more than once. Rollback: rollback_039_my_business.sql
-- =====================================================================

do $$ begin
  if to_regprocedure('public.invest_summary(uuid)') is null then
    raise exception 'Run 036_investment.sql (My investment) first.';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.business_profile (
  property_id     uuid primary key references public.properties(id) on delete cascade,
  has_loan        boolean,                     -- null = not answered yet
  has_partners    boolean,
  is_rented       boolean,
  emi_in_expenses boolean not null default false,   -- EMIs already entered in Expenses → don't subtract interest again
  updated_at      timestamptz not null default now()
);

create table if not exists public.business_loans (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  lender        text not null check (char_length(btrim(lender)) between 2 and 80),
  principal_paise bigint not null check (principal_paise between 100 and 100000000000),
  rate_pct      numeric(5,2) not null check (rate_pct between 0 and 60),
  tenure_months int not null check (tenure_months between 1 and 360),
  emi_paise     bigint check (emi_paise is null or emi_paise > 0),   -- null = worked out from amount, rate, months
  first_emi_on  date not null,
  closed_on     date,                                                  -- closed early / prepaid
  note          text check (char_length(note) <= 200),
  created_at    timestamptz not null default now()
);
create index if not exists business_loans_property on public.business_loans (property_id);

create table if not exists public.business_partners (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 2 and 60),
  phone       text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  share_pct   numeric(5,2) not null check (share_pct > 0 and share_pct <= 100),
  is_me       boolean not null default false,                         -- the owner's own row
  note        text check (char_length(note) <= 200),
  created_at  timestamptz not null default now()
);
create index if not exists business_partners_property on public.business_partners (property_id);
create unique index if not exists business_partners_one_me on public.business_partners (property_id) where is_me;

create table if not exists public.partner_payouts (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  partner_id   uuid not null references public.business_partners(id) on delete cascade,
  amount_paise bigint not null check (amount_paise between 100 and 100000000000),
  paid_on      date not null,
  note         text check (char_length(note) <= 200),
  created_at   timestamptz not null default now()
);
create index if not exists partner_payouts_partner on public.partner_payouts (partner_id, paid_on);

create table if not exists public.business_lease (
  property_id      uuid primary key references public.properties(id) on delete cascade,
  landlord         text check (char_length(landlord) <= 80),
  start_on         date not null,
  end_on           date not null,
  rent_paise       bigint not null check (rent_paise between 0 and 100000000000),   -- monthly rent at the start
  increase_pct     numeric(5,2) not null default 0 check (increase_pct between 0 and 50),
  increase_every_months int not null default 12 check (increase_every_months between 1 and 120),
  deposit_paise    bigint not null default 0 check (deposit_paise >= 0),
  lock_in_months   int not null default 0 check (lock_in_months between 0 and 240),
  notice_months    int not null default 0 check (notice_months between 0 and 24),
  note             text check (char_length(note) <= 200),
  updated_at       timestamptz not null default now(),
  check (end_on > start_on)
);

create table if not exists public.business_reminders (      -- which reminders were already sent (no repeats)
  property_id uuid not null references public.properties(id) on delete cascade,
  key         text not null,
  sent_at     timestamptz not null default now(),
  primary key (property_id, key)
);

alter table public.investments add column if not exists partner_id uuid references public.business_partners(id) on delete set null;

do $$ declare t text; begin
  foreach t in array array['business_profile','business_loans','business_partners','partner_payouts','business_lease','business_reminders'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);    -- owner reads/writes only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- loan maths (equal monthly instalments)
create or replace function public._biz_months(p_from date, p_to date) returns int
language sql immutable as $$
  select (extract(year from age(p_to, p_from)) * 12 + extract(month from age(p_to, p_from)))::int
$$;

create or replace function public._biz_loan(l public.business_loans, p_today date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------- lease maths
create or replace function public._biz_lease(b public.business_lease, p_today date) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------- reminders in the bell (once each)
create or replace function public._biz_remind(p_property uuid, p_key text, p_title text, p_body text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.business_reminders (property_id, key) values (p_property, p_key) on conflict do nothing;
  if not found then return 0; end if;
  insert into public.notifications (property_id, user_id, kind, title, body)
  select p_property, m.user_id, 'my_business', p_title, p_body from public.property_members m where m.property_id = p_property and m.role = 'owner';
  return 1;
end $$;

create or replace function public._biz_notify(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.biz_remind_all() returns int        -- optional daily job (pg_cron)
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; n int := 0;
begin
  for pid in select property_id from public.business_loans where closed_on is null union select property_id from public.business_lease loop
    n := n + public._biz_notify(pid);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- the whole picture (owner)
create or replace function public.biz_summary(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------- saving (owner)
-- p: { has_loan?, has_partners?, is_rented?, emi_in_expenses? }  (only the keys sent are changed)
create or replace function public.biz_profile_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- p: { id?, lender, principal_paise, rate_pct, tenure_months, emi_paise?, first_emi_on, closed_on?, note? }
create or replace function public.biz_loan_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.biz_loan_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.business_loans where id = p_id;
  if v_prop is null then raise exception 'Loan not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.business_loans where id = p_id;
  return public.biz_summary(v_prop);
end $$;

-- p: { id?, name, phone?, share_pct, is_me?, note? }
create or replace function public.biz_partner_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

create or replace function public.biz_partner_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.business_partners where id = p_id;
  if v_prop is null then raise exception 'Partner not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.business_partners where id = p_id;          -- payouts go with them; their investments become "unassigned"
  return public.biz_summary(v_prop);
end $$;

-- Who paid for an investment item (null = not set / the owner)
create or replace function public.biz_investment_partner(p_investment uuid, p_partner uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- p: { id?, partner_id, amount_paise, paid_on, note? }
create or replace function public.biz_payout_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.biz_payout_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.partner_payouts where id = p_id;
  if v_prop is null then raise exception 'Payout not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.partner_payouts where id = p_id;
  return public.biz_summary(v_prop);
end $$;

-- p: { landlord?, start_on, end_on, rent_paise, increase_pct?, increase_every_months?, deposit_paise?, lock_in_months?, notice_months?, note? }
create or replace function public.biz_lease_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------- who may call what
do $$ declare f text; begin
  foreach f in array array['biz_summary(uuid)','biz_profile_save(uuid,jsonb)','biz_loan_save(uuid,jsonb)','biz_loan_delete(uuid)',
      'biz_partner_save(uuid,jsonb)','biz_partner_delete(uuid)','biz_investment_partner(uuid,uuid)','biz_payout_save(uuid,jsonb)',
      'biz_payout_delete(uuid)','biz_lease_save(uuid,jsonb)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
  foreach f in array array['_biz_months(date,date)','_biz_loan(public.business_loans,date)','_biz_lease(public.business_lease,date)',
      '_biz_remind(uuid,text,text,text)','_biz_notify(uuid)','biz_remind_all()'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

-- Check: should say true
select to_regclass('public.business_loans') is not null and to_regclass('public.business_partners') is not null
   and to_regclass('public.business_lease') is not null as my_business_installed;
