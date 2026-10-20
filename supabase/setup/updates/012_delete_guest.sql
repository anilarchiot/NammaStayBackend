-- =====================================================================
-- NammaStay · 012_delete_guest.sql
-- Delete a guest completely (owner / manager only): the guest profile,
-- ALL their bookings (any status) and the payments on those bookings.
-- A copy of every deleted booking is kept in the activity log
-- (Settings → Deleted bookings), marked "Guest deleted: <reason>".
-- Returns the ID photo paths so the app can delete the files too.
-- Run AFTER 008_delete_booking.sql and 010_id_front_back.sql.
-- =====================================================================

drop function if exists public.delete_guest(uuid);        -- earlier "erase details" version, replaced

create or replace function public.delete_guest(p_guest uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  g        public.guests%rowtype;
  b        public.bookings%rowtype;
  v_pay    jsonb;
  v_count  int := 0;
  v_paid   bigint := 0;
begin
  select * into g from public.guests where id = p_guest for update;
  if not found then raise exception 'Guest not found.'; end if;
  perform public._assert_role(g.property_id, array['owner','manager']::public.member_role[]);
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Please choose a reason for deleting.'; end if;

  perform set_config('nammastay.deleting_booking', 'on', true);
  for b in select * from public.bookings where guest_id = p_guest for update loop
    select coalesce(jsonb_agg(to_jsonb(p) order by p.received_at), '[]'::jsonb) into v_pay
      from public.payments p where p.booking_id = b.id;
    insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
    values (b.property_id, 'booking', b.id, b.id, 'deleted',
            jsonb_build_object('reason', 'Guest deleted: ' || left(btrim(p_reason), 180), 'code', b.code, 'guest', g.full_name,
                               'booking', to_jsonb(b), 'payments', v_pay), auth.uid());
    delete from public.payments where booking_id = b.id;
    delete from public.notifications where booking_id = b.id;
    delete from public.bookings where id = b.id;
    v_count := v_count + 1;
    v_paid := v_paid + b.paid_paise;
  end loop;
  perform set_config('nammastay.deleting_booking', 'off', true);

  delete from public.guests where id = p_guest;

  insert into public.audit_log (property_id, entity, entity_id, action, details, actor)
  values (g.property_id, 'guest', g.id, 'deleted',
          jsonb_build_object('guest', g.full_name, 'reason', left(btrim(p_reason), 200),
                             'bookings_removed', v_count, 'paid_removed_paise', v_paid), auth.uid());

  return jsonb_build_object('ok', true, 'guest', g.full_name, 'bookings_removed', v_count, 'paid_removed_paise', v_paid,
                            'id_doc_paths', to_jsonb(array_remove(array[g.id_doc_path, g.id_doc_back_path], null)));
end $$;

revoke execute on function public.delete_guest(uuid, text) from public, anon, authenticated;
grant execute on function public.delete_guest(uuid, text) to authenticated;
