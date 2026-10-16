-- Rollback of 039_my_business.sql — removes loans, partners, payouts, lease and the 3 answers (My business).
-- WARNING: deletes the owners' loan, partner, payout and lease records. Investments stay (only the "who paid" link goes).
-- If you scheduled the reminders with pg_cron: select cron.unschedule('nammastay-my-business-reminders');
drop function if exists public.biz_summary(uuid);
drop function if exists public.biz_profile_save(uuid, jsonb);
drop function if exists public.biz_loan_save(uuid, jsonb);
drop function if exists public.biz_loan_delete(uuid);
drop function if exists public.biz_partner_save(uuid, jsonb);
drop function if exists public.biz_partner_delete(uuid);
drop function if exists public.biz_investment_partner(uuid, uuid);
drop function if exists public.biz_payout_save(uuid, jsonb);
drop function if exists public.biz_payout_delete(uuid);
drop function if exists public.biz_lease_save(uuid, jsonb);
drop function if exists public.biz_remind_all();
drop function if exists public._biz_notify(uuid);
drop function if exists public._biz_remind(uuid, text, text, text);
drop function if exists public._biz_lease(public.business_lease, date);
drop function if exists public._biz_loan(public.business_loans, date);
drop function if exists public._biz_months(date, date);
alter table if exists public.investments drop column if exists partner_id;
drop table if exists public.business_reminders;
drop table if exists public.business_lease;
drop table if exists public.partner_payouts;
drop table if exists public.business_partners;
drop table if exists public.business_loans;
drop table if exists public.business_profile;
