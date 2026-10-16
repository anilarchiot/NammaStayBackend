-- =====================================================================
-- NammaStay · 005_schedule.sql  (optional but recommended)
-- Runs the ID-photo cleanup every night at 3:00 AM IST.
--
-- BEFORE RUNNING:
--   1. Database → Extensions: enable "pg_cron" and "pg_net".
--   2. Deploy the purge-id-docs function and set its CRON_SECRET.
--   3. Replace YOUR-PROJECT-REF and YOUR-CRON-SECRET below.
-- =====================================================================
select cron.schedule(
  'nammastay-purge-id-docs',
  '30 21 * * *',                         -- 21:30 UTC = 03:00 IST
  $$
  select net.http_post(
    url     := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/purge-id-docs',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', 'YOUR-CRON-SECRET'),
    body    := '{}'::jsonb
  );
  $$
);
