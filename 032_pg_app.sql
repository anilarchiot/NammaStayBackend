-- =====================================================================
-- NammaStay · 032_pg_app.sql — the whole app adapted for PG / co-living accounts
--
-- For properties marked PG / co-living (031 pg_properties):
--   • pg_dashboard   PG dashboard (tenants, occupancy, vacant beds, rent due,
--                    rent days this week, leaving soon, recent payments)
--   • pg_payments    all rent receipts in a date range (Rent payments page)
--   • pg_report      month-by-month: billed, collected, deposits, occupancy,
--                    move-ins / move-outs (Rent reports page)
--   • pg_income      rent & charges received, for Expenses & profit
--   • Type locked    a PG account can't change its type (Settings) and can't
--                    turn PG off — only a NammaStay platform admin can.
--
-- ADD-ON ONLY: new functions + one trigger on properties that acts only when
-- the property is PG and its kind is being changed. pg_set_mode (from 031)
-- is re-created: turning PG ON is unchanged, turning it OFF is admin-only.
-- Needs 031. Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------- type lock
create or replace function public._pg_lock_kind() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind is distinct from old.kind
     and exists (select 1 from public.pg_properties where property_id = old.id)
     and not public.is_platform_admin() then
    raise exception 'This is a PG / co-living account — the property type can''t be changed. Contact NammaStay support if you need to.'
      using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists pg_lock_kind on public.properties;
create trigger pg_lock_kind before update of kind on public.properties
  for each row execute function public._pg_lock_kind();

create or replace function public.pg_set_mode(p_property uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_on then
    perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
    if (select kind from public.properties where id = p_property) <> 'hostel' then
      raise exception 'PG / co-living works with beds — set the type to PG / Co-living (not hotel or homestay).';
    end if;
    insert into public.pg_properties (property_id) values (p_property) on conflict do nothing;
  else
    if exists (select 1 from public.pg_properties where property_id = p_property) and not public.is_platform_admin() then
      raise exception 'This is a PG / co-living account — it can''t be switched to another type. Contact NammaStay support if you need to.'
        using errcode = '42501';
    end if;
    delete from public.pg_properties where property_id = p_property;
  end if;
  return p_on;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function public._pg_assert(p_property uuid, p_roles public.member_role[]) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, p_roles);
  if not exists (select 1 from public.pg_properties where property_id = p_property) then
    raise exception 'This is only for PG / co-living properties.';
  end if;
end $$;

