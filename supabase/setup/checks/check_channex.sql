-- NammaStay · check what's already in place for Channex (read-only, safe to run)
select 'Database 027 (channel manager tables)' as item,
       case when to_regclass('public.channex_links') is not null then 'OK — already run' else 'MISSING — run 027_channex.sql' end as status
union all
select 'Database 044 (Channex key from admin screen)',
       case when to_regclass('public.cx_settings') is not null then 'OK — already run' else 'MISSING — run 044_channex_key.sql' end
union all
select 'Channex key saved in admin screen',
       case when to_regclass('public.cx_settings') is null then 'n/a (run 044 first)' else 'see Admin → Channel manager' end
union all
select 'Every-5-minutes sync (cron job)',
       case when exists (select 1 from cron.job where jobname = 'nammastay-channex') then 'OK — scheduled' else 'MISSING — run channex_schedule.sql' end
union all
select 'Calendar (iCal) sync cron job',
       case when exists (select 1 from cron.job where command ilike '%ota-sync%') then 'OK — scheduled' else 'MISSING — run ota_schedule.sql' end;
