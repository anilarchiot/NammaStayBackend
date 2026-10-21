-- =====================================================================
-- NammaStay · 043_branches.sql — owners with more than one property (branches)
--   • branch_create        the owner adds a branch themselves (same login). Each branch is its own property with
--                          its own free trial and its own subscription, exactly like a property made at sign-up.
--                          Optionally copies from an existing branch: rooms, beds & prices · times, GST, UPI &
--                          billing details · house rules & guest guide · staff shifts · team access.
--   • branches_overview    one screen for the owner: today and this month for every branch, the next 14 nights,
--                          alerts, plan status.
--   • branch_team / branch_access_set   who works at which branch; give or remove access in one tap.
-- Adds NO tables and changes NO existing function. Safe to run again.
-- Run AFTER the main setup (works with or without 031 PG, 034 resort, 040–042).
-- =====================================================================

-- ---------------------------------------------------------------- helpers
-- Hostel / hotel / homestay, or 'pg' / 'resort' when that switch is on (the tables may not exist yet).
create or replace function public._br_mode(p_property uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_kind text; v_on boolean;
begin
  select kind into v_kind from public.properties where id = p_property;
  if to_regclass('public.pg_properties') is not null then
    execute 'select exists (select 1 from public.pg_properties where property_id = $1)' into v_on using p_property;
    if v_on then return 'pg'; end if;
  end if;
  if to_regclass('public.resort_properties') is not null then
    execute 'select exists (select 1 from public.resort_properties where property_id = $1)' into v_on using p_property;
    if v_on then return 'resort'; end if;
  end if;
  return v_kind;
end $$;

create or replace function public._br_assert_owner() returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  if not exists (select 1 from public.property_members where user_id = auth.uid() and role = 'owner') then
    raise exception 'Only the owner can manage branches.' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

-- A free invoice prefix for a new branch: initials of the name, never the same as another branch of this owner
-- (two branches under one GSTIN must not both print INV-0001).
create or replace function public._br_prefix(p_name text, p_owner uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_base text; v_try text; i int := 1;
begin
  select string_agg(left(w, 1), '') into v_base
    from regexp_split_to_table(upper(regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9 ]', ' ', 'g')), '\s+') w where w <> '';
  v_base := left(coalesce(nullif(v_base, ''), 'BR'), 6);
  if char_length(v_base) < 2 then v_base := left(upper(regexp_replace(p_name, '[^A-Za-z0-9]', '', 'g')) || 'BR', 3); end if;
  v_try := v_base;
  while exists (select 1 from public.properties p join public.property_members m on m.property_id = p.id
                 where m.user_id = p_owner and m.role = 'owner' and p.invoice_prefix = v_try) loop
    i := i + 1; v_try := left(v_base, 8) || i;
  end loop;
  return v_try;
end $$;

-- ---------------------------------------------------------------- overview
create or replace function public.branches_overview() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := public._br_assert_owner();
  r record; s public.subscriptions%rowtype;
  v_tz text; v_today date; v_m0 date; t0 timestamptz; t1 timestamptz; tm0 timestamptz;
  v_mode text; v_units int; v_state text; v_end timestamptz;
  v_rev bigint; v_exp bigint; v_sold bigint; v_dues bigint; v_n int; v_j jsonb; v_alerts jsonb; v_url text;
  v_out jsonb := '[]'::jsonb;
begin
  for r in select p.* from public.properties p
             join public.property_members m on m.property_id = p.id and m.user_id = v_uid and m.role = 'owner'
            order by p.created_at, p.name loop
    v_tz := r.timezone; v_today := (now() at time zone v_tz)::date; v_m0 := date_trunc('month', v_today)::date;
    t0 := public._day_start(v_tz, v_today); t1 := t0 + interval '1 day'; tm0 := public._day_start(v_tz, v_m0);
    v_mode := public._br_mode(r.id);
    select count(*) into v_units from public.beds where property_id = r.id and is_active;

    -- plan
    select * into s from public.subscriptions where property_id = r.id;
    v_state := public._access_state(r.id);
    v_end := case v_state when 'trial' then s.trial_ends_at when 'active' then s.paid_until
                          else greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at)) end;

    -- money this month (room payments + PG rent receipts) and expenses
    select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0) into v_rev
      from public.payments where property_id = r.id and received_at >= tm0 and received_at < t1;
    v_dues := 0;
    if v_mode = 'pg' and to_regclass('public.rent_payments') is not null then
      execute $q$select coalesce(sum(case kind when 'refund' then -amount_paise when 'payment' then amount_paise else 0 end), 0)
                   from public.rent_payments where property_id = $1 and received_at >= $2 and received_at < $3$q$
        into v_n using r.id, tm0, t1;
      v_rev := v_rev + v_n;
      execute $q$select coalesce(sum(amount_paise - paid_paise), 0) from public.rent_dues
                  where property_id = $1 and due_on <= $2 and amount_paise > paid_paise$q$ into v_n using r.id, v_today;
      v_dues := v_n;
    end if;
    select coalesce(sum(amount_paise), 0) into v_exp from public.expenses where property_id = r.id and spent_on between v_m0 and v_today;
    select coalesce(sum(occupied), 0) into v_sold from public.occupancy_series(r.id, v_m0, v_today);

    -- alerts from the pages the owner already has (each one only if installed)
    v_alerts := '{}'::jsonb;
    begin
      if to_regprocedure('public.hk_counts(uuid)') is not null then
        execute 'select public.hk_counts($1)' into v_j using r.id;
        v_alerts := v_alerts || jsonb_build_object('to_clean', coalesce((v_j->>'dirty')::int, 0) + coalesce((v_j->>'cleaning')::int, 0));
      end if;
    exception when others then null; end;
    begin
      if to_regprocedure('public.formc_due_count(uuid)') is not null then
        execute 'select public.formc_due_count($1)' into v_n using r.id;
        v_alerts := v_alerts || jsonb_build_object('formc_due', coalesce(v_n, 0));
      end if;
    exception when others then null; end;
    begin
      if to_regprocedure('public.staff_counts(uuid)') is not null then
        execute 'select public.staff_counts($1)' into v_n using r.id;
        v_alerts := v_alerts || jsonb_build_object('staff_todo', coalesce(v_n, 0));
      end if;
    exception when others then null; end;
    v_url := null;
    begin
      if to_regclass('public.booking_pages') is not null then
        execute 'select slug from public.booking_pages where property_id = $1 and enabled' into v_url using r.id;
      end if;
    exception when others then v_url := null; end;

    v_out := v_out || jsonb_build_object(
      'id', r.id, 'name', r.name, 'kind', r.kind, 'mode', v_mode, 'city', r.city, 'phone', r.phone,
      'created_at', r.created_at, 'today', v_today, 'setup_done', r.setup_done_at is not null or v_units > 0,
      'plan', jsonb_build_object('state', v_state, 'ends_at', v_end,
        'days_left', case when v_state in ('trial','active') then greatest(0, ceil(extract(epoch from (v_end - now())) / 86400))::int end),
      'units', v_units,
      'tonight', (select count(*) from public.bookings where property_id = r.id and status in ('pending','confirmed','checked_in')
                   and stay @> public._night(v_tz, v_today)),
      'arriving', (select count(*) from public.bookings where property_id = r.id and check_in_at >= t0 and check_in_at < t1
                    and status in ('pending','confirmed','checked_in')),
      'arriving_unpaid', (select count(*) from public.bookings where property_id = r.id and check_in_at >= t0 and check_in_at < t1
                    and status in ('pending','confirmed') and paid_paise < total_paise),
      'leaving', (select count(*) from public.bookings where property_id = r.id and check_out_at >= t0 and check_out_at < t1
                   and status in ('checked_in','checked_out')),
      'collected_today', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                           from public.payments where property_id = r.id and received_at >= t0 and received_at < t1),
      'cash_today', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                      from public.payments where property_id = r.id and received_at >= t0 and received_at < t1 and method = 'cash'),
      'dues', v_dues + (select coalesce(sum(balance_paise), 0) from public.bookings where property_id = r.id
                         and balance_paise > 0 and status in ('checked_in','checked_out')),
      'month', jsonb_build_object('from', v_m0, 'days', v_today - v_m0 + 1, 'revenue', v_rev, 'expenses', v_exp, 'profit', v_rev - v_exp,
        'nights_sold', v_sold,
        'occupancy', case when v_units = 0 then 0 else round(v_sold::numeric / (v_units * (v_today - v_m0 + 1)), 4) end,
        'bookings', (select count(*) from public.bookings where property_id = r.id and check_in_at >= tm0 and check_in_at < t1
                      and status not in ('cancelled','no_show')),
        'direct', (select count(*) from public.bookings where property_id = r.id and check_in_at >= tm0 and check_in_at < t1
                    and status not in ('cancelled','no_show') and source <> 'ota')),
      'nights', (select coalesce(jsonb_agg(jsonb_build_object('day', x.day, 'occupied', x.occupied) order by x.day), '[]'::jsonb)
                   from public.occupancy_series(r.id, v_today, v_today + 13) x),
      'alerts', v_alerts,
      'booking_slug', v_url);
  end loop;
  return jsonb_build_object('branches', v_out, 'team', public.branch_team(),
    'features', jsonb_build_object('pg', to_regclass('public.pg_properties') is not null, 'resort', to_regclass('public.resort_properties') is not null,
      'staff', to_regclass('public.staff_shifts') is not null, 'guide', to_regclass('public.property_guide') is not null));
