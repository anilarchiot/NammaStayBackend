-- =====================================================================
-- NammaStay · load test (lakhs of rows)
--
-- ⚠ Run this ONLY in a separate, throwaway Supabase project — never in
--   your live one. (Free plan allows 2 projects: use one for testing.)
--   Run 001–003 there first, then create a test login in
--   Authentication → Users and put its email below.
--
-- Creates ~1.5 lakh bookings + 1.5 lakh guests + ~1 lakh payments:
--   • "LT Big": 200 beds × 500 stays = 1,00,000 bookings in ONE property
--   • 25 smaller properties × 20 beds × 100 stays = 50,000 bookings
-- Takes 1–3 minutes. Then prints how long each screen's query takes.
-- Target: every call under ~300 ms. Typical results are far lower.
-- =====================================================================

-- ---------- Step 1: generate data ----------
do $$
declare
  v_email text := 'loadtest@example.com';   -- ← CHANGE to your test login
  v_user uuid;
  v_big uuid;
begin
  select id into v_user from auth.users where lower(email) = lower(v_email);
  if v_user is null then raise exception 'Create the test login % first.', v_email; end if;

  alter table public.bookings disable trigger user;
  alter table public.payments disable trigger user;

  insert into public.properties (name) values ('LT Big') returning id into v_big;
  insert into public.property_members (property_id, user_id, role, email) values (v_big, v_user, 'owner', v_email);
  insert into public.properties (name) select 'LT Small ' || i from generate_series(1, 25) i;

  -- rooms: Big = 10 rooms × 20 beds; Small = 2 rooms × 10 beds
  insert into public.rooms (property_id, name, sort)
  select p.id, 'Room ' || r, r
    from public.properties p
    cross join lateral generate_series(1, case when p.id = v_big then 10 else 2 end) r
   where p.name like 'LT %';

  insert into public.beds (property_id, room_id, label, position, rate_paise, sort)
  select r.property_id, r.id, 'Bed ' || b, case when b % 2 = 0 then 'upper' else 'lower' end::public.bed_position,
         case when b % 2 = 0 then 60000 else 70000 end, b
    from public.rooms r join public.properties p on p.id = r.property_id
    cross join lateral generate_series(1, case when p.id = v_big then 20 else 10 end) b
   where p.name like 'LT %';

  -- one stay every 3 days per bed: 2 nights, 2 PM → 11 AM; half in the past, half future
  create temp table lt_plan on commit drop as
  select gen_random_uuid() as guest_id, gen_random_uuid() as booking_id,
         bd.property_id, bd.id as bed_id, bd.rate_paise, k,
         ((date_trunc('day', now() at time zone 'Asia/Kolkata')
           - make_interval(days => (case when bd.property_id = v_big then 500 else 100 end) * 3 / 2)
           + make_interval(days => k * 3) + interval '14 hours') at time zone 'Asia/Kolkata') as cin
    from public.beds bd
    join public.properties p on p.id = bd.property_id
    cross join lateral generate_series(0, case when p.id = v_big then 499 else 99 end) k
   where p.name like 'LT %';

  insert into public.guests (id, property_id, full_name, phone, nationality, created_at)
  select guest_id, property_id,
         (array['Rahul','Priya','Emma','Aravind','Sofia','Karthik','Divya','Marco','Noa','Farah'])[1 + (k % 10)]
           || ' ' || (array['Kannan','N.','Torres','V.','Jensen','R.','Menon','Klein','Levi','Ali'])[1 + ((k / 10) % 10)]
           || ' ' || substr(guest_id::text, 1, 4),
         '+9198' || lpad((abs(hashtext(guest_id::text)) % 100000000)::text, 8, '0'),
         (array['India','India','India','Germany','Spain','France','UK','Israel'])[1 + (k % 8)],
         cin - interval '3 days'
    from lt_plan;

  insert into public.bookings (id, property_id, guest_id, bed_id, check_in_at, check_out_at, nights,
                               rate_paise, total_paise, paid_paise, status, source, created_at)
  select booking_id, property_id, guest_id, bed_id, cin, cin + interval '1 day 21 hours', 2,
         rate_paise, rate_paise * 2,
         case when cin < now() then rate_paise * 2 else 0 end,
         case when k % 20 = 7 then 'cancelled'
              when cin + interval '1 day 21 hours' < now() then 'checked_out'
              when cin <= now() then 'checked_in'
              else 'confirmed' end::public.booking_status,
         (array['walk_in','direct','ota','referral'])[1 + (k % 4)]::public.booking_source,
         cin - interval '3 days'
    from lt_plan;

  insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, received_at)
  select property_id, booking_id, 'payment',
         (array['upi','cash','card','upi'])[1 + (k % 4)]::public.payment_method,
         rate_paise * 2,
         case when k % 4 in (0, 3) then 'LT' || replace(booking_id::text, '-', '') end,
         cin
    from lt_plan where cin < now() and k % 20 <> 7;

  alter table public.bookings enable trigger user;
  alter table public.payments enable trigger user;
