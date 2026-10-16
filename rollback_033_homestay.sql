-- =====================================================================
-- NammaStay · rollback_033_homestay.sql — UNDO 033 (homestay meal plans + house guide)
--
-- Deletes the meal plan list, the meal plan chosen on each booking and the house guide.
-- "Meals: …" lines already on bills STAY on those bills as ordinary extras (money is not changed).
-- Take a backup first. Then put back the old website files (see DEVELOPER-README).
-- Safe to run more than once.
-- =====================================================================
begin;
drop function if exists public.guide_for_token(uuid);
drop function if exists public.guide_save(uuid, jsonb);
drop function if exists public.guide_get(uuid);
drop function if exists public.kitchen_list(uuid, date);
drop function if exists public.booking_meal_set(uuid, uuid);
drop function if exists public.booking_meal_get(uuid);
drop function if exists public.meal_plan_delete(uuid);
drop function if exists public.meal_plan_save(uuid, jsonb);
drop function if exists public.meal_plans_list(uuid);
drop table if exists public.booking_meals;
drop table if exists public.property_guide;
drop table if exists public.meal_plans;
commit;
