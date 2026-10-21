-- =====================================================================
-- NammaStay · which updates does my database still need?
-- Paste in Supabase → SQL Editor → Run. false = run that migration from
-- supabase/migrations, in number order (lowest first).
-- Current frontend features need 001–037 (including the 035 fix), 039–041, 043–047.
-- 038 (public booking page) and 042 (staff management) are optional features.
-- =====================================================================
select * from (values
 ('001-003 core',            exists(select 1 from information_schema.tables  where table_schema='public' and table_name='bookings')),
 ('006_marketing',           exists(select 1 from information_schema.tables  where table_schema='public' and table_name='leads')),
 ('007_subscriptions',       exists(select 1 from information_schema.tables  where table_schema='public' and table_name='plans')),
 ('008_delete_booking',      exists(select 1 from pg_proc where proname='delete_booking')),
 ('009_edit_guest',          exists(select 1 from pg_proc where proname='update_guest')),
 ('010_id_front_back',       exists(select 1 from information_schema.columns where table_name='guests' and column_name='id_doc_back_path')),
 ('011_admin_panel',         exists(select 1 from pg_proc where proname='admin_overview')),
 ('012_delete_guest',        exists(select 1 from pg_proc where proname='delete_guest' and pronargs=2)),
 ('013_admin_add_property',  exists(select 1 from information_schema.tables  where table_schema='public' and table_name='property_invites')),
 ('014_hotels_homestays',    exists(select 1 from information_schema.columns where table_name='beds' and column_name='max_guests')),
 ('015_plans_by_type',       exists(select 1 from information_schema.columns where table_name='plans' and column_name='kind')),
 ('016_extras',              exists(select 1 from information_schema.tables  where table_schema='public' and table_name='extra_items')),
 ('017_role_permissions',    exists(select 1 from information_schema.columns where table_name='properties' and column_name='role_permissions')),
 ('018_invoice_offers',      exists(select 1 from information_schema.tables  where table_schema='public' and table_name='invoices')),
 ('019_prices_oct_2026',     exists(select 1 from public.plans where id = 'monthly' and price_paise = 399900)),
 ('020_ota_sync',            exists(select 1 from information_schema.tables  where table_schema='public' and table_name='ota_feeds')),
 ('021_expenses_paylinks',   exists(select 1 from information_schema.tables  where table_schema='public' and table_name='payment_links')),
 ('022_admin_2fa',           exists(select 1 from pg_proc where proname='admin_mfa_info')),
 ('023_platform_invoices',   exists(select 1 from information_schema.tables  where table_schema='public' and table_name='platform_invoices')),
 ('024_form_c',              exists(select 1 from information_schema.tables  where table_schema='public' and table_name='form_c')),
 ('025_admin_growth',        exists(select 1 from information_schema.tables  where table_schema='public' and table_name='coupons')),
 ('026_pricing_housekeeping', exists(select 1 from information_schema.tables  where table_schema='public' and table_name='rate_rules')),
 ('027_channex',             exists(select 1 from information_schema.tables  where table_schema='public' and table_name='channex_links')),
 ('028_onboarding',          exists(select 1 from information_schema.columns where table_name='properties' and column_name='setup_done_at')),
 ('029_public_api',          exists(select 1 from information_schema.tables  where table_schema='public' and table_name='api_keys')),
 ('030_booking_guests',      exists(select 1 from information_schema.tables  where table_schema='public' and table_name='booking_guests')),
 ('031_pg_tenants (latest)', exists(select 1 from pg_proc where proname = 'pg_set_mode') and exists(select 1 from information_schema.columns where table_name='rent_dues' and column_name='credit_paise')),
 ('032_pg_app',              exists(select 1 from pg_proc where proname = 'pg_dashboard')),
 ('033_homestay',            exists(select 1 from pg_proc where proname = 'booking_meal_set')),
 ('034_resort',              exists(select 1 from pg_proc where proname = 'activity_book')),
 ('035_fix_upi_check',      not exists(select 1 from pg_constraint
    where conrelid in (to_regclass('public.properties'), to_regclass('public.platform_settings'))
      and contype = 'c' and pg_get_constraintdef(oid) like '%{2,256}%')),
 ('036_investment',          exists(select 1 from pg_proc where proname = 'legal_checklist_get')),
 ('037_business_health',     exists(select 1 from pg_proc where proname = 'business_health')),
 ('038_booking_page (optional)', exists(select 1 from pg_proc where proname = 'bp_public')),
 ('039_my_business',         exists(select 1 from pg_proc where proname = 'biz_summary')),
 ('040_company',             exists(select 1 from pg_proc where proname = 'company_health')),
 ('041_smart_pricing',       exists(select 1 from pg_proc where proname = 'sp_get')),
 ('042_staff (optional)',    exists(select 1 from pg_proc where proname = 'staff_get')),
 ('043_branches',            exists(select 1 from pg_proc where proname = 'branch_create')),
 ('044_channex_key',         exists(select 1 from pg_proc where proname = 'cx_key_save')),
 ('045_public_property_count', exists(select 1 from pg_proc where proname = 'public_property_count')),
 ('046_property_type_sync', exists(select 1 from pg_trigger where tgname = 'sync_property_type_modes' and not tgisinternal)),
 ('047_preserve_property_mode_data',
    exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pg_properties' and column_name = 'enabled')
    and exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'resort_properties' and column_name = 'enabled'))
) t(update_file, done) order by 1;
