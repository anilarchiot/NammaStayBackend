-- =====================================================================
-- NammaStay · 033_homestay.sql — homestay add-ons: meal plans + house guide
--
-- Meal plans   Breakfast / Breakfast + Dinner / All meals, priced per adult and per
--              child per night. Choosing a plan on a booking adds ONE normal extra
--              ("Meals: …") to the bill through the existing add_charge(), so bills,
--              invoices, payments and reports work exactly as before. A kitchen list
--              counts the breakfasts / lunches / dinners for a day.
-- House guide  Welcome note, house rules, Wi-Fi, how to reach, host phone, check-in /
--              check-out and food notes. Staff send it on WhatsApp; the guest also sees
--              it on their online check-in page (by their booking link only).
--
-- ADD-ON ONLY — nothing existing is changed:
--   • new tables  meal_plans, booking_meals, property_guide
--   • new functions meal_plans_list, meal_plan_save, meal_plan_delete, booking_meal_get,
--     booking_meal_set, kitchen_list, guide_get, guide_save, guide_for_token
--   • no existing table, function, trigger or policy is touched
-- Safe to run more than once. Run after 001–029 (030–032 not needed).
-- =====================================================================

-- ---------------------------------------------------------------- tables
create table if not exists public.meal_plans (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 60),
  breakfast     boolean not null default false,
  lunch         boolean not null default false,
  dinner        boolean not null default false,
  adult_paise   int not null default 0 check (adult_paise between 0 and 10000000),   -- per adult per night
  child_paise   int not null default 0 check (child_paise between 0 and 10000000),   -- per child per night
  is_active     boolean not null default true,
  sort          smallint not null default 0,
  created_at    timestamptz not null default now(),
  check (breakfast or lunch or dinner)
);
create index if not exists meal_plans_property on public.meal_plans (property_id, sort);

create table if not exists public.booking_meals (
  booking_id    uuid primary key,
  property_id   uuid not null,
  plan_id       uuid references public.meal_plans(id) on delete set null,
  plan_name     text not null,
  breakfast     boolean not null default false,
  lunch         boolean not null default false,
  dinner        boolean not null default false,
  adults        smallint not null default 1,
  children      smallint not null default 0,
  nights        smallint not null default 1,
  amount_paise  int not null default 0,
  charge_id     uuid,                                  -- the "Meals: …" line on the bill (booking_charges)
  note          text check (char_length(note) <= 200),
  updated_at    timestamptz not null default now(),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index if not exists booking_meals_property on public.booking_meals (property_id);

create table if not exists public.property_guide (
  property_id   uuid primary key references public.properties(id) on delete cascade,
  welcome       text check (char_length(welcome) <= 1000),
  house_rules   text check (char_length(house_rules) <= 2000),
  wifi_name     text check (char_length(wifi_name) <= 80),
  wifi_password text check (char_length(wifi_password) <= 80),
  directions    text check (char_length(directions) <= 1500),
  maps_url      text check (maps_url is null or (maps_url ~* '^https?://' and char_length(maps_url) <= 500)),
  host_name     text check (char_length(host_name) <= 80),
  host_phone    text check (host_phone is null or host_phone ~ '^\+?[0-9]{8,15}$'),
  checkin_info  text check (char_length(checkin_info) <= 1000),
  checkout_info text check (char_length(checkout_info) <= 1000),
  food_info     text check (char_length(food_info) <= 1000),
  updated_at    timestamptz not null default now()
);

alter table public.meal_plans enable row level security;
alter table public.booking_meals enable row level security;
alter table public.property_guide enable row level security;
drop policy if exists meal_plans_select on public.meal_plans;
create policy meal_plans_select on public.meal_plans for select to authenticated using (property_id in (select public.my_property_ids()));
drop policy if exists booking_meals_select on public.booking_meals;
create policy booking_meals_select on public.booking_meals for select to authenticated using (property_id in (select public.my_property_ids()));
drop policy if exists property_guide_select on public.property_guide;
create policy property_guide_select on public.property_guide for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.meal_plans, public.booking_meals, public.property_guide from anon, authenticated;
grant select on public.meal_plans, public.booking_meals, public.property_guide to authenticated;   -- writes only through the functions below

-- ---------------------------------------------------------------- meal plans (Settings)
create or replace function public.meal_plans_list(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'breakfast', breakfast, 'lunch', lunch, 'dinner', dinner,
      'adult_paise', adult_paise, 'child_paise', child_paise, 'is_active', is_active) order by sort, created_at)
    from public.meal_plans where property_id = p_property), '[]'::jsonb);
end $$;

