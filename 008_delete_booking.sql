-- =====================================================================
-- NammaStay · 008_delete_booking.sql
-- Delete a booking that was entered by mistake — any status, including a
-- guest who is checked in right now. Only that stay is removed; the guest's
-- profile and their other bookings are untouched, and the bed becomes free.
--
--   • Owner / manager: can delete any booking (its payments are deleted too).
--   • Front desk: only bookings created in the last 24 hours with no payments.
--   • A full copy (booking, guest name, payments, reason, who, when) is kept
--     in the activity log, so a deletion can always be traced.
--
-- Run AFTER 001–003 (and 006/007 if you use them).
-- (If you ran the earlier 008_delete_guest.sql, that's harmless — leave it.)
-- =====================================================================

-- Payments stay append-only, EXCEPT when delete_booking removes a wrong booking.
create or replace function public._payments_immutable() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' and current_setting('nammastay.deleting_booking', true) = 'on' then
    return old;
  end if;
  raise exception 'Payments can''t be edited or deleted. Record a refund instead.';
end $$;

create or replace function public.delete_booking(p_booking uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b        public.bookings%rowtype;
  v_role   public.member_role;
  v_pay    jsonb;
  v_guest  text;
  v_count  int;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  v_role := public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Please choose a reason for deleting.'; end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.received_at), '[]'::jsonb), count(*)
    into v_pay, v_count
    from public.payments p where p.booking_id = b.id;

  if v_role = 'front_desk' and (v_count > 0 or b.created_at < now() - interval '24 hours') then
    raise exception 'Front desk can only delete bookings made in the last 24 hours with no payments. Please ask the owner or manager.';
  end if;

  select full_name into v_guest from public.guests where id = b.guest_id;

  -- keep a full copy for the record
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'deleted',
          jsonb_build_object('reason', left(btrim(p_reason), 200), 'code', b.code, 'guest', v_guest,
                             'booking', to_jsonb(b), 'payments', v_pay), auth.uid());

  perform set_config('nammastay.deleting_booking', 'on', true);
  delete from public.payments where booking_id = b.id;
  delete from public.bookings where id = b.id;
  perform set_config('nammastay.deleting_booking', 'off', true);

  delete from public.notifications where booking_id = b.id;

  return jsonb_build_object('ok', true, 'code', b.code, 'guest', v_guest, 'payments_removed', v_count,
                            'amount_removed_paise', b.paid_paise);
end $$;

-- Deleted bookings, for the owner's records (Settings → Deleted bookings)
create or replace function public.list_deleted_bookings(p_property uuid, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'at', a.at, 'code', a.details->>'code', 'guest', a.details->>'guest', 'reason', a.details->>'reason',
            'check_in_at', a.details#>>'{booking,check_in_at}', 'check_out_at', a.details#>>'{booking,check_out_at}',
            'total_paise', (a.details#>>'{booking,total_paise}')::int, 'paid_paise', (a.details#>>'{booking,paid_paise}')::int,
            'by', (select coalesce(m.display_name, m.email) from public.property_members m
                    where m.property_id = a.property_id and m.user_id = a.actor)) order by a.at desc), '[]'::jsonb)
    from (select * from public.audit_log where property_id = p_property and entity = 'booking' and action = 'deleted'
          order by at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) a);
end $$;

revoke execute on function public.delete_booking(uuid, text), public.list_deleted_bookings(uuid, int) from public, anon, authenticated;
grant execute on function public.delete_booking(uuid, text), public.list_deleted_bookings(uuid, int) to authenticated;
