-- =====================================================================
-- NammaStay · which updates does my database still need?
-- Paste in Supabase → SQL Editor → Run.  false = run that file from the
-- "updates" folder, in number order (lowest first).
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
 ('031_pg_tenants',          exists(select 1 from information_schema.tables  where table_schema='public' and table_name='tenancies'))
) t(update_file, done) order by 1;