-- Money that counts as income: payments for rent / food / charges + dues taken from the deposit.
-- Deposits received are NOT income (they're held); deposit refunds are not expenses.
create or replace function public._pg_income_rows(p_property uuid)
returns table (received_on date, amount_paise int)
language sql stable security definer set search_path = public, pg_temp as $$
  select (p.received_at at time zone public._tz(p_property))::date, p.amount_paise
    from public.rent_payments p left join public.rent_dues d on d.id = p.due_id
   where p.property_id = p_property and p.kind in ('payment','deposit_adjust') and coalesce(d.kind, '') <> 'deposit'
$$;

-- ---------------------------------------------------------------- dashboard
create or replace function public.pg_dashboard(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date; v_month date; v_beds int; v_occ int;
begin
  perform public._pg_assert(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._pg_sync(p_property);
  v_today := public._pg_today(p_property);
  v_month := date_trunc('month', v_today)::date;
  select count(*) into v_beds from public.beds b where b.property_id = p_property and b.is_active;
  select count(distinct t.bed_id) into v_occ from public.tenancies t
   where t.property_id = p_property and t.status <> 'moved_out' and t.start_date <= v_today;
  return jsonb_build_object(
    'today', v_today,
    'property', (select jsonb_build_object('name', name, 'upi_id', upi_id) from public.properties where id = p_property),
    'beds_total', v_beds, 'beds_occupied', v_occ,
    'tenants', (select count(*) from public.tenancies where property_id = p_property and status <> 'moved_out'),
    'on_notice', (select count(*) from public.tenancies where property_id = p_property and status = 'notice'),
    'rent_roll_paise', coalesce((select sum(rent_paise + food_paise) from public.tenancies where property_id = p_property and status <> 'moved_out'), 0),
    'collected_month_paise', coalesce((select sum(amount_paise) from public._pg_income_rows(p_property) where received_on >= v_month), 0),
    'due_now_paise', coalesce((select sum(d.amount_paise - d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                where d.property_id = p_property and d.due_on <= v_today and t.status <> 'moved_out'), 0),
    'overdue_paise', coalesce((select sum(d.amount_paise - d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                where d.property_id = p_property and d.due_on < v_today - 5 and t.status <> 'moved_out'), 0),
    'deposits_held_paise', coalesce((select sum(d.paid_paise) from public.rent_dues d join public.tenancies t on t.id = d.tenancy_id
                                      where d.property_id = p_property and d.kind = 'deposit' and t.status <> 'moved_out'), 0),
    -- who owes money now (largest first)
    'dues', coalesce((select jsonb_agg(x order by (x->>'due_paise')::int desc) from (
        select jsonb_build_object('id', t.id, 'name', g.full_name, 'phone', g.phone, 'bed', r.name || ' · ' || bd.label,
                 'due_paise', sum(d.amount_paise - d.paid_paise), 'oldest', min(d.due_on), 'late', min(d.due_on) < v_today - 5) as x
          from public.tenancies t join public.rent_dues d on d.tenancy_id = t.id
          join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
         where t.property_id = p_property and t.status <> 'moved_out' and d.due_on <= v_today and d.amount_paise > d.paid_paise
         group by t.id, g.full_name, g.phone, r.name, bd.label
         order by sum(d.amount_paise - d.paid_paise) desc limit 8) s), '[]'::jsonb),
    -- rent day in the next 7 days
    'rent_days', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', g.full_name, 'bed', r.name || ' · ' || bd.label,
                 'day', nd.d, 'amount_paise', t.rent_paise + t.food_paise) order by nd.d)
        from public.tenancies t join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
        cross join lateral (
          select min(dd)::date as d from generate_series(v_today + 1, v_today + 7, interval '1 day') dd
           where (t.cycle = 'calendar' and extract(day from dd) = 1)
              or (t.cycle = 'movein' and (extract(day from dd) = extract(day from t.start_date)
                   or (extract(day from t.start_date) > extract(day from (date_trunc('month', dd) + interval '1 month - 1 day'))
                       and dd::date = (date_trunc('month', dd) + interval '1 month - 1 day')::date)))) nd
       where t.property_id = p_property and t.status <> 'moved_out' and nd.d is not null and t.start_date < nd.d
         and coalesce(t.move_out_on, 'infinity'::date) > nd.d), '[]'::jsonb),
    -- leaving soon
    'leaving', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', g.full_name, 'bed', r.name || ' · ' || bd.label, 'day', t.move_out_on) order by t.move_out_on)
        from public.tenancies t join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
       where t.property_id = p_property and t.status = 'notice'), '[]'::jsonb),
    -- moving in soon (future move-in date)
    'arriving', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', g.full_name, 'bed', r.name || ' · ' || bd.label, 'day', t.start_date) order by t.start_date)
        from public.tenancies t join public.guests g on g.id = t.guest_id join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
       where t.property_id = p_property and t.status <> 'moved_out' and t.start_date > v_today), '[]'::jsonb),
    -- vacant beds (no tenant now)
    'vacant', coalesce((select jsonb_agg(jsonb_build_object('id', bd.id, 'bed', r.name || ' · ' || bd.label, 'rent_paise', bd.rate_paise) order by r.sort, bd.sort)
        from public.beds bd join public.rooms r on r.id = bd.room_id
       where bd.property_id = p_property and bd.is_active
         and not exists (select 1 from public.tenancies t where t.bed_id = bd.id and t.status <> 'moved_out' and t.start_date <= v_today)), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('code', p.code, 'name', g.full_name, 'amount_paise', p.amount_paise, 'method', p.method, 'kind', p.kind,
                 'for', d.label, 'at', p.received_at) as x
          from public.rent_payments p join public.tenancies t on t.id = p.tenancy_id join public.guests g on g.id = t.guest_id
          left join public.rent_dues d on d.id = p.due_id
         where p.property_id = p_property and p.kind in ('payment','refund')
         order by p.received_at desc limit 8) s), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- all receipts in a period
create or replace function public.pg_payments(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tz text;
begin
  perform public._pg_assert(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if not public._allowed(p_property, 'view_payments') then
    raise exception 'Your role can’t see payments. Ask the owner.';
  end if;
  v_tz := public._tz(p_property);
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'kind', p.kind, 'amount_paise', p.amount_paise,
               'method', p.method, 'reference', p.reference, 'note', p.note, 'received_at', p.received_at,
               'for', d.label, 'due_kind', d.kind, 'tenancy_id', t.id, 'name', g.full_name, 'phone', g.phone,
               'bed', r.name || ' · ' || bd.label) order by p.received_at desc, p.code desc)
        from public.rent_payments p join public.tenancies t on t.id = p.tenancy_id join public.guests g on g.id = t.guest_id
        join public.beds bd on bd.id = t.bed_id join public.rooms r on r.id = bd.room_id
        left join public.rent_dues d on d.id = p.due_id
       where p.property_id = p_property and (p.received_at at time zone v_tz)::date between p_from and p_to), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'rent_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit'), 0),
        'deposits_in_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and d.kind = 'deposit'), 0),
        'from_deposit_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'deposit_adjust'), 0),
        'refunds_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'refund'), 0),
        'upi_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit' and p.method = 'upi'), 0),
        'cash_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit' and p.method = 'cash'), 0),
        'other_paise', coalesce(sum(p.amount_paise) filter (where p.kind = 'payment' and coalesce(d.kind, '') <> 'deposit' and p.method not in ('upi','cash')), 0))
        from public.rent_payments p left join public.rent_dues d on d.id = p.due_id
       where p.property_id = p_property and (p.received_at at time zone v_tz)::date between p_from and p_to));
