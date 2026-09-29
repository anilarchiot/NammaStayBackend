-- =====================================================================
-- NammaStay · 018_invoice_offers.sql
--   1. GST invoice / bill — numbered per financial year (INV/2026-27/0001),
--      prices include GST; CGST + SGST split; room GST automatic by nightly
--      rate (nil ≤ ₹1,000 · 5% ≤ ₹7,500 · 18% above) or a fixed rate.
--      Confirm the rates with your CA.
--   2. Regular-guest offers — off by default; e.g. 2nd stay 5%, 5th stay 10%.
-- Run AFTER 017_role_permissions.sql.
-- =====================================================================

alter table public.properties
  add column if not exists legal_name text check (char_length(legal_name) <= 120),
  add column if not exists gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'),
  add column if not exists gst_mode text not null default 'none' check (gst_mode in ('none','auto','fixed')),
  add column if not exists gst_rate numeric(5,2) not null default 5 check (gst_rate between 0 and 28),
  add column if not exists extras_gst_rate numeric(5,2) not null default 5 check (extras_gst_rate between 0 and 28),
  add column if not exists invoice_prefix text not null default 'INV' check (invoice_prefix ~ '^[A-Z0-9-]{1,10}$'),
  add column if not exists offers jsonb not null default '{"enabled": false, "tiers": [{"from_stay": 2, "pct": 5}, {"from_stay": 5, "pct": 10}]}'::jsonb
    check (jsonb_typeof(offers) = 'object');
grant update (legal_name, gstin, gst_mode, gst_rate, extras_gst_rate, invoice_prefix, offers)
  on public.properties to authenticated;                  -- RLS: owner / manager

alter table public.bookings
  add column if not exists discount_pct numeric(5,2) not null default 0 check (discount_pct between 0 and 100),
  add column if not exists discount_paise int not null default 0 check (discount_paise >= 0);

-- =====================================================================
-- 2. Regular-guest offers
-- =====================================================================
-- % off for this guest's NEXT stay (offers.tiers: from_stay = 2 means "second stay onwards")
create or replace function public._offer_pct(p_property uuid, p_guest uuid) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o jsonb; v_prev int; v_pct numeric := 0; t jsonb;
begin
  select offers into o from public.properties where id = p_property;
  if o is null or coalesce((o->>'enabled')::boolean, false) is not true or p_guest is null then return 0; end if;
  select count(*) into v_prev from public.bookings where guest_id = p_guest and status in ('checked_in','checked_out');
  for t in select * from jsonb_array_elements(coalesce(o->'tiers', '[]'::jsonb)) loop
    if (t->>'from_stay')::int <= v_prev + 1 and (t->>'pct')::numeric > v_pct then v_pct := least((t->>'pct')::numeric, 50); end if;
  end loop;
  return v_pct;
end $$;

-- Owner / manager can change or remove the offer on one booking
create or replace function public.set_booking_discount(p_booking uuid, p_pct numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings%rowtype; v_stay int; v_disc int;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager']::public.member_role[]);
  if p_pct < 0 or p_pct > 50 then raise exception 'Discount must be between 0 and 50%%.'; end if;
  v_stay := b.nights * (b.rate_paise + b.extra_paise);
  v_disc := round(v_stay * p_pct / 100.0);
  if v_stay - v_disc + b.charges_paise < b.paid_paise then raise exception 'The new total would be less than what’s already paid. Record a refund first.'; end if;
  update public.bookings set discount_pct = p_pct, discount_paise = v_disc, total_paise = v_stay - v_disc + charges_paise where id = b.id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'discount', jsonb_build_object('pct', p_pct, 'amount_paise', v_disc), auth.uid());
