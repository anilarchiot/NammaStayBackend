-- Rollback of 041_smart_pricing.sql — removes Smart pricing. Its "Smart pricing" price rules are deleted first,
-- so every night goes back to the owner's own prices. The owner's own price rules are not touched.
-- If you scheduled it with pg_cron: select cron.unschedule('nammastay-smart-pricing');
delete from public.rate_rules where id in (select rule_id from public.smart_price_rules);
drop function if exists public.sp_run_all();
drop function if exists public.sp_undo(uuid, uuid);
drop function if exists public.sp_pause(uuid, integer);
drop function if exists public.sp_run_now(uuid);
drop function if exists public.sp_night_lock(uuid, uuid, date, boolean);
drop function if exists public.sp_skip(uuid, jsonb);
drop function if exists public.sp_apply(uuid, jsonb);
drop function if exists public.sp_date_delete(uuid, uuid);
drop function if exists public.sp_date_save(uuid, jsonb);
drop function if exists public.sp_limits_save(uuid, jsonb);
drop function if exists public.sp_settings_save(uuid, jsonb);
drop function if exists public.sp_get(uuid);
drop function if exists public._sp_run(uuid, uuid);
drop function if exists public._sp_rebuild(uuid);
drop function if exists public._sp_groups(uuid);
drop function if exists public._sp_is_pg(uuid);
drop function if exists public._sp_check(uuid);
drop function if exists public._sp_today(uuid);
drop function if exists public._sp_tz(uuid);
drop table if exists public.smart_price_runs;
drop table if exists public.smart_price_rules;
drop table if exists public.smart_price_nights;
drop table if exists public.smart_price_dates;
drop table if exists public.smart_price_limits;
drop table if exists public.smart_price_settings;
