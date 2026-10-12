-- =====================================================================
-- NammaStay · rollback_030_031.sql — UNDO the Oct 2026 add-ons
--   031 PG / co-living (Tenants & rent)  and  030 other guests in a booking
--
-- Use ONLY if you must remove these features. It DELETES their data:
-- tenants, rent dues, rent payments, PG switch, and extra guests' details.
-- Everything that existed before 030/031 is left exactly as it was, and the
-- nightly ID-photo clean-up functions are put back to their 010 versions.
--
-- Before running:
--   1) Take a backup (Supabase → Database → Backups), or export the tables below.
--   2) See what would be lost:
--        select (select count(*) from public.tenancies)      as tenants,
--               (select count(*) from public.rent_payments)  as rent_payments,
--               (select count(*) from public.booking_guests) as extra_guests;
--   3) Extra guests' ID photos stay in Storage (bucket guest-ids). To list them first:
--        select id_doc_path, id_doc_back_path from public.booking_guests
--         where id_doc_path is not null or id_doc_back_path is not null;
-- Tenants' ₹0 bed bookings stay in Bookings as ordinary bookings (cancel or delete them there if needed).
-- Then also put back the old website files (see DEVELOPER-README).
-- Safe to run more than once.
-- =====================================================================
begin;

-- ---------- 031 · PG / co-living
do $$ begin
  if to_regclass('cron.job') is not null then                        -- only if pg_cron is installed
    execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'nammastay-pg-rent'$q$;
  end if;
end $$;
drop trigger if exists zz_pg_tenant_booking on public.bookings;
drop function if exists public._pg_keep_tenant_booking();
drop function if exists public.pg_tenants(uuid);
drop function if exists public.pg_tenant(uuid);
drop function if exists public.pg_move_in(uuid, jsonb);
drop function if exists public.pg_update(uuid, jsonb);
drop function if exists public.pg_add_charge(uuid, jsonb);
drop function if exists public.pg_edit_due(uuid, int, text);
drop function if exists public.pg_pay(uuid, jsonb);
drop function if exists public.pg_notice(uuid, date);
drop function if exists public.pg_move_out(uuid, jsonb);
drop function if exists public.pg_delete(uuid);
drop function if exists public.pg_run_all();
drop function if exists public.pg_mode(uuid);
drop function if exists public.pg_set_mode(uuid, boolean);
drop function if exists public._pg_sync(uuid);
drop function if exists public._pg_sync_one(uuid);
drop function if exists public._pg_today(uuid);
drop function if exists public._pg_at(uuid, date, boolean);
drop function if exists public._pg_set_end(uuid, uuid, date);
drop function if exists public._pg_close_segment(uuid);
do $$ begin
  if to_regclass('public.tenancies') is not null then
    execute 'drop function if exists public._pg_row(public.tenancies, date)';
    execute 'drop function if exists public._pg_hold(public.tenancies, date, date, public.booking_status, timestamptz)';
    execute 'drop function if exists public._pg_hold(public.tenancies, date, date, public.booking_status)';
  end if;
end $$;
drop table if exists public.rent_payments;
drop table if exists public.rent_dues;
drop table if exists public.tenancies;
drop table if exists public.pg_properties;
drop sequence if exists public.rent_receipt_seq;

-- ---------- 030 · other guests in a booking
drop trigger if exists booking_guests_trash on public.booking_guests;
drop function if exists public.booking_guests_list(uuid);
drop function if exists public.booking_guest_save(uuid, jsonb);
drop function if exists public.booking_guest_delete(uuid);

-- nightly ID-photo clean-up: back to the 010 versions (main guests only)
create or replace function public.id_docs_due_for_purge(p_limit int default 200)
returns table (guest_id uuid, path text)
language sql stable security definer set search_path = public, pg_temp as $$
  select x.id, x.path from (
    select g.id, unnest(array_remove(array[g.id_doc_path, g.id_doc_back_path], null)) as path, g.property_id
      from public.guests g
     where (g.id_doc_path is not null or g.id_doc_back_path is not null)) x
  join public.properties p on p.id = x.property_id
  where not exists (select 1 from public.bookings b where b.guest_id = x.id
                     and b.check_out_at > now() - make_interval(days => p.id_doc_retention_days))
  limit p_limit
$$;

create or replace function public.mark_id_doc_purged(p_guest uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.guests set id_doc_path = null, id_doc_back_path = null where id = p_guest
$$;
revoke execute on function public.id_docs_due_for_purge(int), public.mark_id_doc_purged(uuid) from public, anon, authenticated;
grant execute on function public.id_docs_due_for_purge(int), public.mark_id_doc_purged(uuid) to service_role;

drop table if exists public.booking_guest_doc_trash;
drop table if exists public.booking_guests;
drop function if exists public._booking_guest_trash();

commit;

-- Check: both should be false now
select exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'booking_guests') as has_030,
       exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'tenancies')      as has_031;
