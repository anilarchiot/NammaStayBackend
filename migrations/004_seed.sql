-- =====================================================================
-- NammaStay · 004_seed.sql
-- Your real property, rooms and beds, and you as the owner.
--
-- BEFORE RUNNING:
--   1. Supabase → Authentication → Users → "Add user" → create your own
--      login (email + strong password). Tick "Auto confirm user".
--   2. Replace owner@example.com below with that email.
-- Rates are in paise: ₹700 = 70000. Edit names/rates later in the app.
-- =====================================================================
do $$
declare
  v_owner_email text := 'owner@example.com';   -- ← CHANGE THIS
  v_user uuid;
  v_prop uuid;
  v_dorm6 uuid;
  v_dorm3 uuid;
begin
  select id into v_user from auth.users where lower(email) = lower(v_owner_email);
  if v_user is null then
    raise exception 'Create the login % in Authentication → Users first.', v_owner_email;
  end if;

  insert into public.properties (name, kind, address, city)
  values ('Social Backpackers Hostel', 'hostel', 'Little Mount', 'Chennai')
  returning id into v_prop;

  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (v_prop, v_user, 'owner', 'Owner', lower(v_owner_email));

  insert into public.rooms (property_id, name, description, sort)
  values (v_prop, '6-Bed Mixed Dorm', 'Fan · Shared bath', 1) returning id into v_dorm6;
  insert into public.rooms (property_id, name, description, sort)
  values (v_prop, '3-Bed Dorm', 'AC · Shared bath', 2) returning id into v_dorm3;

  insert into public.beds (property_id, room_id, label, position, rate_paise, sort) values
    (v_prop, v_dorm6, 'Lower A1', 'lower', 70000, 1),
    (v_prop, v_dorm6, 'Upper A1', 'upper', 60000, 2),
    (v_prop, v_dorm6, 'Lower A2', 'lower', 70000, 3),
    (v_prop, v_dorm6, 'Upper A2', 'upper', 60000, 4),
    (v_prop, v_dorm6, 'Lower A3', 'lower', 70000, 5),
    (v_prop, v_dorm6, 'Upper A3', 'upper', 60000, 6),
    (v_prop, v_dorm3, 'Lower C1', 'lower', 85000, 1),
    (v_prop, v_dorm3, 'Lower C2', 'lower', 85000, 2),
    (v_prop, v_dorm3, 'Lower C3', 'lower', 85000, 3);

  raise notice 'Property created: %  (9 beds). Owner: %', v_prop, v_owner_email;
end $$;
