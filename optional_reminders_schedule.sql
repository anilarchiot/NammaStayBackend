-- =====================================================================
-- NammaStay · reminders_schedule.sql — billing reminders every morning (9:30 AM India)
-- Needs pg_cron + pg_net (Database → Extensions).
-- OPTION A (in-app + email): deploy the billing-reminders function, then replace
--   YOUR-PROJECT-REF and YOUR-CRON-SECRET below and run this.
-- OPTION B (in-app only, no email): run only the last statement instead.
-- =====================================================================
select cron.unschedule('nammastay-billing-reminders') where exists (select 1 from cron.job where jobname = 'nammastay-billing-reminders');
select cron.schedule('nammastay-billing-reminders', '0 4 * * *', $$
  select net.http_post(
    url := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/billing-reminders',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', 'YOUR-CRON-SECRET'),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$$);

-- OPTION B — in-app reminders only (no email, no edge function):
-- select cron.schedule('nammastay-billing-reminders', '0 4 * * *', $$ select public.run_billing_reminders(); $$);
