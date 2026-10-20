-- =====================================================================
-- NammaStay · undo_formc_badges_expenses.sql
-- ONLY if you already ran the old 008_formc_badges_expenses.sql.
-- Removes Form C, guest badges and expenses & profit from the database.
-- ⚠ Any expenses and Form C details you entered are deleted permanently.
--   Export them first if you need them.
-- Then run migrations/008_delete_guest.sql.
-- =====================================================================
drop function if exists public.form_c_list(uuid, text);
drop function if exists public.form_c_get(uuid);
drop function if exists public.form_c_save(uuid, jsonb);
drop function if exists public.form_c_mark(uuid, text, text, text);
drop function if exists public.selfcheckin_form_c(uuid, jsonb);
drop function if exists public._form_c_apply(uuid, jsonb);
drop function if exists public._form_c_ensure(uuid);
drop function if exists public._needs_form_c(text);
drop table if exists public.form_c;
drop type if exists public.form_c_status;

drop function if exists public.guest_badge(uuid);
alter table public.properties drop column if exists loyalty_enabled, drop column if exists loyalty_tiers;

drop function if exists public.profit_summary(uuid, date, date);
drop table if exists public.expenses;
