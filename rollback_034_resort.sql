-- =====================================================================
-- NammaStay · rollback_034_resort.sql — UNDO 034 (resorts)
-- Deletes: the resort switch, activities & their bookings, day packages, day visits & their
-- receipts (RP-…), stay packages, groups, extra-bed records.
-- Lines already added to room bills ("Package: …", "Activity: …", "Extra bed") STAY on those bills
-- as ordinary extras, and group payments stay as ordinary payments (money is not changed).
-- Take a backup first. Then put back the old website files. Safe to run more than once.
-- =====================================================================
begin;
do $$ declare f text; begin
  foreach f in array array[
    'resort_today(uuid, date)','group_pay(uuid, jsonb)','group_delete(uuid)','group_remove_booking(uuid)','group_save(uuid, jsonb)','group_get(uuid)','groups_list(uuid)',
    '_grp_row(public.booking_groups)','booking_resort_get(uuid)','booking_extra_beds_set(uuid, int)','booking_package_set(uuid, uuid)',
    '_sp_price(public.stay_packages, public.bookings)','stay_package_delete(uuid)','stay_package_save(uuid, jsonb)','stay_packages_list(uuid)',
    'resort_income(uuid, date, date)','day_visit_status(uuid, text)','day_visit_pay(uuid, jsonb)','day_visit_save(uuid, jsonb)',
    '_rs_pay(public.day_visits, jsonb, text)','day_visits_list(uuid, date)','_dv_row(public.day_visits)','dayout_package_delete(uuid)',
    'dayout_package_save(uuid, jsonb)','dayout_packages_list(uuid)','activity_booking_status(uuid, text)','activity_book(uuid, jsonb)',
    'activity_guests(uuid, date)','activity_schedule(uuid, date)','activity_delete(uuid)','activity_save(uuid, jsonb)','activities_list(uuid)',
    'resort_settings_save(uuid, jsonb)','resort_settings_get(uuid)','resort_set_mode(uuid, boolean)','resort_mode(uuid)',
    '_rs_room_paise(public.bookings)','_rs_is_resort(uuid)','_rs_rupees(int)','_rs_today(uuid)','_rs_view(uuid)'] loop
    execute 'drop function if exists public.' || f;
  end loop;
end $$;
drop table if exists public.activity_bookings;
drop table if exists public.booking_extra_beds;
drop table if exists public.booking_group_members;
drop table if exists public.booking_groups;
drop table if exists public.booking_packages;
drop table if exists public.stay_packages;
drop table if exists public.resort_payments;
drop table if exists public.day_visits;
drop table if exists public.dayout_packages;
drop table if exists public.activities;
drop table if exists public.resort_settings;
drop table if exists public.resort_properties;
drop sequence if exists public.resort_receipt_seq;
drop sequence if exists public.day_visit_seq;
commit;
