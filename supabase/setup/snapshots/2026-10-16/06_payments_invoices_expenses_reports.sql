-- =====================================================================
-- NammaStay · payments invoices expenses reports
-- Payments, extras charged, GST invoices, payment links (Razorpay), expenses & profit, reports
-- Exported 16 Oct 2026 from a complete install (updates 001–043), so every function is its latest version.
-- Order: run the files in number order on an EMPTY Supabase project (01 first). To add one feature to a
-- LIVE database, use the matching file from updates/ instead: those are safe to run on top of existing data.
-- =====================================================================
SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: _offer_pct(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._offer_pct(p_property uuid, p_guest uuid) RETURNS numeric
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: _room_gst(text, numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._room_gst(p_mode text, p_fixed numeric, p_per_night integer) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select case p_mode when 'none' then 0 when 'fixed' then p_fixed
    else case when p_per_night <= 100000 then 0 when p_per_night <= 750000 then 5 else 18 end end
$$;

--
-- Name: add_charge(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_charge(p_booking uuid, p jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  b      public.bookings%rowtype;
  it     public.extra_items%rowtype;
  v_qty  numeric := coalesce(nullif(p->>'qty', '')::numeric, 1);
  v_name text; v_cat text; v_price int; v_amt int; v_id uuid;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if b.status in ('cancelled','no_show') then raise exception 'This booking is cancelled — extras can’t be added.'; end if;
  if v_qty <= 0 or v_qty > 999 then raise exception 'Enter a quantity between 0.5 and 999.'; end if;

  if nullif(p->>'item_id', '') is not null then
    select * into it from public.extra_items where id = (p->>'item_id')::uuid and property_id = b.property_id;
    if not found then raise exception 'That item isn’t in your price list any more.'; end if;
    v_name := it.name; v_cat := it.category;
    v_price := coalesce(nullif(p->>'unit_price_paise', '')::int, it.price_paise);   -- staff may adjust the price
  else
    v_name := btrim(coalesce(p->>'name', ''));
    if char_length(v_name) < 1 then raise exception 'Enter what the extra is for.'; end if;
    v_cat := coalesce(nullif(p->>'category', ''), 'other');
    v_price := nullif(p->>'unit_price_paise', '')::int;
    if v_price is null or v_price < 0 then raise exception 'Enter the price.'; end if;
  end if;
  v_amt := round(v_qty * v_price);

  insert into public.booking_charges (property_id, booking_id, item_id, name, category, qty, unit_price_paise, amount_paise, note, charged_on)
  values (b.property_id, b.id, it.id, left(v_name, 80), v_cat, v_qty, v_price, v_amt,
          nullif(left(btrim(coalesce(p->>'note', '')), 200), ''),
          coalesce(nullif(p->>'charged_on', '')::date, public._local_date(b.property_id, now())))
  returning id into v_id;
  update public.bookings set charges_paise = charges_paise + v_amt, total_paise = total_paise + v_amt where id = b.id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'extra_added', jsonb_build_object('name', v_name, 'qty', v_qty, 'amount_paise', v_amt), auth.uid());
  return jsonb_build_object('id', v_id, 'amount_paise', v_amt);
end $$;

--
-- Name: delete_expense(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_expense(p_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.expenses where id = p_id;
  if v_prop is null then raise exception 'Expense not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(v_prop, 'view_reports');
  delete from public.expenses where id = p_id;
end $$;

--
-- Name: issue_invoice(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.issue_invoice(p_booking uuid, p_buyer jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: list_payments(uuid, text, date, date, timestamp with time zone, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_payments(p_property uuid, p_method text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_cursor_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 30) RETURNS TABLE(id uuid, code text, booking_id uuid, booking_code text, guest_name text, kind public.payment_kind, method public.payment_method, amount_paise integer, reference text, received_at timestamp with time zone, booking_balance_paise integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: paylink_keys(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paylink_keys(p_property uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object('key_id', rzp_key_id, 'key_secret', rzp_key_secret, 'webhook_secret', rzp_webhook_secret)
    from public.property_secrets where property_id = p_property
$$;

--
-- Name: paylink_list(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paylink_list(p_booking uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.bookings where id = p_booking;
  if v_prop is null then raise exception 'Booking not found.'; end if;
  perform public._assert_role(v_prop, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'rzp_link_id', l.rzp_link_id, 'short_url', l.short_url, 'amount_paise', l.amount_paise,
            'status', l.status, 'created_at', l.created_at, 'paid_at', l.paid_at) order by l.created_at desc), '[]'::jsonb)
          from public.payment_links l where l.booking_id = p_booking);
end $$;

--
-- Name: paylink_mark_paid(text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paylink_mark_paid(p_link_id text, p_payment_id text, p_method text, p_amount integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare l public.payment_links%rowtype; b public.bookings%rowtype; v_amt int; v_pay uuid; v_method public.payment_method;
begin
  select * into l from public.payment_links where rzp_link_id = p_link_id for update;
  if not found then return jsonb_build_object('error', 'unknown link'); end if;
  if l.status = 'paid' then return jsonb_build_object('already', true); end if;
  select * into b from public.bookings where id = l.booking_id for update;
  v_amt := least(coalesce(p_amount, l.amount_paise), greatest(b.balance_paise, 0));
  v_method := case lower(coalesce(p_method, '')) when 'card' then 'card' when 'upi' then 'upi' else 'bank' end;
  if v_amt > 0 then
    insert into public.payments (property_id, booking_id, kind, method, amount_paise, reference, note, received_by)
    values (b.property_id, b.id, 'payment', v_method, v_amt, left(p_payment_id, 64), 'Paid online — Razorpay payment link', l.created_by)
    returning id into v_pay;
  end if;
  update public.payment_links set status = 'paid', rzp_payment_id = p_payment_id, payment_id = v_pay, paid_at = now() where id = l.id;
  insert into public.notifications (property_id, kind, title, body, booking_id)
  values (b.property_id, 'payment', 'Online payment received',
          format('%s · %s paid by %s via payment link', b.code, '₹' || to_char(coalesce(p_amount, l.amount_paise) / 100.0, 'FM99,99,99,990.00'), upper(coalesce(p_method, 'online'))), b.id);
  return jsonb_build_object('recorded_paise', v_amt, 'payment_id', v_pay);
end $$;

--
-- Name: paylink_prepare(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paylink_prepare(p_booking uuid, p_amount integer) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare b public.bookings%rowtype; g public.guests%rowtype; p public.properties%rowtype;
begin
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found.'; end if;
  perform public._assert_role(b.property_id, array['owner','manager','front_desk']::public.member_role[]);
  perform public._require_perm(b.property_id, 'record_payments');
  if b.status in ('cancelled','no_show') then raise exception 'This booking is cancelled.'; end if;
  if b.balance_paise <= 0 then raise exception 'Nothing is due on this booking.'; end if;
  if p_amount is null or p_amount < 100 or p_amount > b.balance_paise then
    raise exception 'Amount must be between ₹1 and the balance (₹%).', to_char(b.balance_paise / 100.0, 'FM99,99,99,990.00');
  end if;
  if not exists (select 1 from public.property_secrets where property_id = b.property_id and rzp_key_secret is not null) then
    raise exception 'Connect Razorpay first: Settings → Property details → Online payments.';
  end if;
  select * into g from public.guests where id = b.guest_id;
  select * into p from public.properties where id = b.property_id;
  return jsonb_build_object('booking_id', b.id, 'property_id', b.property_id, 'code', b.code, 'amount_paise', p_amount,
    'guest_name', g.full_name, 'guest_phone', g.phone, 'guest_email', g.email, 'property_name', p.name);
end $$;

--
-- Name: paylink_set_status(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paylink_set_status(p_link_id text, p_status text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  update public.payment_links set status = p_status where rzp_link_id = p_link_id and status = 'created' and p_status in ('cancelled','expired')
$$;

--
-- Name: paylink_store(uuid, uuid, text, text, integer, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.paylink_store(p_property uuid, p_booking uuid, p_link_id text, p_url text, p_amount integer, p_user uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid;
begin
  insert into public.payment_links (property_id, booking_id, rzp_link_id, short_url, amount_paise, created_by)
  values (p_property, p_booking, p_link_id, p_url, p_amount, p_user) returning id into v_id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (p_property, 'booking', p_booking, p_booking, 'paylink_created', jsonb_build_object('amount_paise', p_amount, 'url', p_url), p_user);
  return v_id;
end $$;

--
-- Name: payment_summary(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.payment_summary(p_property uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: profit_summary(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.profit_summary(p_property uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_tz text; v_rev bigint; v_exp bigint; v_m0 date;
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_reports');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid period.'; end if;
  select timezone into v_tz from public.properties where id = p_property;
  select coalesce(sum(case when kind = 'refund' then -amount_paise else amount_paise end), 0) into v_rev
    from public.payments where property_id = p_property and (received_at at time zone v_tz)::date between p_from and p_to;
  select coalesce(sum(amount_paise), 0) into v_exp from public.expenses where property_id = p_property and spent_on between p_from and p_to;
  v_m0 := (date_trunc('month', p_to) - interval '5 months')::date;
  return jsonb_build_object(
    'revenue_paise', v_rev, 'expenses_paise', v_exp, 'profit_paise', v_rev - v_exp,
    'margin', case when v_rev > 0 then round((v_rev - v_exp) * 100.0 / v_rev, 1) else null end,
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'total_paise', t) order by t desc), '[]'::jsonb)
                      from (select category, sum(amount_paise) t from public.expenses
                             where property_id = p_property and spent_on between p_from and p_to group by category) c),
    'months', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'),
                 'revenue_paise', (select coalesce(sum(case when kind = 'refund' then -amount_paise else amount_paise end), 0) from public.payments
                                    where property_id = p_property and date_trunc('month', (received_at at time zone v_tz)::date) = m),
                 'expenses_paise', (select coalesce(sum(amount_paise), 0) from public.expenses
                                     where property_id = p_property and date_trunc('month', spent_on) = m)) order by m), '[]'::jsonb)
               from generate_series(v_m0, date_trunc('month', p_to)::date, interval '1 month') m));
end $$;

--
-- Name: razorpay_status(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.razorpay_status(p_property uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare s public.property_secrets%rowtype;
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  select * into s from public.property_secrets where property_id = p_property;
  return jsonb_build_object('connected', s.rzp_key_id is not null and s.rzp_key_secret is not null,
    'mode', case when s.rzp_key_id like 'rzp_live_%' then 'live' when s.rzp_key_id like 'rzp_test_%' then 'test' end,
    'key_hint', case when s.rzp_key_id is not null then left(s.rzp_key_id, 9) || '…' || right(s.rzp_key_id, 4) end,
    'webhook', s.rzp_webhook_secret is not null, 'updated_at', s.updated_at);
end $$;

--
-- Name: record_payment(uuid, integer, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_payment(p_booking uuid, p_amount_paise integer, p_method text, p_reference text DEFAULT NULL::text, p_kind text DEFAULT 'payment'::text, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
end $_$;

--
-- Name: remove_charge(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_charge(p_charge uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare c public.booking_charges%rowtype; b public.bookings%rowtype;
begin
  select * into c from public.booking_charges where id = p_charge;
  if not found then raise exception 'Extra not found.'; end if;
  select * into b from public.bookings where id = c.booking_id for update;
  perform public._assert_role(c.property_id, array['owner','manager','front_desk']::public.member_role[]);
  if b.total_paise - c.amount_paise < b.paid_paise then
    raise exception 'The guest has already paid for this. Record a refund instead of removing it.';
  end if;
  delete from public.booking_charges where id = p_charge;
  update public.bookings set charges_paise = greatest(0, charges_paise - c.amount_paise), total_paise = total_paise - c.amount_paise where id = b.id;
  insert into public.audit_log (property_id, entity, entity_id, booking_id, action, details, actor)
  values (b.property_id, 'booking', b.id, b.id, 'extra_removed', jsonb_build_object('name', c.name, 'amount_paise', c.amount_paise), auth.uid());
end $$;

--
-- Name: report_summary(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_summary(p_property uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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

--
-- Name: save_expense(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_expense(p_property uuid, p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid; v_amt int := nullif(p->>'amount_paise', '')::int; v_day date := coalesce(nullif(p->>'spent_on', '')::date, public._local_date(p_property, now()));
begin
  perform public._assert_role(p_property, array['owner','manager','accountant']::public.member_role[]);
  perform public._require_perm(p_property, 'view_reports');
  if v_amt is null or v_amt < 1 then raise exception 'Enter the amount.'; end if;
  if v_day > public._local_date(p_property, now()) + 31 then raise exception 'That date is too far in the future.'; end if;
  if nullif(p->>'id', '') is null then
    insert into public.expenses (property_id, spent_on, category, amount_paise, method, vendor, note)
    values (p_property, v_day, coalesce(nullif(p->>'category', ''), 'other'), v_amt, coalesce(nullif(p->>'method', ''), 'cash'),
            nullif(left(btrim(coalesce(p->>'vendor', '')), 80), ''), nullif(left(btrim(coalesce(p->>'note', '')), 300), ''))
    returning id into v_id;
  else
    update public.expenses set spent_on = v_day, category = coalesce(nullif(p->>'category', ''), category), amount_paise = v_amt,
           method = coalesce(nullif(p->>'method', ''), method), vendor = nullif(left(btrim(coalesce(p->>'vendor', '')), 80), ''),
           note = nullif(left(btrim(coalesce(p->>'note', '')), 300), '')
     where id = (p->>'id')::uuid and property_id = p_property returning id into v_id;
    if v_id is null then raise exception 'Expense not found.'; end if;
  end if;
  return v_id;
end $$;

--
-- Name: set_razorpay_keys(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_razorpay_keys(p_property uuid, p_key_id text, p_key_secret text, p_webhook_secret text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
declare v_id text := nullif(btrim(coalesce(p_key_id, '')), '');
begin
  perform public._assert_role(p_property, array['owner']::public.member_role[]);
  if v_id is null then                                             -- disconnect
    delete from public.property_secrets where property_id = p_property; return;
  end if;
  if v_id !~ '^rzp_(test|live)_[A-Za-z0-9]{8,32}$' then raise exception 'The Key ID looks like rzp_live_XXXXXXXX (Razorpay → Account & Settings → API Keys).'; end if;
  insert into public.property_secrets (property_id, rzp_key_id, rzp_key_secret, rzp_webhook_secret)
  values (p_property, v_id, nullif(btrim(coalesce(p_key_secret, '')), ''), nullif(btrim(coalesce(p_webhook_secret, '')), ''))
  on conflict (property_id) do update set rzp_key_id = excluded.rzp_key_id,
    rzp_key_secret = coalesce(excluded.rzp_key_secret, public.property_secrets.rzp_key_secret),
    rzp_webhook_secret = coalesce(excluded.rzp_webhook_secret, public.property_secrets.rzp_webhook_secret), updated_at = now();
  if (select rzp_key_secret from public.property_secrets where property_id = p_property) is null then
    raise exception 'Enter the Key Secret too.';
  end if;
end $_$;

--
-- Name: booking_charges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_charges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    booking_id uuid NOT NULL,
    item_id uuid,
    name text NOT NULL,
    category text DEFAULT 'other'::text NOT NULL,
    qty numeric(8,2) NOT NULL,
    unit_price_paise integer NOT NULL,
    amount_paise integer NOT NULL,
    note text,
    charged_on date DEFAULT CURRENT_DATE NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT booking_charges_amount_paise_check CHECK ((amount_paise >= 0)),
    CONSTRAINT booking_charges_category_check CHECK ((category = ANY (ARRAY['food'::text, 'laundry'::text, 'rental'::text, 'transport'::text, 'tour'::text, 'other'::text]))),
    CONSTRAINT booking_charges_name_check CHECK (((char_length(btrim(name)) >= 1) AND (char_length(btrim(name)) <= 80))),
    CONSTRAINT booking_charges_note_check CHECK ((char_length(note) <= 200)),
    CONSTRAINT booking_charges_qty_check CHECK (((qty > (0)::numeric) AND (qty <= (999)::numeric))),
    CONSTRAINT booking_charges_unit_price_paise_check CHECK (((unit_price_paise >= 0) AND (unit_price_paise <= 100000000)))
);

--
-- Name: expenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expenses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    spent_on date DEFAULT CURRENT_DATE NOT NULL,
    category text DEFAULT 'other'::text NOT NULL,
    amount_paise integer NOT NULL,
    method text DEFAULT 'cash'::text NOT NULL,
    vendor text,
    note text,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT expenses_amount_paise_check CHECK (((amount_paise >= 1) AND (amount_paise <= 100000000))),
    CONSTRAINT expenses_category_check CHECK ((category = ANY (ARRAY['rent'::text, 'salaries'::text, 'electricity'::text, 'water'::text, 'internet'::text, 'supplies'::text, 'laundry'::text, 'repairs'::text, 'ota_commission'::text, 'marketing'::text, 'food'::text, 'taxes'::text, 'other'::text]))),
    CONSTRAINT expenses_method_check CHECK ((method = ANY (ARRAY['cash'::text, 'upi'::text, 'card'::text, 'bank'::text]))),
    CONSTRAINT expenses_note_check CHECK ((char_length(note) <= 300)),
    CONSTRAINT expenses_vendor_check CHECK ((char_length(vendor) <= 80))
);

--
-- Name: invoice_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice_counters (
    property_id uuid NOT NULL,
    fy text NOT NULL,
    last_no integer DEFAULT 0 NOT NULL
);

--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    booking_id uuid NOT NULL,
    number text NOT NULL,
    fy text NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    total_paise integer NOT NULL,
    doc jsonb NOT NULL,
    created_by uuid DEFAULT auth.uid()
);

--
-- Name: payment_code_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payment_code_seq
    START WITH 10001
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: payment_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    booking_id uuid NOT NULL,
    rzp_link_id text NOT NULL,
    short_url text NOT NULL,
    amount_paise integer NOT NULL,
    status text DEFAULT 'created'::text NOT NULL,
    rzp_payment_id text,
    payment_id uuid,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    paid_at timestamp with time zone,
    CONSTRAINT payment_links_amount_paise_check CHECK ((amount_paise > 0)),
    CONSTRAINT payment_links_status_check CHECK ((status = ANY (ARRAY['created'::text, 'paid'::text, 'cancelled'::text, 'expired'::text])))
);

--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    property_id uuid NOT NULL,
    booking_id uuid NOT NULL,
    code text DEFAULT ('TXN-'::text || nextval('public.payment_code_seq'::regclass)) NOT NULL,
    kind public.payment_kind DEFAULT 'payment'::public.payment_kind NOT NULL,
    method public.payment_method NOT NULL,
    amount_paise integer NOT NULL,
    reference text,
    note text,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    received_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payments_amount_paise_check CHECK (((amount_paise > 0) AND (amount_paise <= 100000000))),
    CONSTRAINT payments_note_check CHECK ((char_length(note) <= 500)),
    CONSTRAINT payments_reference_check CHECK ((char_length(reference) <= 64))
);

--
-- Name: property_secrets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.property_secrets (
    property_id uuid NOT NULL,
    rzp_key_id text,
    rzp_key_secret text,
    rzp_webhook_secret text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT property_secrets_rzp_key_id_check CHECK ((rzp_key_id ~ '^rzp_(test|live)_[A-Za-z0-9]{8,32}$'::text)),
    CONSTRAINT property_secrets_rzp_key_secret_check CHECK (((char_length(rzp_key_secret) >= 8) AND (char_length(rzp_key_secret) <= 120))),
    CONSTRAINT property_secrets_rzp_webhook_secret_check CHECK (((char_length(rzp_webhook_secret) >= 6) AND (char_length(rzp_webhook_secret) <= 120)))
);

--
-- Name: booking_charges booking_charges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_charges
    ADD CONSTRAINT booking_charges_pkey PRIMARY KEY (id);

--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_pkey PRIMARY KEY (id);

--
-- Name: invoice_counters invoice_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_counters
    ADD CONSTRAINT invoice_counters_pkey PRIMARY KEY (property_id, fy);

--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);

--
-- Name: invoices invoices_property_id_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_property_id_number_key UNIQUE (property_id, number);

--
-- Name: payment_links payment_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_links
    ADD CONSTRAINT payment_links_pkey PRIMARY KEY (id);

--
-- Name: payment_links payment_links_rzp_link_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_links
    ADD CONSTRAINT payment_links_rzp_link_id_key UNIQUE (rzp_link_id);

--
-- Name: payments payments_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_code_key UNIQUE (code);

--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);

--
-- Name: property_secrets property_secrets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_secrets
    ADD CONSTRAINT property_secrets_pkey PRIMARY KEY (property_id);

--
-- Name: booking_charges_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_charges_booking ON public.booking_charges USING btree (booking_id, created_at);

--
-- Name: booking_charges_prop; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_charges_prop ON public.booking_charges USING btree (property_id, charged_on);

--
-- Name: expenses_prop_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX expenses_prop_day ON public.expenses USING btree (property_id, spent_on DESC);

--
-- Name: invoices_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoices_booking ON public.invoices USING btree (booking_id, issued_at DESC);

--
-- Name: payment_links_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_links_booking ON public.payment_links USING btree (booking_id, created_at DESC);

--
-- Name: payments_booking; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_booking ON public.payments USING btree (booking_id, received_at);

--
-- Name: payments_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_list ON public.payments USING btree (property_id, received_at DESC, id DESC);

--
-- Name: payments_method; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_method ON public.payments USING btree (property_id, method, received_at DESC);

--
-- Name: payments_upi_ref_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX payments_upi_ref_unique ON public.payments USING btree (property_id, reference) WHERE ((method = 'upi'::public.payment_method) AND (kind = 'payment'::public.payment_kind) AND (reference IS NOT NULL));

--
-- Name: payments payments_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payments_audit AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public._payments_audit();

--
-- Name: payments payments_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payments_no_update BEFORE DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public._payments_immutable();

--
-- Name: payments payments_sync; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payments_sync AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public._payments_sync_booking();

--
-- Name: booking_charges perm_charges; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perm_charges BEFORE INSERT OR DELETE ON public.booking_charges FOR EACH ROW EXECUTE FUNCTION public._perm_charges();

--
-- Name: payments perm_payments; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER perm_payments BEFORE INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public._perm_payments();

--
-- Name: booking_charges booking_charges_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_charges
    ADD CONSTRAINT booking_charges_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: booking_charges booking_charges_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_charges
    ADD CONSTRAINT booking_charges_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.extra_items(id) ON DELETE SET NULL;

--
-- Name: expenses expenses_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: invoice_counters invoice_counters_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_counters
    ADD CONSTRAINT invoice_counters_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: invoices invoices_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: payment_links payment_links_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_links
    ADD CONSTRAINT payment_links_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE CASCADE;

--
-- Name: payments payments_booking_id_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_booking_id_property_id_fkey FOREIGN KEY (booking_id, property_id) REFERENCES public.bookings(id, property_id) ON DELETE RESTRICT;

--
-- Name: property_secrets property_secrets_property_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.property_secrets
    ADD CONSTRAINT property_secrets_property_id_fkey FOREIGN KEY (property_id) REFERENCES public.properties(id) ON DELETE CASCADE;

--
-- Name: booking_charges; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.booking_charges ENABLE ROW LEVEL SECURITY;

--
-- Name: booking_charges charges_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY charges_select ON public.booking_charges FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: expenses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;

--
-- Name: expenses expenses_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY expenses_select ON public.expenses FOR SELECT TO authenticated USING (((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'accountant'::public.member_role]) AS my_property_ids)) AND public._allowed(property_id, 'view_reports'::text)));

--
-- Name: invoice_counters; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invoice_counters ENABLE ROW LEVEL SECURITY;

--
-- Name: invoices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

--
-- Name: invoices invoices_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY invoices_select ON public.invoices FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)));

--
-- Name: payment_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payment_links ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_links payment_links_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payment_links_select ON public.payment_links FOR SELECT TO authenticated USING ((property_id IN ( SELECT public.my_property_ids(ARRAY['owner'::public.member_role, 'manager'::public.member_role, 'front_desk'::public.member_role, 'accountant'::public.member_role]) AS my_property_ids)));

--
-- Name: payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

--
-- Name: payments payments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payments_select ON public.payments FOR SELECT TO authenticated USING (((property_id IN ( SELECT public.my_property_ids() AS my_property_ids)) AND public._allowed(property_id, 'view_payments'::text)));

--
-- Name: property_secrets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.property_secrets ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION _offer_pct(p_property uuid, p_guest uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._offer_pct(p_property uuid, p_guest uuid) FROM PUBLIC;

--
-- Name: FUNCTION _room_gst(p_mode text, p_fixed numeric, p_per_night integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._room_gst(p_mode text, p_fixed numeric, p_per_night integer) FROM PUBLIC;

--
-- Name: FUNCTION add_charge(p_booking uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.add_charge(p_booking uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_charge(p_booking uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION delete_expense(p_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_expense(p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_expense(p_id uuid) TO authenticated;

--
-- Name: FUNCTION issue_invoice(p_booking uuid, p_buyer jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.issue_invoice(p_booking uuid, p_buyer jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.issue_invoice(p_booking uuid, p_buyer jsonb) TO authenticated;

--
-- Name: FUNCTION list_payments(p_property uuid, p_method text, p_from date, p_to date, p_cursor_at timestamp with time zone, p_cursor_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_payments(p_property uuid, p_method text, p_from date, p_to date, p_cursor_at timestamp with time zone, p_cursor_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_payments(p_property uuid, p_method text, p_from date, p_to date, p_cursor_at timestamp with time zone, p_cursor_id uuid, p_limit integer) TO authenticated;

--
-- Name: FUNCTION paylink_keys(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.paylink_keys(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.paylink_keys(p_property uuid) TO service_role;

--
-- Name: FUNCTION paylink_list(p_booking uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.paylink_list(p_booking uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.paylink_list(p_booking uuid) TO authenticated;

--
-- Name: FUNCTION paylink_mark_paid(p_link_id text, p_payment_id text, p_method text, p_amount integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.paylink_mark_paid(p_link_id text, p_payment_id text, p_method text, p_amount integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.paylink_mark_paid(p_link_id text, p_payment_id text, p_method text, p_amount integer) TO service_role;

--
-- Name: FUNCTION paylink_prepare(p_booking uuid, p_amount integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.paylink_prepare(p_booking uuid, p_amount integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.paylink_prepare(p_booking uuid, p_amount integer) TO authenticated;

--
-- Name: FUNCTION paylink_set_status(p_link_id text, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.paylink_set_status(p_link_id text, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.paylink_set_status(p_link_id text, p_status text) TO service_role;

--
-- Name: FUNCTION paylink_store(p_property uuid, p_booking uuid, p_link_id text, p_url text, p_amount integer, p_user uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.paylink_store(p_property uuid, p_booking uuid, p_link_id text, p_url text, p_amount integer, p_user uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.paylink_store(p_property uuid, p_booking uuid, p_link_id text, p_url text, p_amount integer, p_user uuid) TO service_role;

--
-- Name: FUNCTION payment_summary(p_property uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.payment_summary(p_property uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.payment_summary(p_property uuid, p_from date, p_to date) TO authenticated;

--
-- Name: FUNCTION profit_summary(p_property uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.profit_summary(p_property uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.profit_summary(p_property uuid, p_from date, p_to date) TO authenticated;

--
-- Name: FUNCTION razorpay_status(p_property uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.razorpay_status(p_property uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.razorpay_status(p_property uuid) TO authenticated;

--
-- Name: FUNCTION record_payment(p_booking uuid, p_amount_paise integer, p_method text, p_reference text, p_kind text, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_payment(p_booking uuid, p_amount_paise integer, p_method text, p_reference text, p_kind text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_payment(p_booking uuid, p_amount_paise integer, p_method text, p_reference text, p_kind text, p_note text) TO authenticated;

--
-- Name: FUNCTION remove_charge(p_charge uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.remove_charge(p_charge uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_charge(p_charge uuid) TO authenticated;

--
-- Name: FUNCTION report_summary(p_property uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.report_summary(p_property uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_summary(p_property uuid, p_from date, p_to date) TO authenticated;

--
-- Name: FUNCTION save_expense(p_property uuid, p jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_expense(p_property uuid, p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_expense(p_property uuid, p jsonb) TO authenticated;

--
-- Name: FUNCTION set_razorpay_keys(p_property uuid, p_key_id text, p_key_secret text, p_webhook_secret text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_razorpay_keys(p_property uuid, p_key_id text, p_key_secret text, p_webhook_secret text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_razorpay_keys(p_property uuid, p_key_id text, p_key_secret text, p_webhook_secret text) TO authenticated;

--
-- Name: TABLE booking_charges; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.booking_charges TO authenticated;

--
-- Name: TABLE expenses; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.expenses TO authenticated;

--
-- Name: TABLE invoices; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.invoices TO authenticated;

--
-- Name: TABLE payment_links; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.payment_links TO authenticated;

--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.payments TO authenticated;
