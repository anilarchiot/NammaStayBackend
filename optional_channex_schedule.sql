-- =====================================================================
-- NammaStay · channex_schedule.sql — two-way channel manager every 5 minutes
-- (pull OTA bookings for everyone; push availability & prices where something changed;
--  a full push once a day). Needs pg_cron + pg_net and the `channex` edge function.
-- BEFORE RUNNING: replace YOUR-PROJECT-REF and YOUR-CRON-SECRET.
-- Channex also recommends acting on bookings quickly — 5 minutes is a safe start.
-- =====================================================================
select cron.unschedule('nammastay-channex') where exists (select 1 from cron.job where jobname = 'nammastay-channex');
select cron.schedule('nammastay-channex', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/channex',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', 'YOUR-CRON-SECRET'),
    body := '{}'::jsonb, timeout_milliseconds := 120000);
$$);
