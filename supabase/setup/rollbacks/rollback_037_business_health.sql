-- Rollback of 037_business_health.sql — removes Business health (weekly snapshots are deleted).
drop function if exists public.business_health(uuid);
drop function if exists public._bh_area(text, text, text, text, text, text, text, integer);
drop function if exists public._bh_income(uuid, date, date);
drop function if exists public._bh_occ(uuid, date, date);
drop function if exists public._bh_tz(uuid);
drop table if exists public.business_health_snapshots;