create or replace function public.meal_plan_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', ''));
  v_b boolean := coalesce((p->>'breakfast')::boolean, false); v_l boolean := coalesce((p->>'lunch')::boolean, false);
  v_d boolean := coalesce((p->>'dinner')::boolean, false);
  v_a int := coalesce(nullif(p->>'adult_paise', '')::int, 0); v_c int := coalesce(nullif(p->>'child_paise', '')::int, 0);
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if char_length(v_name) < 1 then raise exception 'Give the meal plan a name, e.g. “Breakfast included”.'; end if;
  if not (v_b or v_l or v_d) then raise exception 'Tick at least one meal (breakfast, lunch or dinner).'; end if;
  if v_a < 0 or v_c < 0 or v_a > 10000000 or v_c > 10000000 then raise exception 'Enter a price between ₹0 and ₹1,00,000.'; end if;
  if v_id is null then
    if (select count(*) from public.meal_plans where property_id = p_property) >= 12 then raise exception 'Up to 12 meal plans.'; end if;
    insert into public.meal_plans (property_id, name, breakfast, lunch, dinner, adult_paise, child_paise, is_active, sort)
    values (p_property, left(v_name, 60), v_b, v_l, v_d, v_a, v_c, coalesce((p->>'is_active')::boolean, true),
            coalesce((select max(sort) + 1 from public.meal_plans where property_id = p_property), 0))
    returning id into v_id;
  else
    update public.meal_plans set name = left(v_name, 60), breakfast = v_b, lunch = v_l, dinner = v_d, adult_paise = v_a, child_paise = v_c,
           is_active = coalesce((p->>'is_active')::boolean, is_active)
     where id = v_id and property_id = p_property;
    if not found then raise exception 'Meal plan not found.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.meal_plan_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.meal_plans where id = p_id;
  if v_prop is null then raise exception 'Meal plan not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager']::public.member_role[]);
  delete from public.meal_plans where id = p_id;          -- bookings keep their plan name and bill line
end $$;

