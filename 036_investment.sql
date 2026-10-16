-- =====================================================================
-- NammaStay · 036_investment.sql — My investment (owner only)
--
--   • Investments      what the owner put in (interiors, deposit, beds, later upgrades)
--   • Payback          profit since opening (income − expenses) against the money invested,
--                      % paid back, estimated break-even at the last 3 months' pace
--   • Milestones       first booking, first month in profit, first ₹1 lakh month,
--                      10 / 25 / 50 / 75 % paid back, break-even, 100 / 1,000 guests
--   • Licences checklist  what a hostel / homestay / PG / hotel / resort usually needs in the
--                      owner's state (the list itself is in the app: licences-data.js); items tick
--                      when the document is uploaded, or the owner marks them done / not needed
--   • Legal documents  licences, NOCs, agreements with expiry dates; files in a PRIVATE
--                      storage bucket "owner-docs"; reminders in the bell 30, 15 and 3 days
--                      before expiry, and when expired
--
-- OWNER ONLY: every function checks the owner role; managers, front desk and accountants
-- cannot read investments or documents (tables have no grants; files: owner-only policies).
--
-- Income = payments (refunds subtracted), plus PG rent (pg_rent_payments / rent_payments) and resort
-- day-visitor payments (resort_payments) when those tables exist. Expenses = expenses table.
--
-- ADD-ON ONLY — new tables, functions, one storage bucket; nothing existing is changed.
-- Safe to run more than once. Rollback: rollback_036_investment.sql
-- =====================================================================

-- ---------------------------------------------------------------- tables
create table if not exists public.investment_settings (
  property_id  uuid primary key references public.properties(id) on delete cascade,
  opened_on    date not null,
  updated_at   timestamptz not null default now()
);