end $$;

-- ---------------------------------------------------------------- month by month
create or replace function public.pg_report(p_property uuid, p_months int default 12) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_today date; v_beds int;
begin
  perform public._pg_assert(p_property, array['owner','manager','accountant']::public.member_role[]);
  if not public._allowed(p_property, 'view_reports') then
    raise exception 'Your role can’t see reports. Ask the owner.';
  end if;
  perform public._pg_sync(p_property);
  v_today := public._pg_today(p_property);
  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  return jsonb_build_object('beds_total', v_beds, 'months', (select jsonb_agg(m order by m->>'month') from (
    select jsonb_build_object(
      'month', to_char(ms, 'YYYY-MM'),
      'billed_paise', coalesce((select sum(d.amount_paise - d.credit_paise) from public.rent_dues d
                                 where d.property_id = p_property and d.kind <> 'deposit' and date_trunc('month', d.due_on) = ms), 0),
      'collected_paise', coalesce((select sum(amount_paise) from public._pg_income_rows(p_property) where date_trunc('month', received_on) = ms), 0),
      'deposits_in_paise', coalesce((select sum(p.amount_paise) from public.rent_payments p join public.rent_dues d on d.id = p.due_id
                                      where p.property_id = p_property and p.kind = 'payment' and d.kind = 'deposit'
                                        and date_trunc('month', (p.received_at at time zone public._tz(p_property))) = ms), 0),
      'refunds_paise', coalesce((select sum(p.amount_paise) from public.rent_payments p
                                  where p.property_id = p_property and p.kind = 'refund'
                                    and date_trunc('month', (p.received_at at time zone public._tz(p_property))) = ms), 0),
      'move_ins', (select count(*) from public.tenancies where property_id = p_property and date_trunc('month', start_date) = ms),
      'move_outs', (select count(*) from public.tenancies where property_id = p_property and status = 'moved_out' and date_trunc('month', move_out_on) = ms),
      -- occupancy on the 15th (or today for the current month)
      'occupied', (select count(distinct t.bed_id) from public.tenancies t where t.property_id = p_property
                     and t.start_date <= least((ms + interval '14 days')::date, v_today)
                     and coalesce(t.move_out_on, 'infinity'::date) > least((ms + interval '14 days')::date, v_today))) as m
    from generate_series(date_trunc('month', v_today) - make_interval(months => greatest(1, least(p_months, 36)) - 1),
                         date_trunc('month', v_today), interval '1 month') ms) s));
end $$;

-- ---------------------------------------------------------------- income for Expenses & profit
create or replace function public.pg_income(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  if not exists (select 1 from public.pg_properties where property_id = p_property) then
    return jsonb_build_object('total_paise', 0, 'months', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'total_paise', coalesce((select sum(amount_paise) from public._pg_income_rows(p_property) where received_on between p_from and p_to), 0),
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', mo, 'income_paise', amt) order by mo) from (
        select to_char(received_on, 'YYYY-MM') mo, sum(amount_paise) amt from public._pg_income_rows(p_property)
         where received_on >= (date_trunc('month', public._pg_today(p_property)) - interval '11 months')::date group by 1) s), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- tenant registration link
-- The online check-in page (opened by the tenant with their link token) asks whether this is a PG tenant,
-- so it can say "Tenant registration" instead of showing nights. Returns nothing else.
create or replace function public.pg_selfcheckin_info(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select jsonb_build_object('tenant', true, 'start_date', t.start_date, 'moved_in', t.start_date <= public._pg_today(t.property_id))
      from public.bookings b join public.tenancies t on t.booking_ids @> array[b.id]
     where b.self_checkin_token = p_token limit 1), jsonb_build_object('tenant', false))
$$;
revoke execute on function public.pg_selfcheckin_info(uuid) from public;
grant execute on function public.pg_selfcheckin_info(uuid) to anon, authenticated;

revoke execute on function public._pg_lock_kind(), public._pg_assert(uuid, public.member_role[]), public._pg_income_rows(uuid) from public, anon, authenticated;
revoke execute on function public.pg_dashboard(uuid), public.pg_payments(uuid, date, date), public.pg_report(uuid, int), public.pg_income(uuid, date, date),
  public.pg_set_mode(uuid, boolean) from public, anon;
grant execute on function public.pg_dashboard(uuid), public.pg_payments(uuid, date, date), public.pg_report(uuid, int), public.pg_income(uuid, date, date),
  public.pg_set_mode(uuid, boolean) to authenticated;
