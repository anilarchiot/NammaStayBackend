-- =====================================================================
-- 035_fix_upi_check.sql  — fix "invalid regular expression: invalid repetition count(s)"
--
-- The UPI ID checks on properties.upi_id (001) and platform_settings.upi_id (007) used
-- the pattern {2,256}. Postgres allows repeat counts up to 255 only, so EVERY non-empty
-- UPI ID failed to save (owners in Settings → Property, and admin Billing settings).
--
-- This file swaps only those two checks for the same rule with {2,255}. Nothing else
-- changes. Safe to run more than once. Run in Supabase → SQL Editor.
-- =====================================================================
do $$
declare r record;
begin
  -- drop the broken checks (whatever their names are)
  for r in
    select c.conrelid::regclass as tbl, c.conname
    from pg_constraint c
    where c.contype = 'c'
      and c.conrelid in ('public.properties'::regclass, 'public.platform_settings'::regclass)
      and pg_get_constraintdef(c.oid) like '%upi_id%'
      and pg_get_constraintdef(c.oid) like '%{2,256}%'
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;

  -- add the corrected checks (once)
  if not exists (select 1 from pg_constraint where conname = 'properties_upi_id_format') then
    alter table public.properties add constraint properties_upi_id_format
      check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,255}@[A-Za-z]{2,64}$');
  end if;
  if to_regclass('public.platform_settings') is not null
     and not exists (select 1 from pg_constraint where conname = 'platform_settings_upi_id_format') then
    alter table public.platform_settings add constraint platform_settings_upi_id_format
      check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,255}@[A-Za-z]{2,64}$');
  end if;
end $$;

-- Check: both rows should say true
select 'properties' as tbl, exists (select 1 from pg_constraint where conname = 'properties_upi_id_format') as fixed
union all
select 'platform_settings', exists (select 1 from pg_constraint where conname = 'platform_settings_upi_id_format');