-- ---------------------------------------------------------------- a booking's meal plan
create or replace function public.booking_meal_get(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_prop uuid; m public.booking_meals%rowtype; b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.' using errcode = 'P0404'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select * into m from public.booking_meals where booking_id = p_booking;
  if not found then return jsonb_build_object('plan', null); end if;
  return jsonb_build_object('plan', jsonb_build_object('plan_id', m.plan_id, 'name', m.plan_name, 'breakfast', m.breakfast, 'lunch', m.lunch,
    'dinner', m.dinner, 'adults', m.adults, 'children', m.children, 'nights', m.nights, 'amount_paise', m.amount_paise,
    'charged', exists (select 1 from public.booking_charges c where c.id = m.charge_id),
    'stale', (m.nights <> b.nights or m.adults <> b.visitors or m.children <> coalesce(b.children, 0))));
end $$;

-- p_plan null = room only (removes the plan and its bill line)
create or replace function public.booking_meal_set(p_booking uuid, p_plan uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings%rowtype; mp public.meal_plans%rowtype; old public.booking_meals%rowtype;
  v_night int; v_amt int; v_charge jsonb; v_meals text;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  select * into old from public.booking_meals where booking_id = p_booking for update;
  if found and old.charge_id is not null and exists (select 1 from public.booking_charges where id = old.charge_id) then
    perform public.remove_charge(old.charge_id);                       -- the old "Meals: …" line comes off the bill
  end if;
  delete from public.booking_meals where booking_id = p_booking;
  if p_plan is null then return jsonb_build_object('plan', null); end if;

  select * into mp from public.meal_plans where id = p_plan and property_id = b.property_id;
  if not found then raise exception 'That meal plan isn’t in your list any more.'; end if;
  v_night := mp.adult_paise * greatest(b.visitors, 1) + mp.child_paise * coalesce(b.children, 0);
  v_amt := v_night * b.nights;
  v_meals := array_to_string(array_remove(array[case when mp.breakfast then 'breakfast' end, case when mp.lunch then 'lunch' end,
                                                case when mp.dinner then 'dinner' end], null), ' + ');
  if v_night > 0 then
    v_charge := public.add_charge(p_booking, jsonb_build_object('name', left('Meals: ' || mp.name, 80), 'category', 'food',
      'qty', b.nights, 'unit_price_paise', v_night,
      'note', left(greatest(b.visitors, 1) || ' adult' || case when b.visitors > 1 then 's' else '' end
              || case when coalesce(b.children, 0) > 0 then ' + ' || b.children || ' child' || case when b.children > 1 then 'ren' else '' end else '' end
              || ', every night (' || v_meals || ')', 200),
      'charged_on', public._local_date(b.property_id, b.check_in_at)));
  end if;
  insert into public.booking_meals (booking_id, property_id, plan_id, plan_name, breakfast, lunch, dinner, adults, children, nights, amount_paise, charge_id)
  values (b.id, b.property_id, mp.id, mp.name, mp.breakfast, mp.lunch, mp.dinner, greatest(b.visitors, 1), coalesce(b.children, 0), b.nights,
          coalesce(v_amt, 0), nullif(v_charge->>'id', '')::uuid);
  return jsonb_build_object('plan', mp.name, 'amount_paise', coalesce(v_amt, 0));
end $$;

-- ---------------------------------------------------------------- kitchen list for a day
-- Breakfast on day D = guests who slept the night before (check-in < D ≤ check-out day).
-- Lunch and dinner on day D = guests sleeping the night of D (check-in ≤ D < check-out day).
create or replace function public.kitchen_list(p_property uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  return (with x as (
      select b.id, b.code, g.full_name, r.name as room, bd.label as unit, m.plan_name, m.breakfast, m.lunch, m.dinner,
             greatest(b.visitors, 1) as adults, coalesce(b.children, 0) as children,
             (b.check_in_at at time zone v_tz)::date as d_in, (b.check_out_at at time zone v_tz)::date as d_out, b.status
        from public.booking_meals m
        join public.bookings b on b.id = m.booking_id
        join public.guests g on g.id = b.guest_id
        join public.beds bd on bd.id = b.bed_id
        join public.rooms r on r.id = bd.room_id
       where m.property_id = p_property and b.status in ('pending','confirmed','checked_in','checked_out')
         and (b.check_in_at at time zone v_tz)::date <= p_day and (b.check_out_at at time zone v_tz)::date >= p_day),
    y as (select *, (breakfast and d_in < p_day) as has_b, (lunch and d_out > p_day) as has_l, (dinner and d_out > p_day) as has_d from x)
    select jsonb_build_object('day', p_day,
      'totals', jsonb_build_object(
        'breakfast', coalesce(sum(case when has_b then adults + children end), 0),
        'lunch', coalesce(sum(case when has_l then adults + children end), 0),
        'dinner', coalesce(sum(case when has_d then adults + children end), 0)),
      'rows', coalesce(jsonb_agg(jsonb_build_object('booking_id', id, 'code', code, 'guest', full_name, 'room', room, 'unit', unit,
          'plan', plan_name, 'adults', adults, 'children', children, 'breakfast', has_b, 'lunch', has_l, 'dinner', has_d)
          order by room, unit) filter (where has_b or has_l or has_d), '[]'::jsonb))
    from y);
end $$;

-- ---------------------------------------------------------------- house guide
create or replace function public.guide_get(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return coalesce((select to_jsonb(g) - 'property_id' from public.property_guide g where property_id = p_property), '{}'::jsonb);
end $$;

create or replace function public.guide_save(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t text[] := array['welcome','house_rules','wifi_name','wifi_password','directions','maps_url','host_name','host_phone','checkin_info','checkout_info','food_info'];
  v jsonb := '{}'::jsonb; k text; v_phone text;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  foreach k in array t loop v := v || jsonb_build_object(k, nullif(btrim(coalesce(p->>k, '')), '')); end loop;
  v_phone := nullif(regexp_replace(coalesce(v->>'host_phone', ''), '[\s\-()]', '', 'g'), '');
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Check the host phone number.'; end if;
  if v->>'maps_url' is not null and v->>'maps_url' !~* '^https?://' then raise exception 'The map link should start with https://'; end if;
  insert into public.property_guide as g (property_id, welcome, house_rules, wifi_name, wifi_password, directions, maps_url, host_name, host_phone,
                                          checkin_info, checkout_info, food_info, updated_at)
  values (p_property, v->>'welcome', v->>'house_rules', v->>'wifi_name', v->>'wifi_password', v->>'directions', v->>'maps_url', v->>'host_name',
          v_phone, v->>'checkin_info', v->>'checkout_info', v->>'food_info', now())
  on conflict (property_id) do update set welcome = excluded.welcome, house_rules = excluded.house_rules, wifi_name = excluded.wifi_name,
     wifi_password = excluded.wifi_password, directions = excluded.directions, maps_url = excluded.maps_url, host_name = excluded.host_name,
     host_phone = excluded.host_phone, checkin_info = excluded.checkin_info, checkout_info = excluded.checkout_info,
     food_info = excluded.food_info, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- The guest's own online check-in link → the house guide of that property (nothing else).
-- Only for live bookings; the Wi-Fi password is shown only from the check-in day on.
create or replace function public.guide_for_token(p_token uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select (to_jsonb(g) - 'property_id' - 'updated_at' - case when b.check_in_at > now() + interval '1 day' then 'wifi_password' else '' end)
           || jsonb_build_object('property', p.name)
      from public.bookings b
      join public.property_guide g on g.property_id = b.property_id
      join public.properties p on p.id = b.property_id
     where b.self_checkin_token = p_token and b.status in ('pending','confirmed','checked_in') and b.check_out_at > now()
     limit 1), '{}'::jsonb)
$$;

revoke execute on function public.meal_plans_list(uuid), public.meal_plan_save(uuid, jsonb), public.meal_plan_delete(uuid),
  public.booking_meal_get(uuid), public.booking_meal_set(uuid, uuid), public.kitchen_list(uuid, date),
  public.guide_get(uuid), public.guide_save(uuid, jsonb), public.guide_for_token(uuid) from public, anon;
grant execute on function public.meal_plans_list(uuid), public.meal_plan_save(uuid, jsonb), public.meal_plan_delete(uuid),
  public.booking_meal_get(uuid), public.booking_meal_set(uuid, uuid), public.kitchen_list(uuid, date),
  public.guide_get(uuid), public.guide_save(uuid, jsonb), public.guide_for_token(uuid) to authenticated;
grant execute on function public.guide_for_token(uuid) to anon;
