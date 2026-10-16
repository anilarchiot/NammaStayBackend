-- =====================================================================
-- NammaStay · 017_role_permissions.sql
-- The owner decides what Manager, Front desk and Accountant may do
-- (Settings → Users & roles → What each role can do). Enforced here in the
-- database, so a switched-off feature can't be used from any device.
-- The owner can always do everything. Fixed safety limits from earlier
-- migrations still apply (e.g. only owner/manager can refund or delete a
-- whole guest; the accountant can't change bookings).
-- Run AFTER 016_extras.sql.
-- =====================================================================

alter table public.properties add column if not exists role_permissions jsonb not null default '{}'::jsonb
  check (jsonb_typeof(role_permissions) = 'object');

-- Defaults when the owner hasn't changed anything
create or replace function public._perm_default(p_role public.member_role, p_perm text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select case p_role
    when 'owner'      then true
    when 'manager'    then true
    when 'front_desk' then p_perm in ('view_payments','record_payments','cancel_bookings','delete_bookings','add_extras')
    when 'accountant' then p_perm in ('view_reports','view_payments','export_data')
    else false end
$$;

create or replace function public._allowed(p_property uuid, p_perm text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_role public.member_role; v_set jsonb;
begin
  if auth.uid() is null then return true; end if;                -- SQL editor, scheduled jobs
  select role into v_role from public.property_members where property_id = p_property and user_id = auth.uid();
  if v_role is null then return false; end if;
  if v_role = 'owner' then return true; end if;
  select role_permissions -> (v_role::text) -> p_perm into v_set from public.properties where id = p_property;
  if v_set is not null and jsonb_typeof(v_set) = 'boolean' then return v_set::text::boolean; end if;
  return public._perm_default(v_role, p_perm);
end $$;

create or replace function public._require_perm(p_property uuid, p_perm text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public._allowed(p_property, p_perm) then
    raise exception '%', case p_perm
      when 'view_reports'    then 'Your role can’t see reports. Ask the owner.'
      when 'view_payments'   then 'Your role can’t see payments. Ask the owner.'
      when 'record_payments' then 'Your role can’t take payments. Ask the owner.'
      when 'refunds'         then 'Your role can’t give refunds. Ask the owner.'
      when 'cancel_bookings' then 'Your role can’t cancel bookings. Ask the owner.'
      when 'delete_bookings' then 'Your role can’t delete bookings. Ask the owner.'
      when 'delete_guests'   then 'Your role can’t delete guests. Ask the owner.'
      when 'manage_rooms'    then 'Your role can’t change rooms, beds or prices. Ask the owner.'
      when 'add_extras'      then 'Your role can’t add or remove extras. Ask the owner.'
      else 'Your role can’t do this. Ask the owner.' end
      using errcode = '42501';
  end if;
end $$;

-- ---------- enforcement ----------
create or replace function public._perm_payments() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_perm(new.property_id, case new.kind when 'refund' then 'refunds' else 'record_payments' end);
  return new;
end $$;
drop trigger if exists perm_payments on public.payments;
create trigger perm_payments before insert on public.payments for each row execute function public._perm_payments();

create or replace function public._perm_bookings() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then perform public._require_perm(old.property_id, 'delete_bookings'); return old; end if;
  if new.status = 'cancelled' and old.status <> 'cancelled' then perform public._require_perm(new.property_id, 'cancel_bookings'); end if;
  return new;
end $$;
drop trigger if exists perm_bookings on public.bookings;
create trigger perm_bookings before update of status or delete on public.bookings for each row execute function public._perm_bookings();

create or replace function public._perm_guests() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public._require_perm(old.property_id, 'delete_guests'); return old; end $$;
drop trigger if exists perm_guests on public.guests;
create trigger perm_guests before delete on public.guests for each row execute function public._perm_guests();

create or replace function public._perm_rooms() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_perm(coalesce(new.property_id, old.property_id), 'manage_rooms');
  return coalesce(new, old);
end $$;
drop trigger if exists perm_rooms on public.rooms;
drop trigger if exists perm_beds on public.beds;
drop trigger if exists perm_extra_items on public.extra_items;
create trigger perm_rooms before insert or update or delete on public.rooms for each row execute function public._perm_rooms();
create trigger perm_beds before insert or update or delete on public.beds for each row execute function public._perm_rooms();
create trigger perm_extra_items before insert or update or delete on public.extra_items for each row execute function public._perm_rooms();

create or replace function public._perm_charges() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._require_perm(coalesce(new.property_id, old.property_id), 'add_extras');
  return coalesce(new, old);
end $$;
drop trigger if exists perm_charges on public.booking_charges;
create trigger perm_charges before insert or delete on public.booking_charges for each row execute function public._perm_charges();

-- payments are only visible to roles allowed to see them (booking screens still show a booking's own payments)
drop policy if exists payments_select on public.payments;
create policy payments_select on public.payments for select to authenticated
  using (property_id in (select public.my_property_ids()) and public._allowed(property_id, 'view_payments'));

create or replace function public.report_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz text; t0 timestamptz; t1 timestamptz;
  v_days int; v_beds int; v_revenue bigint; v_bed_nights bigint;
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_reports');
  if p_to < p_from or p_to - p_from > 370 then raise exception 'Choose a range of up to one year.'; end if;
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_to + 1);
  v_days := p_to - p_from + 1;
  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0) into v_revenue
    from public.payments where property_id = p_property and received_at >= t0 and received_at < t1;
  select coalesce(sum(occupied), 0) into v_bed_nights from public.occupancy_series(p_property, p_from, p_to);

  return jsonb_build_object(
    'revenue', v_revenue,
    'days', v_days,
    'beds', v_beds,
    'occupancy', case when v_beds * v_days = 0 then 0 else round(v_bed_nights::numeric / (v_beds * v_days), 4) end,
    'revpab', case when v_beds * v_days = 0 then 0 else round(v_revenue::numeric / (v_beds * v_days)) end,
    'alos', (select coalesce(round(avg(nights), 1), 0) from public.bookings where property_id = p_property
              and check_in_at >= t0 and check_in_at < t1 and status in ('confirmed','checked_in','checked_out')),
    'weekly', (select coalesce(jsonb_agg(w order by w->>'start'), '[]'::jsonb) from (
                 select jsonb_build_object('start', ws::date,
                   'digital', coalesce(sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end)
                                        filter (where x.method <> 'cash'), 0),
                   'cash',    coalesce(sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end)
                                        filter (where x.method = 'cash'), 0)) w
                   from generate_series(p_from::timestamp, p_to::timestamp, interval '7 days') ws
                   left join public.payments x
                     on x.property_id = p_property
                    and x.received_at >= public._day_start(v_tz, ws::date)
                    and x.received_at <  least(public._day_start(v_tz, ws::date + 7), t1)
                  group by ws) q),
    'rooms', (select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'beds', rb.n,
                 'occupancy', case when rb.n * v_days = 0 then 0 else round(rn.nights::numeric / (rb.n * v_days), 4) end,
                 'revenue', coalesce(rv.amt, 0)) order by r.sort, r.name), '[]'::jsonb)
               from public.rooms r
               cross join lateral (select count(*) n from public.beds where room_id = r.id and is_active) rb
               cross join lateral (select count(*) nights
                                     from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
                                     join public.bookings b on b.stay @> public._night(v_tz, d::date)
                                     join public.beds bd on bd.id = b.bed_id
                                    where bd.room_id = r.id and b.property_id = p_property
                                      and b.status in ('pending','confirmed','checked_in','checked_out')) rn
               cross join lateral (select sum(case x.kind when 'payment' then x.amount_paise else -x.amount_paise end) amt
                                     from public.payments x join public.bookings b on b.id = x.booking_id
                                     join public.beds bd on bd.id = b.bed_id
                                    where bd.room_id = r.id and x.property_id = p_property
                                      and x.received_at >= t0 and x.received_at < t1) rv
              where r.property_id = p_property),
    'sources', (select coalesce(jsonb_object_agg(source, n), '{}'::jsonb) from (
                  select source, count(*) n from public.bookings where property_id = p_property
                     and check_in_at >= t0 and check_in_at < t1 and status not in ('cancelled') group by source) s),
    'nationalities', (select coalesce(jsonb_agg(jsonb_build_object('name', nat, 'n', n) order by n desc), '[]'::jsonb) from (
                  select coalesce(nullif(g.nationality, ''), 'Unknown') nat, count(*) n
                    from public.bookings b join public.guests g on g.id = b.guest_id
                   where b.property_id = p_property and b.check_in_at >= t0 and b.check_in_at < t1
                     and b.status not in ('cancelled')
                   group by 1 order by 2 desc limit 6) q));