end $$;

-- ---------------------------------------------------------------- team across branches
create or replace function public.branch_team() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_uid uuid := public._br_assert_owner();
begin
  return (select coalesce(jsonb_agg(t order by t->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('user_id', m.user_id,
             'name', coalesce(max(m.display_name), max(m.email), 'Team member'), 'email', max(m.email),
             'access', jsonb_agg(jsonb_build_object('property_id', m.property_id, 'role', m.role) order by p.created_at)) t
      from public.property_members m join public.properties p on p.id = m.property_id
     where m.property_id in (select public.my_property_ids(array['owner']::public.member_role[]))
       and m.user_id <> v_uid and m.role <> 'owner'
     group by m.user_id) q);
end $$;

-- Give someone who already works at one of your branches access to another one (or take it away).
create or replace function public.branch_access_set(p_user uuid, p_property uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_cur public.member_role; v_name text; v_email text; v_n int;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if p_user is null or p_user = v_uid then raise exception 'Choose a team member.'; end if;
  select count(*), max(display_name), max(email) into v_n, v_name, v_email from public.property_members
   where user_id = p_user and role <> 'owner'
     and property_id in (select public.my_property_ids(array['owner']::public.member_role[]));
  if v_n = 0 then
    raise exception 'This person doesn''t work at any of your branches. Add them first in Settings → Users & roles.';
  end if;
  select role into v_cur from public.property_members where property_id = p_property and user_id = p_user;
  if v_cur = 'owner' then raise exception 'An owner''s access can''t be changed here.'; end if;
  if coalesce(p_role, '') = '' then
    delete from public.property_members where property_id = p_property and user_id = p_user;
    return jsonb_build_object('removed', true);
  end if;
  if p_role not in ('manager','front_desk','accountant') then raise exception 'Choose manager, front desk or accountant.'; end if;
  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (p_property, p_user, p_role::public.member_role, v_name, v_email)
  on conflict (property_id, user_id) do update set role = excluded.role;
  return jsonb_build_object('role', p_role);
end $$;

-- ---------------------------------------------------------------- add a branch
create or replace function public.branch_create(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid   uuid := public._br_assert_owner();
  v_src   uuid := nullif(p->>'copy_from', '')::uuid;
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_type  text := coalesce(nullif(p->>'kind', ''), 'hostel');
  v_kind  text;
  v_copy  jsonb := coalesce(p->'copy', '[]'::jsonb);
  v_email text; v_owner_name text; v_prefix text; v_prop uuid; v_room uuid; v_n int := 0; v_team int := 0;
  sp public.properties%rowtype; rm record; u record; v_map jsonb := '{}'::jsonb;
begin
  if char_length(v_name) < 2 then raise exception 'Enter the branch name.'; end if;
  if v_type not in ('hostel','hotel','homestay','pg','resort') then raise exception 'Choose the type of property.'; end if;
  if v_type = 'pg' and to_regclass('public.pg_properties') is null then raise exception 'PG / co-living isn''t switched on for your account yet.'; end if;
  if v_type = 'resort' and to_regclass('public.resort_properties') is null then raise exception 'Resorts aren''t switched on for your account yet.'; end if;
  v_kind := case v_type when 'pg' then 'hostel' when 'resort' then 'hotel' else v_type end;
  if jsonb_typeof(v_copy) <> 'array' then raise exception 'Bad copy list.'; end if;

  if (select count(*) from public.property_members where user_id = v_uid and role = 'owner') >= 25 then
    raise exception 'You already have 25 properties. Contact NammaStay support to add more.';
  end if;
  -- each branch gets a free trial, but only two branches can be on an unpaid trial at the same time
  if (select count(*) from public.property_members m join public.subscriptions s on s.property_id = m.property_id
       where m.user_id = v_uid and m.role = 'owner' and s.paid_until is null and not s.is_complimentary
         and public._access_state(m.property_id) = 'trial') >= 2 then
    raise exception 'Two of your branches are still on the free trial. Choose a plan for one of them in Settings → Billing, then add the next branch.';
  end if;
  if exists (select 1 from public.properties x join public.property_members m on m.property_id = x.id
              where m.user_id = v_uid and m.role = 'owner' and lower(x.name) = lower(v_name)) then
    raise exception 'You already have a branch called "%". Use a different name, e.g. add the area.', v_name;
  end if;
  if v_src is not null then
    perform public._assert_role(v_src, array['owner']::public.member_role[]);
    select * into sp from public.properties where id = v_src;
    if v_copy ? 'rooms' and public._br_mode(v_src) <> v_type then
      raise exception 'Rooms and prices can only be copied from a branch of the same type.';
    end if;
  elsif jsonb_array_length(v_copy) > 0 then
    raise exception 'Choose the branch to copy from.';
  end if;

  select email into v_email from auth.users where id = v_uid;
  select display_name into v_owner_name from public.property_members
   where user_id = v_uid and role = 'owner' and display_name is not null order by created_at limit 1;
  v_prefix := upper(btrim(coalesce(p->>'invoice_prefix', '')));
  if v_prefix = '' then v_prefix := public._br_prefix(v_name, v_uid); end if;
  if v_prefix !~ '^[A-Z0-9-]{1,10}$' then raise exception 'Invoice prefix: up to 10 capital letters, numbers or -.'; end if;
  if exists (select 1 from public.properties x join public.property_members m on m.property_id = x.id
              where m.user_id = v_uid and m.role = 'owner' and x.invoice_prefix = v_prefix) then
    raise exception 'Another branch already uses the invoice prefix %. Pick a different one so invoice numbers don''t repeat.', v_prefix;
  end if;

  insert into public.properties (name, kind, city, address, phone, email, invoice_prefix)
  values (left(v_name, 120), v_kind,
          left(nullif(btrim(p->>'city'), ''), 80), left(nullif(btrim(p->>'address'), ''), 300),
          left(coalesce(nullif(btrim(p->>'phone'), ''), sp.phone), 20), v_email, v_prefix)
  returning id into v_prop;                                       -- the existing trigger starts this branch's free trial
  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (v_prop, v_uid, 'owner', v_owner_name, v_email);
  if v_type = 'pg' then execute 'insert into public.pg_properties (property_id) values ($1) on conflict do nothing' using v_prop; end if;
  if v_type = 'resort' then execute 'insert into public.resort_properties (property_id) values ($1) on conflict do nothing' using v_prop; end if;

  if v_src is not null and v_copy ? 'details' then                 -- times, GST, UPI, billing, offers, role permissions
    update public.properties set checkin_time = sp.checkin_time, checkout_time = sp.checkout_time,
      id_doc_retention_days = sp.id_doc_retention_days, upi_id = sp.upi_id, legal_name = sp.legal_name, gstin = sp.gstin,
      gst_mode = sp.gst_mode, gst_rate = sp.gst_rate, extras_gst_rate = sp.extras_gst_rate, offers = sp.offers,
      role_permissions = sp.role_permissions, bill_name = sp.bill_name, bill_gstin = sp.bill_gstin,
      bill_address = sp.bill_address, bill_state = sp.bill_state, timezone = sp.timezone
     where id = v_prop;
  end if;

  if v_src is not null and v_copy ? 'rooms' then                   -- rooms, beds, prices, weekend/season prices, extras
    for rm in select * from public.rooms where property_id = v_src order by sort, name loop
      insert into public.rooms (property_id, name, description, sort) values (v_prop, rm.name, rm.description, rm.sort)
      returning id into v_room;
      v_map := v_map || jsonb_build_object(rm.id::text, v_room);
      insert into public.beds (property_id, room_id, label, position, rate_paise, is_active, sort, max_guests, base_guests, extra_guest_paise)
      select v_prop, v_room, b.label, b.position, b.rate_paise, b.is_active, b.sort, b.max_guests, b.base_guests, b.extra_guest_paise
        from public.beds b where b.room_id = rm.id;
      v_n := v_n + 1;
    end loop;
    insert into public.rate_rules (property_id, name, kind, weekdays, date_from, date_to, adjust, value, room_ids, min_nights, priority, is_active)
    select v_prop, rr.name, rr.kind, rr.weekdays, rr.date_from, rr.date_to, rr.adjust, rr.value,
           case when rr.room_ids is null then null
                else (select array_agg((v_map->>x::text)::uuid) from unnest(rr.room_ids) x where v_map ? x::text) end,
           rr.min_nights, rr.priority, rr.is_active
      from public.rate_rules rr
     where rr.property_id = v_src and rr.name <> 'Smart pricing'                     -- Smart pricing (041) makes its own
       and (rr.room_ids is null or exists (select 1 from unnest(rr.room_ids) x where v_map ? x::text));
    insert into public.extra_items (property_id, name, category, price_paise, unit, is_active, sort)
    select v_prop, name, category, price_paise, unit, is_active, sort from public.extra_items where property_id = v_src;
  end if;

  if v_src is not null and v_copy ? 'guide' and to_regclass('public.property_guide') is not null then   -- not Wi-Fi or directions
    execute $q$insert into public.property_guide (property_id, welcome, house_rules, host_name, host_phone, checkin_info, checkout_info, food_info)
               select $1, welcome, house_rules, host_name, host_phone, checkin_info, checkout_info, food_info
                 from public.property_guide where property_id = $2 on conflict (property_id) do nothing$q$ using v_prop, v_src;
  end if;

  if v_src is not null and v_copy ? 'shifts' and to_regclass('public.staff_shifts') is not null then     -- Staff (042)
    execute $q$insert into public.staff_shifts (property_id, name, starts, ends, sort)
               select $1, name, starts, ends, sort from public.staff_shifts where property_id = $2$q$ using v_prop, v_src;
    execute $q$insert into public.staff_settings (property_id, leave_days_year, late_after_min, managers_see_salary)
               select $1, leave_days_year, late_after_min, managers_see_salary from public.staff_settings where property_id = $2
               on conflict (property_id) do nothing$q$ using v_prop, v_src;
  end if;

  -- team: people who already work at one of your branches, with the role they have there
  for u in select distinct on (m.user_id) m.user_id, m.role, m.display_name, m.email
             from public.property_members m
            where jsonb_typeof(p->'team') = 'array' and m.user_id::text in (select jsonb_array_elements_text(p->'team'))
              and m.role <> 'owner' and m.user_id <> v_uid
              and m.property_id in (select public.my_property_ids(array['owner']::public.member_role[]))
            order by m.user_id, (m.property_id = v_src) desc, case m.role when 'manager' then 1 when 'front_desk' then 2 else 3 end loop
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (v_prop, u.user_id, u.role, u.display_name, u.email) on conflict do nothing;
    v_team := v_team + 1;
  end loop;

  return jsonb_build_object('property_id', v_prop, 'name', v_name, 'invoice_prefix', v_prefix, 'rooms_copied', v_n, 'team_added', v_team,
    'trial_ends_at', (select trial_ends_at from public.subscriptions where property_id = v_prop));
end $$;

-- ---------------------------------------------------------------- permissions
do $$ declare f text; begin
  foreach f in array array['branches_overview()', 'branch_team()', 'branch_access_set(uuid, uuid, text)', 'branch_create(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['_br_mode(uuid)', '_br_assert_owner()', '_br_prefix(text, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

select to_regprocedure('public.branch_create(jsonb)') is not null and to_regprocedure('public.branches_overview()') is not null as branches_installed;
