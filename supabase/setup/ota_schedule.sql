-- =====================================================================
-- NammaStay · ota_schedule.sql — run OTA calendar sync every 30 minutes
-- BEFORE RUNNING: replace YOUR-PROJECT-REF and YOUR-CRON-SECRET (the same
-- secret you set for the edge functions: supabase secrets set CRON_SECRET=…).
-- Needs the pg_cron and pg_net extensions (Database → Extensions).
-- =====================================================================
select cron.unschedule('nammastay-ota-sync') where exists (select 1 from cron.job where jobname = 'nammastay-ota-sync');
select cron.schedule(
  'nammastay-ota-sync',
  '*/30 * * * *',
  $$
  select net.http_post(
    url     := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/ota-sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', 'YOUR-CRON-SECRET'),
    body    := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
  $$
);