end $$;

create or replace function public.list_payments(
  p_property uuid, p_method text default null, p_from date default null, p_to date default null,
  p_cursor_at timestamptz default null, p_cursor_id uuid default null, p_limit int default 30)
returns table (id uuid, code text, booking_id uuid, booking_code text, guest_name text,
               kind public.payment_kind, method public.payment_method, amount_paise int,
               reference text, received_at timestamptz, booking_balance_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_tz text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_payments');
  v_tz := public._tz(p_property);
  return query
  select x.id, x.code, b.id, b.code, g.full_name, x.kind, x.method, x.amount_paise,
         x.reference, x.received_at, b.balance_paise
    from public.payments x
    join public.bookings b on b.id = x.booking_id
    join public.guests   g on g.id = b.guest_id
   where x.property_id = p_property
     and (p_method is null or x.method = p_method::public.payment_method)
     and (p_from is null or x.received_at >= public._day_start(v_tz, p_from))
     and (p_to   is null or x.received_at <  public._day_start(v_tz, p_to + 1))
     and (p_cursor_at is null or (x.received_at, x.id) < (p_cursor_at, p_cursor_id))
   order by x.received_at desc, x.id desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

create or replace function public.payment_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; t0 timestamptz; t1 timestamptz; pt0 timestamptz; v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_payments');
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_to + 1);
  pt0 := t0 - (t1 - t0);
  select jsonb_build_object(
    'revenue', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end)
                        filter (where received_at >= t0), 0),
    'previous', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end)
                        filter (where received_at < t0), 0),
    'upi',  coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'upi'  and received_at >= t0), 0),
    'cash', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'cash' and received_at >= t0), 0),
    'card', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'card' and received_at >= t0), 0),
    'bank', coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end) filter (where method = 'bank' and received_at >= t0), 0))
    into v
    from public.payments
   where property_id = p_property and received_at >= pt0 and received_at < t1;
  return v || jsonb_build_object(
    'dues_paise', (select coalesce(sum(balance_paise), 0) from public.bookings where property_id = p_property
                    and balance_paise > 0 and status in ('checked_in','checked_out')),
    'dues_count', (select count(*) from public.bookings where property_id = p_property
                    and balance_paise > 0 and status in ('checked_in','checked_out')));
end $$;

-- ---------- owner edits the permissions ----------
-- p: { "manager": { "refunds": false, … }, "front_desk": { … }, "accountant": { … } }
create or replace function public.set_role_permissions(p_property uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb := '{}'::jsonb; r text; k text;
  v_perms text[] := array['view_reports','view_payments','record_payments','refunds','cancel_bookings','delete_bookings',
                          'delete_guests','manage_rooms','add_extras','export_data'];
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  foreach r in array array['manager','front_desk','accountant'] loop
    if p ? r and jsonb_typeof(p->r) = 'object' then
      v := v || jsonb_build_object(r, (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
                                        from jsonb_each(p->r) where key = any (v_perms) and jsonb_typeof(value) = 'boolean'));
    end if;
  end loop;
  update public.properties set role_permissions = v where id = p_property;
  return v;
end $$;

revoke execute on function public._perm_default(public.member_role, text), public._allowed(uuid, text), public._require_perm(uuid, text),
  public._perm_payments(), public._perm_bookings(), public._perm_guests(), public._perm_rooms(), public._perm_charges(),
  public.set_role_permissions(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.set_role_permissions(uuid, jsonb), public._allowed(uuid, text) to authenticated;
