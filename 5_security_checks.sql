-- =====================================================================
-- NammaStay · security & integrity checks
-- Run in SQL Editor after 001–004. Every query should return 0 rows
-- (or the stated expected result). Re-run after any schema change.
-- =====================================================================

-- 1. Every table in public has Row Level Security ON           → expect 0 rows
select c.relname as table_without_rls
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

-- 2. Anonymous visitors have no direct table access             → expect only: plans / SELECT (public prices)
select table_name, privilege_type
  from information_schema.role_table_grants
 where grantee = 'anon' and table_schema = 'public';

-- 3. Signed-in staff can't insert/update/delete bookings or payments directly → expect 0 rows
select table_name, privilege_type
  from information_schema.role_table_grants
 where grantee = 'authenticated' and table_schema = 'public'
   and table_name in ('bookings','payments','audit_log','property_members','leads','platform_admins')
   and privilege_type in ('INSERT','UPDATE','DELETE');

-- 4. Functions anonymous visitors can call                      → expect exactly these 4:
--    checkin_upload_allowed, selfcheckin_get, selfcheckin_submit, submit_lead (006)
select p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
 order by 1;

-- 5. SECURITY DEFINER functions all pin search_path            → expect 0 rows
select p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prosecdef
   and not coalesce(array_to_string(p.proconfig, ',') like '%search_path%', false);

-- 6. ID photo bucket is private                                 → expect public = false
select id, public, file_size_limit from storage.buckets where id = 'guest-ids';

-- 7. Double-booking guard works (runs inside a rolled-back block) → expect NOTICE "PASS"
do $$
declare v_prop uuid; v_bed uuid; v_guest uuid;
begin
  select property_id, id into v_prop, v_bed from public.beds limit 1;
  insert into public.guests (property_id, full_name) values (v_prop, 'Test Guest') returning id into v_guest;
  insert into public.bookings (property_id, guest_id, bed_id, check_in_at, check_out_at, nights, rate_paise, total_paise, status)
  values (v_prop, v_guest, v_bed, now() + interval '400 days', now() + interval '402 days', 2, 1, 2, 'confirmed');
  begin
    insert into public.bookings (property_id, guest_id, bed_id, check_in_at, check_out_at, nights, rate_paise, total_paise, status)
    values (v_prop, v_guest, v_bed, now() + interval '401 days', now() + interval '403 days', 2, 1, 2, 'pending');
    raise notice 'FAIL: overlapping booking was accepted';
  exception when exclusion_violation then
    raise notice 'PASS: overlapping booking rejected';
  end;
  raise exception 'rollback test data' using errcode = 'P0002';
exception when sqlstate 'P0002' then
  null;  -- test rows are rolled back
end $$;

-- 8. Payments ledger can't be edited                            → expect NOTICE "PASS"
do $$
begin
  if exists (select 1 from public.payments) then
    begin
      update public.payments set note = note where id = (select id from public.payments limit 1);
      raise notice 'FAIL: payment was editable';
    exception when others then
      raise notice 'PASS: payments are append-only';
    end;
  else
    raise notice 'SKIP: no payments yet — re-run after the first payment';
  end if;
end $$;

-- 9. Size check (free plan limit is 500 MB)
select pg_size_pretty(pg_database_size(current_database())) as database_size;
select relname as table, pg_size_pretty(pg_total_relation_size(c.oid)) as size_with_indexes
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
 order by pg_total_relation_size(c.oid) desc;
