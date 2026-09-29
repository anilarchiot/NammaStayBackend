-- =====================================================================
-- NammaStay · 016_extras.sql
-- Extra charges on a booking: food, laundry, rentals, transport, tours…
--   • extra_items       each property's price list (owner / manager edit)
--   • booking_charges   what was added to a guest's bill (qty × price)
--   • bookings.charges_paise = sum of the booking's charges; the booking
--     total (and so the balance due) = stay + extras
-- Charges are added / removed only through add_charge / remove_charge.
-- A charge can't be removed if that would make the total less than what
-- the guest has already paid (record a refund instead).
-- Run AFTER 014_hotels_homestays.sql.
-- =====================================================================

create table public.extra_items (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  name         text not null check (char_length(btrim(name)) between 1 and 80),
  category     text not null default 'other' check (category in ('food','laundry','rental','transport','tour','other')),
  price_paise  int  not null check (price_paise between 0 and 100000000),
  unit         text not null default 'each' check (char_length(unit) <= 30),
  is_active    boolean not null default true,
  sort         int not null default 0,
  created_at   timestamptz not null default now()
);
create index extra_items_prop on public.extra_items (property_id, is_active, sort);

alter table public.bookings add column if not exists charges_paise int not null default 0 check (charges_paise >= 0);

create table public.booking_charges (
  id                uuid primary key default gen_random_uuid(),
  property_id       uuid not null,
  booking_id        uuid not null,
  item_id           uuid references public.extra_items(id) on delete set null,
  name              text not null check (char_length(btrim(name)) between 1 and 80),
  category          text not null default 'other' check (category in ('food','laundry','rental','transport','tour','other')),
  qty               numeric(8,2) not null check (qty > 0 and qty <= 999),
  unit_price_paise  int not null check (unit_price_paise between 0 and 100000000),
  amount_paise      int not null check (amount_paise >= 0),
  note              text check (char_length(note) <= 200),
  charged_on        date not null default current_date,
  created_by        uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  foreign key (booking_id, property_id) references public.bookings(id, property_id) on delete cascade
);
create index booking_charges_booking on public.booking_charges (booking_id, created_at);
create index booking_charges_prop on public.booking_charges (property_id, charged_on);

-- ---------- security ----------
alter table public.extra_items enable row level security;
alter table public.booking_charges enable row level security;
create policy extras_select on public.extra_items for select to authenticated
  using (property_id in (select public.my_property_ids()));
create policy extras_write on public.extra_items for all to authenticated
  using      (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])))
  with check (property_id in (select public.my_property_ids(array['owner','manager']::public.member_role[])));
create policy charges_select on public.booking_charges for select to authenticated
  using (property_id in (select public.my_property_ids()));
revoke all on public.extra_items, public.booking_charges from anon, authenticated;
grant select, insert, update, delete on public.extra_items to authenticated;
grant select on public.booking_charges to authenticated;          -- writes only through the functions below

-- ---------- add / remove ----------
-- p: { item_id?  |  name + unit_price_paise (+ category) ,  qty, note?, charged_on? }
create or replace function public.add_charge(p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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

create or replace function public.remove_charge(p_charge uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- stay changes keep the extras in the total
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
  if v_nights * (v_rate + v_extra) + v_b.charges_paise < v_b.paid_paise then
    raise exception 'New total is less than what''s already paid. Record a refund first.';
  end if;

  begin
    update public.bookings
       set check_in_at = v_in, check_out_at = v_out, bed_id = v_bed.id,
           rate_paise = v_rate, nights = v_nights, total_paise = v_nights * (v_rate + v_extra) + charges_paise,
           visitors = v_adults, children = v_children, extra_paise = v_extra,
           note = case when p ? 'note' then nullif(btrim(p->>'note'), '') else note end
     where id = p_booking
     returning * into v_b;
  exception when exclusion_violation then
    raise exception '% is already booked for part of those dates.', v_bed.label using errcode = '23P01';
  end;

  return jsonb_build_object('id', v_b.id, 'total_paise', v_b.total_paise, 'nights', v_b.nights);
end $$;

revoke execute on function public.add_charge(uuid, jsonb), public.remove_charge(uuid) from public, anon, authenticated;
grant execute on function public.add_charge(uuid, jsonb), public.remove_charge(uuid) to authenticated;