end $$;

analyze public.guests;
analyze public.bookings;
analyze public.payments;

-- ---------- Step 2: time every screen's query as the test owner ----------
do $$
declare
  v_email text := 'loadtest@example.com';   -- ← same email as above
  v_user uuid; v_prop uuid; v_guest uuid; v_booking uuid;
  t timestamptz; c_at timestamptz; c_id uuid;
  v_phone text;
begin
  select id into v_user from auth.users where lower(email) = lower(v_email);
  select id into v_prop from public.properties where name = 'LT Big';
  perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  raise notice 'Rows in LT Big: % bookings, % guests, % payments',
    (select count(*) from public.bookings where property_id = v_prop),
    (select count(*) from public.guests   where property_id = v_prop),
    (select count(*) from public.payments where property_id = v_prop);

  t := clock_timestamp(); perform public.dashboard_summary(v_prop);
  raise notice 'Dashboard ............... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform count(*) from public.list_bookings(v_prop, null, null, null, null, 30);
  raise notice 'Bookings page 1 ......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform public.booking_status_counts(v_prop);
  raise notice 'Status counts ........... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  select check_in_at, id into c_at, c_id from public.bookings
   where property_id = v_prop order by check_in_at desc, id desc offset 60000 limit 1;
  t := clock_timestamp(); perform count(*) from public.list_bookings(v_prop, null, 'Rahul', c_at, c_id, 30);
  raise notice 'Search, 60,000 rows deep  % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform count(*) from public.list_bookings(v_prop, null, 'Emma Torres', null, null, 30);
  raise notice 'Search by name .......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  select phone into v_phone from public.guests where property_id = v_prop offset 12345 limit 1;
  t := clock_timestamp(); perform count(*) from public.list_bookings(v_prop, null, right(v_phone, 6), null, null, 30);
  raise notice 'Search by phone ......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  select id, guest_id into v_booking, v_guest from public.bookings where property_id = v_prop offset 40000 limit 1;
  t := clock_timestamp(); perform public.booking_detail(v_booking);
  raise notice 'Booking detail .......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform public.guest_profile(v_guest);
  raise notice 'Guest profile ........... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform public.bed_board(v_prop);
  raise notice 'Rooms board (200 beds) .. % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform public.calendar_range(v_prop, current_date - 4, 9);
  raise notice 'Calendar 9 days ......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform count(*) from public.list_payments(v_prop, null, null, null, null, null, 30);
  raise notice 'Payments page 1 ......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform public.payment_summary(v_prop, date_trunc('month', current_date)::date, current_date);
  raise notice 'Payments summary ........ % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform public.report_summary(v_prop, current_date - 29, current_date);
  raise notice 'Reports, 30 days ........ % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform public.report_summary(v_prop, current_date - 364, current_date);
  raise notice 'Reports, 1 year ......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);

  t := clock_timestamp(); perform count(*) from public.available_beds(v_prop, now() + interval '2 days', now() + interval '4 days');
  raise notice 'Available beds .......... % ms', round(extract(epoch from clock_timestamp() - t) * 1000);
end $$;

-- ---------- Step 3: confirm indexes are used (look for "Index" / "Bitmap", not "Seq Scan" on bookings) ----------
explain (analyze, buffers)
select b.id from public.bookings b
 where b.property_id = (select id from public.properties where name = 'LT Big')
   and b.check_out_at >= now() - interval '30 days'
 order by b.check_in_at desc, b.id desc limit 30;

-- Size after load (compare against your plan's limit)
select pg_size_pretty(pg_database_size(current_database())) as database_size;

-- ---------- Cleanup (or simply delete the test project) ----------
-- do $$ begin
--   alter table public.payments disable trigger user;
--   delete from public.payments  where property_id in (select id from public.properties where name like 'LT %');
--   alter table public.payments enable trigger user;
--   delete from public.bookings  where property_id in (select id from public.properties where name like 'LT %');
--   delete from public.guests    where property_id in (select id from public.properties where name like 'LT %');
--   delete from public.beds      where property_id in (select id from public.properties where name like 'LT %');
--   delete from public.rooms     where property_id in (select id from public.properties where name like 'LT %');
--   delete from public.properties where name like 'LT %';
-- end $$;