end $$;

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
  v_adults int;
  v_children int;
  v_extra  int;
  v_stay   int;
  v_pct    numeric := 0;
  v_disc   int := 0;
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
    if coalesce(p#>>'{guest,id_doc_path}', '') not in ('') and p#>>'{guest,id_doc_path}' not like v_prop::text || '/%'
       or coalesce(p#>>'{guest,id_doc_back_path}', '') not in ('') and p#>>'{guest,id_doc_back_path}' not like v_prop::text || '/%' then
      raise exception 'ID photo upload is invalid. Please try again.';
    end if;
    perform public._check_dob(v_dob);
    insert into public.guests (property_id, full_name, phone, email, dob, nationality, id_type, id_number, id_doc_path, id_doc_back_path, consent_at)
    values (v_prop,
            btrim(p#>>'{guest,full_name}'),
            public._clean_phone(p#>>'{guest,phone}'),
            nullif(lower(btrim(p#>>'{guest,email}')), ''),
            v_dob,
            nullif(btrim(p#>>'{guest,nationality}'), ''),
            nullif(p#>>'{guest,id_type}', '')::public.id_doc_type,
            public._mask_id(nullif(p#>>'{guest,id_type}', ''), p#>>'{guest,id_number}'),
            nullif(p#>>'{guest,id_doc_path}', ''),
            nullif(p#>>'{guest,id_doc_back_path}', ''),
            now())
    returning id into v_guest;
  elsif not exists (select 1 from public.guests where id = v_guest and property_id = v_prop) then
    raise exception 'Guest not found.';
  end if;

  v_nights := greatest(1, public._local_date(v_prop, v_out) - public._local_date(v_prop, v_in));
  v_adults := greatest(1, coalesce(nullif(p->>'visitors', '')::int, 1));
  v_children := greatest(0, coalesce(nullif(p->>'children', '')::int, 0));
  if v_adults + v_children > v_bed.max_guests then
    raise exception '% fits up to % guest%.', v_bed.label, v_bed.max_guests, case when v_bed.max_guests = 1 then '' else 's' end;
  end if;
  v_extra := greatest(0, v_adults - v_bed.base_guests) * v_bed.extra_guest_paise;
  v_stay := v_nights * (v_bed.rate_paise + v_extra);

  begin
    v_pct  := public._offer_pct(v_prop, v_guest);                        -- regular-guest offer (0 when off)
    v_disc := round(v_stay * v_pct / 100.0);
    insert into public.bookings (property_id, guest_id, bed_id, visitors, children, extra_paise, discount_pct, discount_paise, check_in_at, check_out_at,
                                 nights, rate_paise, total_paise, status, source, note,
                                 send_confirmation, arrived_at)
    values (v_prop, v_guest, v_bed.id,
            v_adults, v_children, v_extra, v_pct, v_disc,
            v_in, v_out, v_nights, v_bed.rate_paise, v_stay - v_disc,
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

  return jsonb_build_object('id', v_b.id, 'code', v_b.code, 'nights', v_nights, 'guest_id', v_b.guest_id, 'discount_pct', v_pct, 'discount_paise', v_disc,
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
  v_adults int;
  v_children int;
  v_extra int;
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
  v_adults := greatest(1, coalesce(nullif(p->>'visitors', '')::int, v_b.visitors));
  v_children := greatest(0, coalesce(nullif(p->>'children', '')::int, v_b.children));
  -- check capacity only when guests or the room change (older bookings keep working)
  if (p ? 'visitors' or p ? 'children' or v_bed.id <> v_b.bed_id) and v_adults + v_children > v_bed.max_guests then
    raise exception '% fits up to % guest%.', v_bed.label, v_bed.max_guests, case when v_bed.max_guests = 1 then '' else 's' end;
  end if;
  v_extra := greatest(0, v_adults - v_bed.base_guests) * v_bed.extra_guest_paise;
  if v_nights * (v_rate + v_extra) - round(v_nights * (v_rate + v_extra) * v_b.discount_pct / 100.0) + v_b.charges_paise < v_b.paid_paise then
    raise exception 'New total is less than what''s already paid. Record a refund first.';
  end if;

  begin
    update public.bookings
       set check_in_at = v_in, check_out_at = v_out, bed_id = v_bed.id,
           rate_paise = v_rate, nights = v_nights,
           discount_paise = round(v_nights * (v_rate + v_extra) * discount_pct / 100.0),
           total_paise = v_nights * (v_rate + v_extra) - round(v_nights * (v_rate + v_extra) * discount_pct / 100.0) + charges_paise,
           visitors = v_adults, children = v_children, extra_paise = v_extra,
           note = case when p ? 'note' then nullif(btrim(p->>'note'), '') else note end
     where id = p_booking
     returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  return jsonb_build_object('id', v_b.id, 'total_paise', v_b.total_paise, 'nights', v_b.nights);
end $$;

-- =====================================================================
-- 1. Invoices
-- =====================================================================
create table public.invoice_counters (
  property_id uuid not null references public.properties(id) on delete cascade,
  fy          text not null,
  last_no     int  not null default 0,
  primary key (property_id, fy)
);
create table public.invoices (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null,
  booking_id  uuid not null,
  number      text not null,
  fy          text not null,
  issued_at   timestamptz not null default now(),
  total_paise int not null,
  doc         jsonb not null,
  created_by  uuid default auth.uid(),
  unique (property_id, number),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index invoices_booking on public.invoices (booking_id, issued_at desc);
alter table public.invoice_counters enable row level security;
alter table public.invoices enable row level security;
create policy invoices_select on public.invoices for select to authenticated using (property_id in (select public.my_property_ids()));
revoke all on public.invoice_counters, public.invoices from anon, authenticated;
grant select on public.invoices to authenticated;

create or replace function public._room_gst(p_mode text, p_fixed numeric, p_per_night int) returns numeric
language sql immutable set search_path = public, pg_temp as $$
  select case p_mode when 'none' then 0 when 'fixed' then p_fixed
    else case when p_per_night <= 100000 then 0 when p_per_night <= 750000 then 5 else 18 end end
$$;

-- p_buyer (optional): { "name": "...", "gstin": "..." } for company bills
create or replace function public.issue_invoice(p_booking uuid, p_buyer jsonb default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b public.bookings%rowtype; p public.properties%rowtype; g public.guests%rowtype;
  v_room text; v_bed text; v_lines jsonb := '[]'::jsonb; v_amt bigint := 0; v_taxable bigint := 0; v_tax bigint := 0;
  r_room numeric; r_x numeric; v_per int; ln record; v_fy text; v_no int; v_num text; v_doc jsonb; v_last public.invoices%rowtype;
  v_buyer jsonb := coalesce(p_buyer, '{}'::jsonb);
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk','accountant']::public.member_role[]);
  if b.status in ('cancelled','no_show') and b.paid_paise = 0 then raise exception 'Nothing to bill on a cancelled booking.'; end if;
  if nullif(v_buyer->>'gstin', '') is not null and upper(v_buyer->>'gstin') !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then
    raise exception 'Check the company GSTIN (15 characters).';
  end if;
  select * into p from public.properties where id = b.property_id;
  select * into g from public.guests where id = b.guest_id;
  select r.name, bd.label into v_room, v_bed from public.beds bd join public.rooms r on r.id = bd.room_id where bd.id = b.bed_id;

  v_per  := b.rate_paise + b.extra_paise - (b.discount_paise / greatest(b.nights, 1));
  r_room := public._room_gst(p.gst_mode, p.gst_rate, v_per);
  r_x    := case when p.gst_mode = 'none' then 0 else p.extras_gst_rate end;

  -- lines: (description, sac, qty, rate, amount, gst %)
  for ln in
    select * from (values
      (1, format('Accommodation — %s · %s', v_room, v_bed), '996311', b.nights::numeric, b.rate_paise, b.nights * b.rate_paise, r_room),
      (2, 'Extra guest charge', '996311', b.nights::numeric, b.extra_paise, b.nights * b.extra_paise, r_room),
      (3, format('Regular-guest offer (%s%%)', trim(to_char(b.discount_pct, 'FM990.##'))), '996311', 1::numeric, -b.discount_paise, -b.discount_paise, r_room)
    ) v(o, d, sac, q, rt, amt, rate) where amt <> 0
    union all
    select 10 + row_number() over (order by c.created_at), c.name || coalesce(' — ' || c.note, ''),
           case c.category when 'food' then '996331' else '' end, c.qty, c.unit_price_paise, c.amount_paise, r_x
      from public.booking_charges c where c.booking_id = b.id
    order by 1
  loop
    declare v_t bigint := round(ln.amt * 100.0 / (100 + ln.rate)); begin
      v_lines := v_lines || jsonb_build_object('desc', ln.d, 'sac', ln.sac, 'qty', ln.q, 'rate_paise', ln.rt, 'amount_paise', ln.amt,
                                               'gst_rate', ln.rate, 'taxable_paise', v_t, 'tax_paise', ln.amt - v_t);
      v_amt := v_amt + ln.amt; v_taxable := v_taxable + v_t; v_tax := v_tax + (ln.amt - v_t);
    end;
  end loop;

  -- same bill as last time → reuse its number
  select * into v_last from public.invoices where booking_id = b.id order by issued_at desc limit 1;
  if found and v_last.total_paise = v_amt and v_last.doc->'lines' = v_lines
     and coalesce(v_last.doc->'buyer'->>'company', '') = coalesce(v_buyer->>'name', '')
     and coalesce(v_last.doc->'buyer'->>'gstin', '') = coalesce(upper(v_buyer->>'gstin'), '')
     and (v_last.doc->>'paid_paise')::int = b.paid_paise then
    return v_last.doc;
  end if;

  v_fy := (select case when extract(month from d) >= 4 then extract(year from d)::int else extract(year from d)::int - 1 end
             from (select public._local_date(b.property_id, now()) d) x)::text;
  v_fy := v_fy || '-' || right(((v_fy::int) + 1)::text, 2);
  insert into public.invoice_counters (property_id, fy, last_no) values (b.property_id, v_fy, 1)
  on conflict (property_id, fy) do update set last_no = public.invoice_counters.last_no + 1
  returning last_no into v_no;
  v_num := p.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 4, '0');

  v_doc := jsonb_build_object(
    'number', v_num, 'issued_at', now(), 'fy', v_fy,
    'title', case when p.gst_mode <> 'none' and p.gstin is not null then 'Tax invoice' else 'Bill / receipt' end,
    'gst', p.gst_mode <> 'none' and p.gstin is not null,
    'seller', jsonb_build_object('name', p.name, 'legal_name', coalesce(p.legal_name, p.name), 'gstin', p.gstin,
                                 'address', concat_ws(', ', p.address, p.city), 'phone', p.phone, 'email', p.email),
    'buyer', jsonb_build_object('name', g.full_name, 'phone', g.phone, 'email', g.email,
                                'company', nullif(btrim(v_buyer->>'name'), ''), 'gstin', nullif(upper(btrim(v_buyer->>'gstin')), '')),
    'stay', jsonb_build_object('code', b.code, 'room', v_room, 'bed', v_bed, 'check_in_at', b.check_in_at, 'check_out_at', b.check_out_at,
                               'nights', b.nights, 'adults', b.visitors, 'children', b.children),
    'lines', v_lines,
    'amount_paise', v_amt, 'taxable_paise', v_taxable, 'cgst_paise', v_tax / 2, 'sgst_paise', v_tax - v_tax / 2,
    'paid_paise', b.paid_paise, 'balance_paise', v_amt - b.paid_paise,
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'kind', x.kind, 'method', x.method, 'amount_paise', x.amount_paise,
                   'received_at', x.received_at, 'reference', x.reference) order by x.received_at), '[]'::jsonb)
                 from public.payments x where x.booking_id = b.id));
  insert into public.invoices (property_id, booking_id, number, fy, total_paise, doc) values (b.property_id, b.id, v_num, v_fy, v_amt, v_doc);
  return v_doc;
end $$;

revoke execute on function public._offer_pct(uuid, uuid), public.set_booking_discount(uuid, numeric), public._room_gst(text, numeric, int),
  public.issue_invoice(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.set_booking_discount(uuid, numeric), public.issue_invoice(uuid, jsonb) to authenticated;
