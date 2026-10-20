-- Rollback of 040_company.sql — removes the admin "Company" data (NammaStay's own costs, money put in,
-- founders, other income, cash in bank, renewals and the weekly health scores).
-- WARNING: deletes what the admins entered on the Company page. Subscriptions, payments and invoices are not touched.
drop function if exists public.company_health();
drop function if exists public.company_badge();
drop function if exists public.company_renewal_delete(uuid);
drop function if exists public.company_renewal_done(uuid);
drop function if exists public.company_renewal_save(jsonb);
drop function if exists public.company_income_delete(uuid);
drop function if exists public.company_income_save(jsonb);
drop function if exists public.company_cost_delete(uuid);
drop function if exists public.company_cost_save(jsonb);
drop function if exists public.company_investment_delete(uuid);
drop function if exists public.company_investment_save(jsonb);
drop function if exists public.company_founder_delete(uuid);
drop function if exists public.company_founder_save(jsonb);
drop function if exists public.company_profile_save(jsonb);
drop function if exists public.company_summary();
drop function if exists public._co_area(text, text, text, text, text, text);
drop function if exists public._co_renewals();
drop function if exists public._co_next_due(date, text);
drop function if exists public._co_paying_at(timestamptz);
drop function if exists public._co_month_costs(date);
drop function if exists public._co_net(numeric);
drop function if exists public._co_month0();
drop table if exists public.company_health_snapshots;
drop table if exists public.company_renewals;
drop table if exists public.company_income;
drop table if exists public.company_costs;
drop table if exists public.company_investments;
drop table if exists public.company_founders;
drop table if exists public.company_profile;