create table if not exists public.investments (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  title         text not null check (char_length(btrim(title)) between 1 and 80),
  note          text check (char_length(note) <= 200),
  amount_paise  bigint not null check (amount_paise > 0 and amount_paise <= 100000000000),
  invested_on   date not null,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists investments_property on public.investments (property_id, invested_on);

create table if not exists public.legal_documents (
  id             uuid primary key default gen_random_uuid(),
  property_id    uuid not null references public.properties(id) on delete cascade,
  doc_type       text not null check (doc_type in ('trade_licence','fire_noc','fssai','gst','police','tourism','rental_agreement','lease_deed','insurance','building_approval','pollution','partnership','other',
                   'shops_establishment','professional_tax','frro','music','liquor','lift','labour','hostel_licence','environment','classification','rwa_noc')),
  title          text not null check (char_length(btrim(title)) between 1 and 80),
  doc_number     text check (char_length(doc_number) <= 60),
  issued_on      date,
  expires_on     date,
  note           text check (char_length(note) <= 300),
  file_path      text check (char_length(file_path) <= 300),
  file_name      text check (char_length(file_name) <= 160),
  file_size      int check (file_size between 0 and 10485760),
  reminded_level smallint not null default 0,   -- 0 none · 30 · 15 · 3 · -1 expired (bell reminders sent)
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (expires_on is null or issued_on is null or expires_on >= issued_on)
);
create index if not exists legal_documents_property on public.legal_documents (property_id, expires_on);

-- Licences checklist (state + property type picked by the owner; items marked "not needed" or "done without a file")
alter table public.investment_settings add column if not exists state_code text check (state_code ~ '^[0-9]{2}$');
alter table public.investment_settings add column if not exists checklist_kind text check (checklist_kind in ('hostel','homestay','pg','hotel','resort'));
alter table public.legal_documents drop constraint if exists legal_documents_doc_type_check;   -- (re)set the list of document types
alter table public.legal_documents add constraint legal_documents_doc_type_check check (doc_type in ('trade_licence','fire_noc','fssai','gst','police','tourism','rental_agreement','lease_deed','insurance','building_approval','pollution','partnership','other',
                   'shops_establishment','professional_tax','frro','music','liquor','lift','labour','hostel_licence','environment','classification','rwa_noc'));
create table if not exists public.legal_checklist (
  property_id  uuid not null references public.properties(id) on delete cascade,
  item_key     text not null check (item_key ~ '^[a-z0-9_]{1,40}$'),
  status       text not null check (status in ('not_needed','done')),
  updated_at   timestamptz not null default now(),
  primary key (property_id, item_key)
);

do $$
declare t text;
begin
  foreach t in array array['investment_settings','investments','legal_documents','legal_checklist'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);   -- owner reads/writes only through the functions below
  end loop;
end $$;

-- ---------------------------------------------------------------- private file storage (owner only)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('owner-docs', 'owner-docs', false, 10485760, array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Path layout: {property_id}/{random}.{ext}
drop policy if exists "owner-docs: owner read" on storage.objects;
create policy "owner-docs: owner read" on storage.objects for select to authenticated
  using (bucket_id = 'owner-docs' and exists (
    select 1 from public.my_property_ids(array['owner']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "owner-docs: owner upload" on storage.objects;
create policy "owner-docs: owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'owner-docs' and exists (
    select 1 from public.my_property_ids(array['owner']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));
drop policy if exists "owner-docs: owner delete" on storage.objects;
create policy "owner-docs: owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'owner-docs' and exists (
    select 1 from public.my_property_ids(array['owner']::public.member_role[]) pid where pid::text = (storage.foldername(name))[1]));

-- ---------------------------------------------------------------- helpers
create or replace function public._inv_owner(p_property uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_property is null then raise exception 'Property missing.'; end if;
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
end $$;

create or replace function public._inv_today(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (now() at time zone coalesce((select timezone from public.properties where id = p_property), 'Asia/Kolkata'))::date
$$;

create or replace function public._inv_opened_on(p_property uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select opened_on from public.investment_settings where property_id = p_property),
    (select min(check_in_at)::date from public.bookings where property_id = p_property),
    (select created_at::date from public.properties where id = p_property))
$$;

-- Income and expenses per month from p_from's month to this month.
create or replace function public._inv_months(p_property uuid, p_from date)
returns table (month date, revenue_paise bigint, expenses_paise bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
end $$;

-- Bell reminders 30 / 15 / 3 days before expiry, and once when expired (to every owner of the property).
create or replace function public._legal_docs_notify(p_property uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------- payback summary
create or replace function public.invest_summary(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.invest_settings_save(p_property uuid, p_opened_on date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._inv_owner(p_property);
  if p_opened_on is null or p_opened_on > public._inv_today(p_property) then raise exception 'Choose the date your property opened (not in the future).'; end if;
  if p_opened_on < date '1990-01-01' then raise exception 'That opening date looks wrong.'; end if;
  insert into public.investment_settings (property_id, opened_on) values (p_property, p_opened_on)
  on conflict (property_id) do update set opened_on = excluded.opened_on, updated_at = now();
  return jsonb_build_object('opened_on', p_opened_on);
end $$;

create or replace function public.investment_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.investment_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.investments where id = p_id;
  if v_prop is null then raise exception 'Investment not found.'; end if;
  perform public._inv_owner(v_prop);
  delete from public.investments where id = p_id;
end $$;

-- ---------------------------------------------------------------- legal documents
create or replace function public.legal_docs_list(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.legal_doc_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.legal_doc_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.legal_documents;
begin
  select * into d from public.legal_documents where id = p_id;
  if d.id is null then raise exception 'Document not found.'; end if;
  perform public._inv_owner(d.property_id);
  delete from public.legal_documents where id = p_id;
  return jsonb_build_object('file_path', d.file_path);   -- the app removes the file from storage
end $$;

-- Dashboard: documents expired or expiring within 30 days (owner only; others get nothing).
create or replace function public.legal_docs_alerts(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- Licences checklist: the owner's state + property type, and items marked by hand.
create or replace function public.legal_checklist_get(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._inv_owner(p_property);
  return jsonb_build_object(
    'state_code', coalesce((select state_code from public.investment_settings where property_id = p_property),
                           (select nullif(bill_state, '') from public.properties where id = p_property)),
    'kind', (select checklist_kind from public.investment_settings where property_id = p_property),
    'marks', (select coalesce(jsonb_object_agg(item_key, status), '{}'::jsonb) from public.legal_checklist where property_id = p_property),
    'doc_types', (select coalesce(jsonb_agg(distinct doc_type), '[]'::jsonb) from public.legal_documents where property_id = p_property));
end $$;

create or replace function public.legal_checklist_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

-- Optional daily job (pg_cron): reminders even when nobody opens the app. See README.
create or replace function public.legal_docs_remind_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  for r in select distinct property_id from public.legal_documents where expires_on is not null loop
    n := n + public._legal_docs_notify(r.property_id);
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- grants
do $$
declare f text;
begin
  foreach f in array array['invest_summary(uuid)','invest_settings_save(uuid,date)','investment_save(uuid,jsonb)','investment_delete(uuid)',
    'legal_docs_list(uuid)','legal_doc_save(uuid,jsonb)','legal_doc_delete(uuid)','legal_docs_alerts(uuid)',
    'legal_checklist_get(uuid)','legal_checklist_save(uuid,jsonb)'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
  foreach f in array array['_inv_owner(uuid)','_inv_today(uuid)','_inv_opened_on(uuid)','_inv_months(uuid,date)','_legal_docs_notify(uuid)',
    'legal_docs_remind_all()'] loop
    execute 'revoke execute on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

-- Check: should say true
select to_regclass('public.investments') is not null and to_regclass('public.legal_documents') is not null
   and exists (select 1 from storage.buckets where id = 'owner-docs' and not public) as investment_installed;
