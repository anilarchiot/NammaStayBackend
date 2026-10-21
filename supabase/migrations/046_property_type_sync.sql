-- Keep the stored property type and PG / resort mode switches in sync.
-- A PG is stored as a hostel and a resort as a hotel; their mode rows select
-- the corresponding UI. Updating kind to hostel also disables either mode.
create or replace function public._sync_property_type_modes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind = 'hostel' then
    delete from public.pg_properties where property_id = new.id;
    delete from public.resort_properties where property_id = new.id;
  else
    delete from public.pg_properties where property_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists sync_property_type_modes on public.properties;
-- UPDATE OF fires even when kind remains 'hostel', which is how PG is stored.
create trigger sync_property_type_modes
  after update of kind on public.properties
  for each row execute function public._sync_property_type_modes();

create or replace function public.admin_property(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  if not exists (select 1 from public.properties where id = p_property) then raise exception 'Property not found.'; end if;
  return (select jsonb_build_object(
    'property', jsonb_build_object(
      'id', p.id, 'name', p.name,
      'kind', case
        when exists (select 1 from public.pg_properties where property_id = p.id) then 'pg'
        when exists (select 1 from public.resort_properties where property_id = p.id) then 'resort'
        else p.kind
      end,
      'address', p.address, 'city', p.city, 'phone', p.phone, 'email', p.email,
      'upi_id', p.upi_id, 'created_at', p.created_at),
    'subscription', to_jsonb(s) || jsonb_build_object('state', public._access_state(p.id)),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('name', m.display_name, 'email', m.email, 'role', m.role,
                  'last_seen_at', m.last_seen_at) order by m.role, m.created_at), '[]'::jsonb)
                from public.property_members m where m.property_id = p.id),
    'usage', jsonb_build_object(
       'rooms', (select count(*) from public.rooms where property_id = p.id),
       'beds', (select count(*) from public.beds where property_id = p.id and is_active),
       'guests', (select count(*) from public.guests where property_id = p.id),
       'bookings_total', (select count(*) from public.bookings where property_id = p.id),
       'bookings_30d', (select count(*) from public.bookings where property_id = p.id and created_at > now() - interval '30 days'),
       'guest_payments_30d_paise', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                                     from public.payments where property_id = p.id and received_at > now() - interval '30 days'),
       'last_booking_at', (select max(created_at) from public.bookings where property_id = p.id),
       'last_seen_at', (select max(last_seen_at) from public.property_members where property_id = p.id)),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', sp.id, 'plan_id', sp.plan_id, 'amount_paise', sp.amount_paise, 'utr', sp.utr,
                  'status', sp.status, 'submitted_at', sp.submitted_at, 'review_note', sp.review_note,
                  'period_start', sp.period_start, 'period_end', sp.period_end) order by sp.submitted_at desc), '[]'::jsonb)
                 from public.subscription_payments sp where sp.property_id = p.id))
    from public.properties p join public.subscriptions s on s.property_id = p.id where p.id = p_property);
end $$;

create or replace function public.admin_set_property(p_property uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_days int := nullif(p->>'extend_days', '')::int;
  v_kind text;
  v_property_kind text;
begin
  perform public._assert_platform_admin();
  if v_days is not null and (v_days < -3650 or v_days > 3650) then raise exception 'Enter a sensible number of days.'; end if;
  if coalesce((p->>'suspend')::boolean, false) and coalesce(btrim(p->>'suspend_reason'), '') = '' then
    raise exception 'Add a short reason for suspending (the owner sees it).';
  end if;
  if p ? 'kind' then
    v_kind := p->>'kind';
    if v_kind is null or v_kind not in ('hostel', 'pg', 'hotel', 'homestay', 'resort') then
      raise exception 'Choose a valid property type.';
    end if;
  end if;
  update public.subscriptions set
    paid_until = case when v_days is null or v_days = 0 then paid_until
                      else greatest(now(), coalesce(paid_until, now()), trial_ends_at) + make_interval(days => v_days) end,
    is_complimentary = coalesce((p->>'complimentary')::boolean, is_complimentary),
    is_suspended = coalesce((p->>'suspend')::boolean, is_suspended),
    suspended_reason = case when p ? 'suspend' then case when (p->>'suspend')::boolean then left(btrim(p->>'suspend_reason'), 300) end else suspended_reason end,
    suspended_at = case when p ? 'suspend' then case when (p->>'suspend')::boolean then coalesce(suspended_at, now()) end else suspended_at end,
    admin_note = case when p ? 'admin_note' then nullif(left(btrim(p->>'admin_note'), 4000), '') else admin_note end
  where property_id = p_property;
  if not found then raise exception 'Property not found.'; end if;

  if v_kind is not null then
    v_property_kind := case when v_kind in ('pg', 'hostel') then 'hostel'
                            when v_kind = 'resort' then 'hotel'
                            else v_kind end;
    update public.properties set kind = v_property_kind where id = p_property;
    if not found then raise exception 'Property not found.'; end if;
    delete from public.pg_properties where property_id = p_property;
    delete from public.resort_properties where property_id = p_property;
    if v_kind = 'pg' then
      insert into public.pg_properties (property_id) values (p_property) on conflict do nothing;
    elsif v_kind = 'resort' then
      insert into public.resort_properties (property_id) values (p_property) on conflict do nothing;
    end if;
  end if;

  if p ? 'suspend' then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'subscription',
            case when (p->>'suspend')::boolean then 'Account suspended' else 'Account reactivated' end,
            case when (p->>'suspend')::boolean then left(btrim(p->>'suspend_reason'), 300) else 'You can take new bookings again.' end);
  end if;
end $$;

revoke execute on function public.admin_property(uuid), public.admin_set_property(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.admin_property(uuid), public.admin_set_property(uuid, jsonb)
  to authenticated;
