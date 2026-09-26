-- =====================================================================
-- NammaStay · 003_functions.sql
-- Every query the app runs. The browser calls these with supabase.rpc().
-- Each function checks the caller's role first, validates input, and only
-- returns one page of rows at a time, so screens stay fast at lakhs of rows.
-- =====================================================================

-- ---------- Small helpers ----------
create or replace function public._tz(p_property uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select timezone from public.properties where id = p_property
$$;

create or replace function public._local_date(p_property uuid, p_ts timestamptz) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select (p_ts at time zone public._tz(p_property))::date
$$;

-- A bed counts as occupied on a night if a stay covers 8 PM local time that day.
create or replace function public._night(p_tz text, p_day date) returns timestamptz
language sql stable set search_path = public, pg_temp as $$
  select (p_day + time '20:00') at time zone p_tz
$$;

create or replace function public._day_start(p_tz text, p_day date) returns timestamptz
language sql stable set search_path = public, pg_temp as $$
  select p_day::timestamp at time zone p_tz
$$;

-- "98400 12233" → "+919840012233"; keeps an explicit country code if given.
create or replace function public._clean_phone(p text) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare d text;
begin
  if p is null or btrim(p) = '' then return null; end if;
  d := regexp_replace(p, '[^0-9]', '', 'g');
  if btrim(p) like '+%' then return '+' || d; end if;
  if length(d) = 10 then return '+91' || d; end if;
  if length(d) = 12 and d like '91%' then return '+' || d; end if;
  return d;
end $$;

-- Aadhaar is never stored in full: only the last 4 digits are kept.
create or replace function public._mask_id(p_type text, p_num text) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare d text;
begin
  if p_num is null or btrim(p_num) = '' then return null; end if;
  if p_type = 'aadhaar' then
    d := regexp_replace(p_num, '[^0-9]', '', 'g');
    if length(d) = 12 or length(d) = 4 then
      return 'XXXX XXXX ' || right(d, 4);
    end if;
    raise exception 'Aadhaar number must have 12 digits.';
  end if;
  return upper(regexp_replace(btrim(p_num), '\s+', ' ', 'g'));
end $$;

create or replace function public._check_dob(p_dob date) returns void
language plpgsql stable set search_path = public, pg_temp as $$
begin
  if p_dob is null then return; end if;
  if p_dob > current_date then raise exception 'Date of birth can''t be in the future.'; end if;
  if p_dob < current_date - interval '120 years' then raise exception 'Please check the date of birth.'; end if;
end $$;

-- ---------- Session ----------
create or replace function public.my_memberships()
returns table (property_id uuid, property_name text, role public.member_role, display_name text)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.property_id, p.name, m.role, m.display_name
    from public.property_members m join public.properties p on p.id = m.property_id
   where m.user_id = auth.uid()
   order by p.name
$$;

create or replace function public.touch_presence(p_property uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.property_members set last_seen_at = now()
   where property_id = p_property and user_id = auth.uid()
     and (last_seen_at is null or last_seen_at < now() - interval '5 minutes')
$$;

-- =====================================================================
-- Bookings
-- =====================================================================

create or replace function public.create_booking(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_prop   uuid := (p->>'property_id')::uuid;
  v_in     timestamptz := (p->>'check_in_at')::timestamptz;
  v_out    timestamptz := (p->>'check_out_at')::timestamptz;
  v_status public.booking_status := coalesce(nullif(p->>'status', ''), 'pending')::public.booking_status;
  v_guest  uuid := nullif(p->>'guest_id', '')::uuid;
  v_bed    public.beds%rowtype;
  v_nights int;
  v_b      public.bookings%rowtype;
  v_pay    jsonb := p->'payment';
  v_dob    date := nullif(p#>>'{guest,dob}', '')::date;
begin
  perform public._assert_role(v_prop, array['owner','manager','front_desk']::public.member_role[]);

  if v_in is null or v_out is null then raise exception 'Check-in and check-out are required.'; end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;
  if v_in < now() - interval '2 days' then raise exception 'Check-in can''t be more than 2 days in the past.'; end if;
  if v_in > now() + interval '2 years' then raise exception 'Check-in is too far in the future.'; end if;
  if v_status not in ('pending','confirmed','checked_in') then raise exception 'A new booking must be pending, confirmed or checked in.'; end if;
  if v_status = 'checked_in' and public._local_date(v_prop, v_in) > public._local_date(v_prop, now()) then
    raise exception 'You can only check in a guest whose stay starts today.';
  end if;

  select * into v_bed from public.beds where id = (p->>'bed_id')::uuid and property_id = v_prop;
  if not found then raise exception 'Please choose a bed.'; end if;
  if not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  if v_guest is null then
    if coalesce(btrim(p#>>'{guest,full_name}'), '') = '' then raise exception 'Guest name is required.'; end if;
    perform public._check_dob(v_dob);
    insert into public.guests (property_id, full_name, phone, email, dob, nationality, id_type, id_number, id_doc_path, consent_at)
    values (v_prop,
            btrim(p#>>'{guest,full_name}'),
            public._clean_phone(p#>>'{guest,phone}'),
            nullif(lower(btrim(p#>>'{guest,email}')), ''),
            v_dob,
            nullif(btrim(p#>>'{guest,nationality}'), ''),
            nullif(p#>>'{guest,id_type}', '')::public.id_doc_type,
            public._mask_id(nullif(p#>>'{guest,id_type}', ''), p#>>'{guest,id_number}'),
            nullif(p#>>'{guest,id_doc_path}', ''),
            now())
    returning id into v_guest;
  elsif not exists (select 1 from public.guests where id = v_guest and property_id = v_prop) then
    raise exception 'Guest not found.';
  end if;

  v_nights := greatest(1, public._local_date(v_prop, v_out) - public._local_date(v_prop, v_in));

  begin
    insert into public.bookings (property_id, guest_id, bed_id, visitors, check_in_at, check_out_at,
                                 nights, rate_paise, total_paise, status, source, note,
                                 send_confirmation, arrived_at)
    values (v_prop, v_guest, v_bed.id,
            coalesce(nullif(p->>'visitors', '')::smallint, 1),
            v_in, v_out, v_nights, v_bed.rate_paise, v_nights * v_bed.rate_paise,
            v_status,
            coalesce(nullif(p->>'source', ''), 'walk_in')::public.booking_source,
            nullif(btrim(p->>'note'), ''),
            coalesce((p->>'send_confirmation')::boolean, false),
            case when v_status = 'checked_in' then now() end)
    returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  if v_pay is not null and coalesce((v_pay->>'amount_paise')::int, 0) > 0 then
    perform public.record_payment(v_b.id, (v_pay->>'amount_paise')::int, v_pay->>'method',
                                  v_pay->>'reference', 'payment', null);
  end if;

  return jsonb_build_object('id', v_b.id, 'code', v_b.code, 'nights', v_nights,
                            'total_paise', v_b.total_paise,
                            'self_checkin_token', v_b.self_checkin_token);
end $$;

create or replace function public.update_booking(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_bed  public.beds%rowtype;
  v_in   timestamptz;
  v_out  timestamptz;
  v_rate int;
  v_nights int;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if v_b.status not in ('pending','confirmed','checked_in') then
    raise exception 'This booking is % and can''t be changed.', replace(v_b.status::text, '_', ' ');
  end if;

  v_in  := coalesce((p->>'check_in_at')::timestamptz,  v_b.check_in_at);
  v_out := coalesce((p->>'check_out_at')::timestamptz, v_b.check_out_at);
  if v_b.status = 'checked_in' and v_in <> v_b.check_in_at then
    raise exception 'Guest is already checked in; only the check-out can change.';
  end if;
  if v_out <= v_in then raise exception 'Check-out must be after check-in.'; end if;

  select * into v_bed from public.beds
   where id = coalesce(nullif(p->>'bed_id', '')::uuid, v_b.bed_id) and property_id = v_b.property_id;
  if not found then raise exception 'Bed not found.'; end if;
  if v_bed.id <> v_b.bed_id and not v_bed.is_active then raise exception '% is not in use.', v_bed.label; end if;
  if exists (select 1 from public.bed_blocks
              where bed_id = v_bed.id and period && tstzrange(v_in, v_out, '[)')) then
    raise exception '% is blocked for maintenance on those dates.', v_bed.label;
  end if;

  v_rate   := case when v_bed.id = v_b.bed_id then v_b.rate_paise else v_bed.rate_paise end;
  v_nights := greatest(1, public._local_date(v_b.property_id, v_out) - public._local_date(v_b.property_id, v_in));
  if v_nights * v_rate < v_b.paid_paise then
    raise exception 'New total is less than what''s already paid. Record a refund first.';
  end if;

  begin
    update public.bookings
       set check_in_at = v_in, check_out_at = v_out, bed_id = v_bed.id,
           rate_paise = v_rate, nights = v_nights, total_paise = v_nights * v_rate,
           visitors = coalesce(nullif(p->>'visitors', '')::smallint, visitors),
           note = case when p ? 'note' then nullif(btrim(p->>'note'), '') else note end
     where id = p_booking
     returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  return jsonb_build_object('id', v_b.id, 'total_paise', v_b.total_paise, 'nights', v_b.nights);
end $$;

-- confirm | check_in | check_out | cancel | no_show
create or replace function public.booking_action(p_booking uuid, p_action text, p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b public.bookings%rowtype;
  v_today date;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  v_today := public._local_date(v_b.property_id, now());

  if p_action = 'confirm' then
    if v_b.status <> 'pending' then raise exception 'Only pending bookings can be confirmed.'; end if;
    update public.bookings set status = 'confirmed' where id = p_booking;

  elsif p_action = 'check_in' then
    if v_b.status not in ('pending','confirmed') then raise exception 'This booking can''t be checked in.'; end if;
    if public._local_date(v_b.property_id, v_b.check_in_at) > v_today then
      raise exception 'Check-in is on %. Change the dates to check in early.',
        to_char(v_b.check_in_at at time zone public._tz(v_b.property_id), 'DD Mon');
    end if;
    if v_b.check_out_at <= now() then raise exception 'This stay has already ended.'; end if;
    update public.bookings set status = 'checked_in', arrived_at = now() where id = p_booking;

  elsif p_action = 'check_out' then
    if v_b.status <> 'checked_in' then raise exception 'Only checked-in guests can be checked out.'; end if;
    if v_b.balance_paise > 0 and not p_force then
      raise exception 'Balance of ₹% is still due. Record the payment first.',
        to_char(v_b.balance_paise / 100.0, 'FM99,99,99,990.00');
    end if;
    update public.bookings
       set status = 'checked_out', departed_at = now(),
           check_out_at = least(check_out_at, now())   -- early departure frees the bed
     where id = p_booking;

  elsif p_action = 'cancel' then
    if v_b.status not in ('pending','confirmed') then raise exception 'Only pending or confirmed bookings can be cancelled.'; end if;
    update public.bookings set status = 'cancelled', cancelled_at = now() where id = p_booking;

  elsif p_action = 'no_show' then
    if v_b.status not in ('pending','confirmed') then raise exception 'Only pending or confirmed bookings can be marked no-show.'; end if;
    if public._local_date(v_b.property_id, v_b.check_in_at) > v_today then
      raise exception 'The guest isn''t due yet.';
    end if;
    update public.bookings set status = 'no_show' where id = p_booking;

  else
    raise exception 'Unknown action.';
  end if;

  return jsonb_build_object('id', p_booking, 'action', p_action);
end $$;

-- Payments are append-only. A refund is a separate negative entry.
create or replace function public.record_payment(
  p_booking uuid, p_amount_paise int, p_method text, p_reference text default null,
  p_kind text default 'payment', p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_ref  text := nullif(upper(regexp_replace(coalesce(p_reference, ''), '\s', '', 'g')), '');
  v_pay  public.payments%rowtype;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;

  if p_kind = 'refund' then
    perform public._assert_role(v_b.property_id, array['owner','manager']::public.member_role[]);
  else
    perform public._assert_role(v_b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  end if;

  if p_amount_paise is null or p_amount_paise <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if p_method not in ('upi','cash','card','bank') then raise exception 'Choose a payment method.'; end if;

  if p_kind = 'payment' then
    if v_b.status in ('cancelled','no_show') then raise exception 'Can''t take payment on a % booking.', v_b.status; end if;
    if p_amount_paise > v_b.balance_paise then
      raise exception 'Amount is more than the balance due (₹%).', to_char(v_b.balance_paise / 100.0, 'FM99,99,99,990.00');
    end if;
    if p_method = 'upi' and (v_ref is null or v_ref !~ '^[0-9A-Z]{6,35}$') then
      raise exception 'Enter the UPI transaction ID (UTR) from the guest''s payment screen.';
    end if;
  elsif p_kind = 'refund' then
    if p_amount_paise > v_b.paid_paise then raise exception 'Refund is more than the amount paid.'; end if;
  else
    raise exception 'Unknown payment type.';
  end if;

  begin
    insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, note)
    values (v_b.property_id, v_b.id, p_kind::public.payment_kind, p_method::public.payment_method,
            p_amount_paise, v_ref, nullif(btrim(p_note), ''))
    returning * into v_pay;
  exception when unique_violation then
    raise exception 'UPI transaction % was already recorded.', v_ref using errcode = '23505';
  end;

  return jsonb_build_object('id', v_pay.id, 'code', v_pay.code);
end $$;

-- ---------- Booking lists (keyset pagination: fast on page 1 and page 5,000) ----------
create or replace function public.list_bookings(
  p_property uuid, p_status text default null, p_q text default null,
  p_cursor_check_in timestamptz default null, p_cursor_id uuid default null, p_limit int default 30)
returns table (id uuid, code text, guest_id uuid, guest_name text, guest_phone text,
               room_name text, bed_label text, check_in_at timestamptz, check_out_at timestamptz,
               total_paise int, paid_paise int, balance_paise int,
               status public.booking_status, source public.booking_source)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  v_role   public.member_role;
  v_q      text := nullif(btrim(p_q), '');
  v_digits text;
  v_like   text;
begin
  v_role   := public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  v_like   := '%' || replace(replace(coalesce(v_q, ''), '%', ''), '_', '') || '%';

  return query
  select b.id, b.code, b.guest_id, g.full_name,
         case when v_role = 'accountant' then null else g.phone end,
         r.name, bd.label, b.check_in_at, b.check_out_at,
         b.total_paise, b.paid_paise, b.balance_paise, b.status, b.source
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    join public.beds  bd on bd.id = b.bed_id
    join public.rooms r  on r.id = bd.room_id
   where b.property_id = p_property
     and (p_status is null or b.status = p_status::public.booking_status)
     and (v_q is not null or b.check_out_at >= now() - interval '30 days')
     and (v_q is null
          or upper(b.code) = upper(v_q)
          or (v_digits <> '' and b.code = 'BK-' || v_digits)
          or g.full_name ilike v_like
          or (length(v_digits) >= 4 and g.phone like '%' || v_digits || '%'))
     and (p_cursor_check_in is null or (b.check_in_at, b.id) < (p_cursor_check_in, p_cursor_id))
   order by b.check_in_at desc, b.id desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

create or replace function public.booking_status_counts(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status, count(*) n from public.bookings
           where property_id = p_property and check_out_at >= now() - interval '30 days'
           group by status) s;
  return v || jsonb_build_object('all', (select coalesce(sum(value::int), 0) from jsonb_each_text(v)));
end $$;

create or replace function public.occupancy_series(p_property uuid, p_from date, p_to date)
returns table (day date, occupied int, total int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_tz text; v_total int;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if p_to < p_from or p_to - p_from > 400 then raise exception 'Choose a range of up to 400 days.'; end if;
  v_tz := public._tz(p_property);
  select count(*) into v_total from public.beds where property_id = p_property and is_active;
  return query
  select d::date,
         (select count(*) from public.bookings b
           where b.property_id = p_property
             and b.status in ('pending','confirmed','checked_in','checked_out')
             and b.stay @> public._night(v_tz, d::date))::int,
         v_total
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d;
end $$;

create or replace function public.booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_b    public.bookings%rowtype;
  v_role public.member_role;
  v      jsonb;
begin
  select * into v_b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  v_role := public._assert_role(v_b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);

  select jsonb_build_object(
    'booking', to_jsonb(v_b) - 'self_checkin_token'
               || case when v_role <> 'accountant'
                       then jsonb_build_object('self_checkin_token', v_b.self_checkin_token) else '{}'::jsonb end,
    'guest', case when v_role = 'accountant'
                  then jsonb_build_object('id', g.id, 'full_name', g.full_name)
                  else jsonb_build_object('id', g.id, 'full_name', g.full_name, 'phone', g.phone,
                         'email', g.email, 'nationality', g.nationality, 'id_type', g.id_type,
                         'id_number', g.id_number, 'id_doc_path', g.id_doc_path, 'dob', g.dob) end,
    'bed',  jsonb_build_object('id', bd.id, 'label', bd.label, 'room', r.name),
    'property', jsonb_build_object('id', p.id, 'name', p.name, 'upi_id', p.upi_id, 'timezone', p.timezone),
    'created_by', (select coalesce(m.display_name, m.email) from public.property_members m
                    where m.property_id = v_b.property_id and m.user_id = v_b.created_by),
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
                    'code', x.code, 'kind', x.kind, 'method', x.method, 'amount_paise', x.amount_paise,
                    'reference', x.reference, 'received_at', x.received_at) order by x.received_at)
                  from public.payments x where x.booking_id = v_b.id), '[]'::jsonb),
    'activity', case when v_role = 'accountant' then '[]'::jsonb else
                coalesce((select jsonb_agg(jsonb_build_object(
                    'action', a.action, 'details', a.details, 'at', a.at,
                    'by', (select coalesce(m.display_name, m.email) from public.property_members m
                            where m.property_id = a.property_id and m.user_id = a.actor)) order by a.at)
                  from public.audit_log a where a.booking_id = v_b.id), '[]'::jsonb) end)
  into v
  from public.guests g, public.beds bd, public.rooms r, public.properties p
  where g.id = v_b.guest_id and bd.id = v_b.bed_id and r.id = bd.room_id and p.id = v_b.property_id;
  return v;
end $$;

-- ---------- Dashboard ----------
create or replace function public.dashboard_summary(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz    text;
  v_today date;
  t0 timestamptz; t1 timestamptz; y0 timestamptz;
  v_beds int; v_occ int; v_occ_y int;
  v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz    := public._tz(p_property);
  v_today := (now() at time zone v_tz)::date;
  t0 := public._day_start(v_tz, v_today);
  t1 := t0 + interval '1 day';
  y0 := t0 - interval '1 day';

  select count(*) into v_beds from public.beds where property_id = p_property and is_active;
  select count(*) into v_occ from public.bookings
   where property_id = p_property and status in ('pending','confirmed','checked_in')
     and stay @> public._night(v_tz, v_today);
  select count(*) into v_occ_y from public.bookings
   where property_id = p_property and status in ('pending','confirmed','checked_in','checked_out')
     and stay @> public._night(v_tz, v_today - 1);

  select jsonb_build_object(
    'today', v_today,
    'beds_total', v_beds,
    'beds_occupied', v_occ,
    'beds_occupied_yesterday', v_occ_y,
    'checkins_today', (select count(*) from public.bookings where property_id = p_property
                        and check_in_at >= t0 and check_in_at < t1 and status in ('pending','confirmed','checked_in')),
    'checkins_pending', (select count(*) from public.bookings where property_id = p_property
                        and check_in_at >= t0 and check_in_at < t1 and status in ('pending','confirmed')),
    'checkouts_today', (select count(*) from public.bookings where property_id = p_property
                        and check_out_at >= t0 and check_out_at < t1 and status in ('checked_in','checked_out')),
    'checkouts_late', (select count(*) from public.bookings where property_id = p_property
                        and status = 'checked_in' and check_out_at < now()),
    'revenue_today', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                        from public.payments where property_id = p_property and received_at >= t0 and received_at < t1),
    'revenue_yesterday', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                        from public.payments where property_id = p_property and received_at >= y0 and received_at < t0),
    'dues_paise', (select coalesce(sum(balance_paise), 0) from public.bookings where property_id = p_property
                        and balance_paise > 0 and status in ('checked_in','checked_out')),
    'dues_count', (select count(*) from public.bookings where property_id = p_property
                        and balance_paise > 0 and status in ('checked_in','checked_out')),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('day', s.day, 'occupied', s.occupied) order by s.day), '[]'::jsonb)
                 from public.occupancy_series(p_property, v_today - 6, v_today) s),
    'arriving', (select coalesce(jsonb_agg(x order by x->>'check_in_at'), '[]'::jsonb) from (
                   select jsonb_build_object('id', b.id, 'guest', g.full_name, 'room', r.name, 'bed', bd.label,
                          'check_in_at', b.check_in_at, 'status', b.status) x
                     from public.bookings b join public.guests g on g.id = b.guest_id
                     join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                    where b.property_id = p_property and b.check_in_at >= t0 and b.check_in_at < t1
                      and b.status in ('pending','confirmed','checked_in')
                    order by b.check_in_at limit 8) q),
    'departing', (select coalesce(jsonb_agg(x order by x->>'check_out_at'), '[]'::jsonb) from (
                   select jsonb_build_object('id', b.id, 'guest', g.full_name, 'room', r.name, 'bed', bd.label,
                          'check_out_at', b.check_out_at, 'status', b.status,
                          'overdue', b.status = 'checked_in' and b.check_out_at < now()) x
                     from public.bookings b join public.guests g on g.id = b.guest_id
                     join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                    where b.property_id = p_property
                      and ((b.check_out_at >= t0 and b.check_out_at < t1 and b.status in ('checked_in','checked_out'))
                           or (b.status = 'checked_in' and b.check_out_at < t0))
                    order by b.check_out_at limit 8) q)
  ) into v;
  return v;
end $$;

-- ---------- Rooms board & calendar ----------
create or replace function public.bed_board(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; t0 timestamptz; t1 timestamptz; v jsonb;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, (now() at time zone v_tz)::date);
  t1 := t0 + interval '1 day';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'name', r.name, 'description', r.description,
           'beds', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', bd.id, 'label', bd.label, 'position', bd.position,
                      'rate_paise', bd.rate_paise, 'is_active', bd.is_active,
                      'block', (select k.reason from public.bed_blocks k
                                 where k.bed_id = bd.id and k.period @> now() limit 1),
                      'booking', (select jsonb_build_object('id', b.id, 'guest', g.full_name, 'status', b.status,
                                          'check_out_at', b.check_out_at)
                                    from public.bookings b join public.guests g on g.id = b.guest_id
                                   where b.bed_id = bd.id and b.status in ('pending','confirmed','checked_in')
                                     and b.stay && tstzrange(t0, t1, '[)')
                                   order by (b.status = 'checked_in') desc, b.check_in_at limit 1)
                    ) order by bd.sort, bd.label), '[]'::jsonb)
                    from public.beds bd where bd.room_id = r.id)
         ) order by r.sort, r.name), '[]'::jsonb)
    into v
    from public.rooms r where r.property_id = p_property;
  return v;
end $$;

create or replace function public.calendar_range(p_property uuid, p_from date, p_days int default 9) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_tz text; t0 timestamptz; t1 timestamptz;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if p_days < 1 or p_days > 62 then raise exception 'Choose between 1 and 62 days.'; end if;
  v_tz := public._tz(p_property);
  t0 := public._day_start(v_tz, p_from);
  t1 := public._day_start(v_tz, p_from + p_days);
  return jsonb_build_object(
    'beds', (select coalesce(jsonb_agg(jsonb_build_object('id', bd.id, 'label', bd.label, 'room', r.name,
                     'room_id', r.id) order by r.sort, r.name, bd.sort, bd.label), '[]'::jsonb)
               from public.beds bd join public.rooms r on r.id = bd.room_id
              where bd.property_id = p_property and bd.is_active),
    'bookings', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'bed_id', b.bed_id, 'guest', g.full_name,
                     'status', b.status, 'balance_paise', b.balance_paise, 'paid_paise', b.paid_paise,
                     'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at)), '[]'::jsonb)
               from public.bookings b join public.guests g on g.id = b.guest_id
              where b.property_id = p_property and b.stay && tstzrange(t0, t1, '[)')
                and b.status in ('pending','confirmed','checked_in','checked_out')),
    'blocks', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'bed_id', k.bed_id, 'reason', k.reason,
                     'starts_at', k.starts_at, 'ends_at', k.ends_at)), '[]'::jsonb)
               from public.bed_blocks k
              where k.property_id = p_property and k.period && tstzrange(t0, t1, '[)')));
end $$;

create or replace function public.available_beds(p_property uuid, p_in timestamptz, p_out timestamptz)
returns table (id uuid, label text, room_id uuid, room_name text, rate_paise int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  return query
  select bd.id, bd.label, r.id, r.name, bd.rate_paise
    from public.beds bd join public.rooms r on r.id = bd.room_id
   where bd.property_id = p_property and bd.is_active
     and not exists (select 1 from public.bookings b where b.bed_id = bd.id
                      and b.status in ('pending','confirmed','checked_in')
                      and b.stay && tstzrange(p_in, p_out, '[)'))
     and not exists (select 1 from public.bed_blocks k where k.bed_id = bd.id
                      and k.period && tstzrange(p_in, p_out, '[)'))
   order by r.sort, r.name, bd.sort, bd.label;
end $$;

create or replace function public.set_bed_block(p_bed uuid, p_from timestamptz, p_to timestamptz, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bed public.beds%rowtype; v_id uuid;
begin
  select * into v_bed from public.beds where id = p_bed;
  if not found then raise exception 'Bed not found.'; end if;
  perform public._assert_role(v_bed.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if exists (select 1 from public.bookings b where b.bed_id = p_bed
              and b.status in ('pending','confirmed','checked_in') and b.stay && tstzrange(p_from, p_to, '[)')) then
    raise exception '% has bookings in that period. Move them first.', v_bed.label;
  end if;
  begin
    insert into public.bed_blocks (property_id, bed_id, starts_at, ends_at, reason)
    values (v_bed.property_id, p_bed, p_from, p_to, p_reason) returning id into v_id;
  exception when exclusion_violation then
    raise exception '% is already blocked for part of that period.', v_bed.label;
  end;
  return v_id;
end $$;

-- ---------- Payments ----------
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

-- ---------- Guests ----------
create or replace function public.guest_profile(p_guest uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_g public.guests%rowtype;
begin
  select * into v_g from public.guests where id = p_guest;
  if not found then raise exception 'Guest not found.'; end if;
  perform public._assert_role(v_g.property_id, array['owner','manager','front_desk']::public.member_role[]);
  return jsonb_build_object(
    'guest', to_jsonb(v_g),
    'visits', (select count(*) from public.bookings where guest_id = p_guest and status in ('confirmed','checked_in','checked_out')),
    'spend_paise', (select coalesce(sum(paid_paise), 0) from public.bookings where guest_id = p_guest),
    'last_stay', (select jsonb_build_object('check_in_at', check_in_at, 'check_out_at', check_out_at)
                    from public.bookings where guest_id = p_guest and status in ('checked_in','checked_out')
                   order by check_in_at desc limit 1),
    'current', (select jsonb_build_object('id', b.id, 'room', r.name, 'bed', bd.label, 'check_out_at', b.check_out_at)
                  from public.bookings b join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                 where b.guest_id = p_guest and b.status = 'checked_in' limit 1),
    'stays', (select coalesce(jsonb_agg(s order by s->>'check_in_at' desc), '[]'::jsonb) from (
                select jsonb_build_object('id', b.id, 'code', b.code, 'room', r.name, 'bed', bd.label,
                       'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at,
                       'paid_paise', b.paid_paise, 'status', b.status) s
                  from public.bookings b join public.beds bd on bd.id = b.bed_id join public.rooms r on r.id = bd.room_id
                 where b.guest_id = p_guest order by b.check_in_at desc limit 50) q));
end $$;

create or replace function public.search_guests(p_property uuid, p_q text)
returns table (id uuid, full_name text, phone text, email text, nationality text, last_check_in timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_q text := btrim(coalesce(p_q, '')); v_digits text;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk']::public.member_role[]);
  v_digits := regexp_replace(v_q, '[^0-9]', '', 'g');
  if length(v_q) < 3 then return; end if;
  return query
  select g.id, g.full_name, g.phone, g.email, g.nationality,
         (select max(b.check_in_at) from public.bookings b where b.guest_id = g.id)
    from public.guests g
   where g.property_id = p_property
     and ((length(v_digits) >= 6 and g.phone like '%' || v_digits || '%')
          or g.full_name ilike '%' || replace(replace(v_q, '%', ''), '_', '') || '%')
   order by g.created_at desc
   limit 8;
end $$;

-- ---------- Reports ----------
create or replace function public.report_summary(p_property uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz text; t0 timestamptz; t1 timestamptz;
  v_days int; v_beds int; v_revenue bigint; v_bed_nights bigint;
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
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

-- ---------- Team ----------
create or replace function public.list_members(p_property uuid)
returns table (user_id uuid, display_name text, email text, role public.member_role, last_seen_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return query select m.user_id, m.display_name, m.email, m.role, m.last_seen_at
                 from public.property_members m where m.property_id = p_property
                order by m.role, m.display_name;
end $$;

-- Add someone who already has a login (invite them first: Supabase → Authentication → Users → Invite).
create or replace function public.add_member(p_property uuid, p_email text, p_role text, p_name text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid;
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  select id into v_user from auth.users where lower(email) = lower(btrim(p_email));
  if v_user is null then
    raise exception 'No login exists for %. Invite them from Supabase → Authentication → Users first.', p_email;
  end if;
  insert into public.property_members (property_id, user_id, role, display_name, email)
  values (p_property, v_user, p_role::public.member_role, nullif(btrim(p_name), ''), lower(btrim(p_email)))
  on conflict (property_id, user_id)
  do update set role = excluded.role, display_name = coalesce(excluded.display_name, property_members.display_name);
end $$;

create or replace function public.remove_member(p_property uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if (select role from public.property_members where property_id = p_property and user_id = p_user) = 'owner'
     and (select count(*) from public.property_members where property_id = p_property and role = 'owner') <= 1 then
    raise exception 'A property needs at least one owner.';
  end if;
  delete from public.property_members where property_id = p_property and user_id = p_user;
end $$;

-- ---------- Notifications ----------
create or replace function public.mark_notifications_read(p_property uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.notifications set read_at = now()
   where property_id = p_property and read_at is null
     and (user_id is null or user_id = auth.uid())
     and property_id in (select public.my_property_ids())
$$;

-- =====================================================================
-- Guest self check-in (no login; the link contains an unguessable token)
-- =====================================================================
create or replace function public.selfcheckin_get(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  select jsonb_build_object(
           'property_id', p.id, 'property', p.name, 'code', b.code, 'status', b.status,
           'room', r.name, 'bed', bd.label, 'nights', b.nights,
           'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at,
           'full_name', g.full_name, 'submitted', b.self_checkin_at is not null)
    into v
    from public.bookings b
    join public.guests g on g.id = b.guest_id
    join public.beds bd on bd.id = b.bed_id
    join public.rooms r on r.id = bd.room_id
    join public.properties p on p.id = b.property_id
   where b.self_checkin_token = p_token
     and b.status in ('pending','confirmed','checked_in')
     and b.check_out_at > now();
  if v is null then raise exception 'This check-in link is invalid or has expired. Please ask the front desk.'; end if;
  return v;
end $$;

create or replace function public.selfcheckin_submit(p_token uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_b   public.bookings%rowtype;
  v_dob date := nullif(p->>'dob', '')::date;
  v_doc text := nullif(p->>'id_doc_path', '');
begin
  select * into v_b from public.bookings
   where self_checkin_token = p_token and status in ('pending','confirmed','checked_in') and check_out_at > now()
   for update;
  if not found then raise exception 'This check-in link is invalid or has expired. Please ask the front desk.'; end if;
  if v_b.self_checkin_count >= 5 then raise exception 'Too many attempts. Please finish check-in at the front desk.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then
    raise exception 'Please confirm your details and accept the house rules.';
  end if;
  if coalesce(btrim(p->>'full_name'), '') = '' then raise exception 'Full name is required.'; end if;
  if v_dob is null then raise exception 'Date of birth is required.'; end if;
  perform public._check_dob(v_dob);
  if v_dob > current_date - interval '18 years' then
    raise exception 'Guests must be 18 or older to check in.';
  end if;
  if coalesce(p->>'id_type', '') = '' then raise exception 'Choose a proof of identity.'; end if;
  if v_doc is not null and v_doc not like v_b.property_id::text || '/' || p_token::text || '/%' then
    raise exception 'ID upload is invalid. Please try again.';
  end if;

  update public.guests
     set full_name   = btrim(p->>'full_name'),
         dob         = v_dob,
         phone       = coalesce(public._clean_phone(p->>'phone'), phone),
         email       = coalesce(nullif(lower(btrim(p->>'email')), ''), email),
         nationality = coalesce(nullif(btrim(p->>'nationality'), ''), nationality),
         id_type     = (p->>'id_type')::public.id_doc_type,
         id_number   = coalesce(public._mask_id(p->>'id_type', p->>'id_number'), id_number),
         id_doc_path = coalesce(v_doc, id_doc_path),
         consent_at  = now()
   where id = v_b.guest_id;

  update public.bookings
     set self_checkin_at = now(), self_checkin_count = self_checkin_count + 1
   where id = v_b.id;

  return jsonb_build_object('ok', true, 'code', v_b.code);
end $$;

-- =====================================================================
-- Retention: ID photos are deleted N days after the guest's last stay.
-- Called only by the purge-id-docs Edge Function (service role).
-- =====================================================================
create or replace function public.id_docs_due_for_purge(p_limit int default 200)
returns table (guest_id uuid, path text)
language sql stable security definer set search_path = public, pg_temp as $$
  select g.id, g.id_doc_path
    from public.guests g join public.properties p on p.id = g.property_id
   where g.id_doc_path is not null
     and not exists (select 1 from public.bookings b where b.guest_id = g.id
                      and b.check_out_at > now() - make_interval(days => p.id_doc_retention_days))
   limit p_limit
$$;

create or replace function public.mark_id_doc_purged(p_guest uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.guests set id_doc_path = null where id = p_guest
$$;

-- =====================================================================
-- Execute permissions: nothing by default, then exactly what each role needs
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.my_property_ids(public.member_role[]),
  public.my_memberships(),
  public.touch_presence(uuid),
  public.create_booking(jsonb),
  public.update_booking(uuid, jsonb),
  public.booking_action(uuid, text, boolean),
  public.record_payment(uuid, int, text, text, text, text),
  public.list_bookings(uuid, text, text, timestamptz, uuid, int),
  public.booking_status_counts(uuid),
  public.occupancy_series(uuid, date, date),
  public.booking_detail(uuid),
  public.dashboard_summary(uuid),
  public.bed_board(uuid),
  public.calendar_range(uuid, date, int),
  public.available_beds(uuid, timestamptz, timestamptz),
  public.set_bed_block(uuid, timestamptz, timestamptz, text),
  public.list_payments(uuid, text, date, date, timestamptz, uuid, int),
  public.payment_summary(uuid, date, date),
  public.guest_profile(uuid),
  public.search_guests(uuid, text),
  public.report_summary(uuid, date, date),
  public.list_members(uuid),
  public.add_member(uuid, text, text, text),
  public.remove_member(uuid, uuid),
  public.mark_notifications_read(uuid)
to authenticated;

-- Guests (not signed in) can only use these three
grant execute on function
  public.selfcheckin_get(uuid),
  public.selfcheckin_submit(uuid, jsonb),
  public.checkin_upload_allowed(text)
to anon, authenticated;

grant execute on function public.id_docs_due_for_purge(int), public.mark_id_doc_purged(uuid) to service_role;
