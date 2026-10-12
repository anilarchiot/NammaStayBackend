-- =====================================================================
-- NammaStay · pg_schedule.sql — OPTIONAL daily job for PG / co-living tenants
-- Creates each month's rent & food on the rent day and keeps tenants' beds
-- held, even if nobody opens the Tenants & rent page that day.
-- (Without it, this happens anyway whenever the page is opened.)
-- Needs the pg_cron extension (Database → Extensions → pg_cron). Run once.
-- =====================================================================
select cron.unschedule('nammastay-pg-rent') where exists (select 1 from cron.job where jobname = 'nammastay-pg-rent');
select cron.schedule('nammastay-pg-rent', '35 18 * * *', $$ select public.pg_run_all(); $$);   -- 00:05 India time
