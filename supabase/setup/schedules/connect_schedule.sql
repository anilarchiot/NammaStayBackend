-- =====================================================================
-- NammaStay · connect_schedule.sql — NammaStay Connect every minute
-- (pull OTA reservations, push only what changed, full refresh once a day).
-- Needs pg_cron + pg_net and the `connect` edge function (deploy with --no-verify-jwt).
-- BEFORE RUNNING: replace YOUR-CRON-SECRET with the CRON_SECRET you set for the functions.
-- =====================================================================
select cron.unschedule('nammastay-connect') where exists (select 1 from cron.job where jobname = 'nammastay-connect');
select cron.schedule('nammastay-connect', '* * * * *', $$
  select net.http_post(
    url := 'https://skcqpfyshbxcyyamsgtj.supabase.co/functions/v1/connect',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', 'YOUR-CRON-SECRET'),
    body := '{}'::jsonb, timeout_milliseconds := 55000);
$$);
