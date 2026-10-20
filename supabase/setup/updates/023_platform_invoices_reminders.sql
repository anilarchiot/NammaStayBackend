-- =====================================================================
-- NammaStay · 023_platform_invoices_reminders.sql
--   1. GST invoices for NammaStay subscriptions (NammaStay → property).
--      Issued automatically when an admin approves a subscription payment.
--      Numbered per financial year (NS/2026-27/0001). Prices include GST.
--      Same state as NammaStay → CGST + SGST, other state → IGST.
--      Without NammaStay's GSTIN the document is a plain invoice/receipt.
--   2. Billing reminders: trial ending (3 days, 1 day), trial ended,
--      renewal due (7 days, 1 day), access ended. Each reminder is created
--      once, appears in the owner's notifications, is emailed by the
--      `billing-reminders` edge function (if email is set up) and shows in
--      the admin website with a one-tap WhatsApp message.
-- Rates/SAC: confirm with your CA. Run AFTER 022_admin_2fa.sql.
-- =====================================================================

-- ---------------------------------------------------------------- settings
alter table public.platform_settings
  add column if not exists legal_name     text check (char_length(legal_name) <= 120),
  add column if not exists gstin          text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'),
  add column if not exists address        text check (char_length(address) <= 300),
  add column if not exists state_code     text not null default '33' check (state_code ~ '^[0-9]{2}$'),
  add column if not exists sac            text not null default '998314' check (sac ~ '^[0-9]{4,8}$'),
  add column if not exists gst_rate       numeric(5,2) not null default 18 check (gst_rate between 0 and 28),
  add column if not exists invoice_prefix text not null default 'NS' check (invoice_prefix ~ '^[A-Z0-9-]{1,10}$');

-- Owner's billing details (what goes on their subscription invoice)
alter table public.properties
  add column if not exists bill_name    text check (char_length(bill_name) <= 120),
  add column if not exists bill_gstin   text check (bill_gstin is null or bill_gstin ~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$'),
  add column if not exists bill_address text check (char_length(bill_address) <= 300),
  add column if not exists bill_state   text check (bill_state is null or bill_state ~ '^[0-9]{2}$');

create or replace function public.set_billing_details(p_property uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_gstin text := nullif(upper(btrim(coalesce(p->>'bill_gstin', ''))), '');
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then raise exception 'Check the GSTIN — 15 characters, e.g. 33ABCDE1234F1Z5.'; end if;
  update public.properties set
    bill_name = nullif(left(btrim(coalesce(p->>'bill_name', '')), 120), ''),
    bill_gstin = v_gstin,
    bill_address = nullif(left(btrim(coalesce(p->>'bill_address', '')), 300), ''),
    bill_state = coalesce(left(v_gstin, 2), nullif(p->>'bill_state', ''))
  where id = p_property;
end $$;

create or replace function public.admin_invoice_settings() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select jsonb_build_object('legal_name', legal_name, 'gstin', gstin, 'address', address, 'state_code', state_code,
            'sac', sac, 'gst_rate', gst_rate, 'invoice_prefix', invoice_prefix, 'payee_name', payee_name,
            'support_email', support_email, 'support_whatsapp', support_whatsapp)
          from public.platform_settings where id = 1);
end $$;

create or replace function public.admin_save_invoice_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_gstin text := nullif(upper(btrim(coalesce(p->>'gstin', ''))), '');
begin
  perform public._assert_platform_admin();
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z0-9]{10}[0-9A-Z]{3}$' then raise exception 'Check the GSTIN — 15 characters.'; end if;
  update public.platform_settings set
    legal_name = nullif(left(btrim(coalesce(p->>'legal_name', '')), 120), ''),
    gstin = v_gstin,
    address = nullif(left(btrim(coalesce(p->>'address', '')), 300), ''),
    state_code = coalesce(left(v_gstin, 2), nullif(p->>'state_code', ''), state_code),
    sac = coalesce(nullif(btrim(coalesce(p->>'sac', '')), ''), sac),
    gst_rate = coalesce(nullif(p->>'gst_rate', '')::numeric, gst_rate),
    invoice_prefix = coalesce(nullif(upper(btrim(coalesce(p->>'invoice_prefix', ''))), ''), invoice_prefix),
    updated_at = now()
  where id = 1;
end $$;

-- ---------------------------------------------------------------- invoices
create table if not exists public.platform_invoice_counters (fy text primary key, last_no int not null default 0);
create table if not exists public.platform_invoices (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  payment_id  uuid not null unique references public.subscription_payments(id) on delete cascade,
  number      text not null unique,
  fy          text not null,
  issued_at   timestamptz not null default now(),
  total_paise int  not null,
  doc         jsonb not null
);
create index if not exists platform_invoices_prop on public.platform_invoices (property_id, issued_at desc);
alter table public.platform_invoice_counters enable row level security;
alter table public.platform_invoices enable row level security;
revoke all on public.platform_invoice_counters, public.platform_invoices from anon, authenticated;

create or replace function public._issue_platform_invoice(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  sp public.subscription_payments%rowtype; ps public.platform_settings%rowtype; pr public.properties%rowtype; pl public.plans%rowtype;
  v_owner record; v_existing public.platform_invoices%rowtype; v_fy text; v_no int; v_num text; v_doc jsonb;
  v_gst boolean; v_inter boolean; v_rate numeric; v_taxable bigint; v_tax bigint; v_buyer_state text; v_day date;
begin
  select * into v_existing from public.platform_invoices where payment_id = p_payment;
  if found then return v_existing.doc; end if;
  select * into sp from public.subscription_payments where id = p_payment;
  if not found or sp.status <> 'approved' then return null; end if;
  select * into ps from public.platform_settings where id = 1;
  select * into pr from public.properties where id = sp.property_id;
  select * into pl from public.plans where id = sp.plan_id;
  select m.display_name, m.email into v_owner from public.property_members m where m.property_id = pr.id and m.role = 'owner' order by m.created_at limit 1;

  v_gst := ps.gstin is not null;
  v_rate := case when v_gst then ps.gst_rate else 0 end;
  v_taxable := round(sp.amount_paise * 100.0 / (100 + v_rate));
  v_tax := sp.amount_paise - v_taxable;
  v_buyer_state := coalesce(left(pr.bill_gstin, 2), pr.bill_state);
  v_inter := v_buyer_state is not null and v_buyer_state <> ps.state_code;

  v_day := (coalesce(sp.reviewed_at, now()) at time zone 'Asia/Kolkata')::date;
  v_fy := case when extract(month from v_day) >= 4 then extract(year from v_day)::int else extract(year from v_day)::int - 1 end::text;
  v_fy := v_fy || '-' || right(((v_fy::int) + 1)::text, 2);
  insert into public.platform_invoice_counters (fy, last_no) values (v_fy, 1)
  on conflict (fy) do update set last_no = public.platform_invoice_counters.last_no + 1 returning last_no into v_no;
  v_num := ps.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 4, '0');

  v_doc := jsonb_build_object(
    'number', v_num, 'issued_at', coalesce(sp.reviewed_at, now()), 'fy', v_fy, 'subscription', true,
    'title', case when v_gst then 'Tax invoice' else 'Invoice' end, 'gst', v_gst, 'inter_state', v_gst and v_inter,
    'seller', jsonb_build_object('name', 'NammaStay', 'legal_name', coalesce(ps.legal_name, ps.payee_name, 'NammaStay'), 'gstin', ps.gstin,
                                 'address', ps.address, 'phone', ps.support_whatsapp, 'email', ps.support_email),
    'buyer', jsonb_build_object('name', coalesce(pr.bill_name, pr.name), 'company', case when pr.bill_name is not null and pr.bill_name <> pr.name then pr.name end,
                                'gstin', pr.bill_gstin, 'address', coalesce(pr.bill_address, concat_ws(', ', pr.address, pr.city)),
                                'phone', pr.phone, 'email', v_owner.email),
    'period', jsonb_build_object('plan', pl.name, 'kind', pl.kind, 'from', sp.period_start, 'to', sp.period_end, 'property', pr.name),
    'lines', jsonb_build_array(jsonb_build_object(
       'desc', format('NammaStay subscription — %s plan (%s → %s) · %s', pl.name,
                      to_char(sp.period_start at time zone 'Asia/Kolkata', 'DD Mon YYYY'), to_char(sp.period_end at time zone 'Asia/Kolkata', 'DD Mon YYYY'), pr.name),
       'sac', ps.sac, 'qty', 1, 'rate_paise', sp.amount_paise, 'amount_paise', sp.amount_paise, 'gst_rate', v_rate,
       'taxable_paise', v_taxable, 'tax_paise', v_tax)),
    'amount_paise', sp.amount_paise, 'taxable_paise', v_taxable,
    'cgst_paise', case when v_gst and not v_inter then v_tax / 2 else 0 end,
    'sgst_paise', case when v_gst and not v_inter then v_tax - v_tax / 2 else 0 end,
    'igst_paise', case when v_gst and v_inter then v_tax else 0 end,
    'paid_paise', sp.amount_paise, 'balance_paise', 0,
    'payments', jsonb_build_array(jsonb_build_object('code', 'UPI', 'kind', 'payment', 'method', 'upi', 'amount_paise', sp.amount_paise,
                                                     'received_at', sp.submitted_at, 'reference', sp.utr)));
  insert into public.platform_invoices (property_id, payment_id, number, fy, issued_at, total_paise, doc)
  values (pr.id, sp.id, v_num, v_fy, coalesce(sp.reviewed_at, now()), sp.amount_paise, v_doc);
  insert into public.notifications (property_id, kind, title, body)
  values (pr.id, 'subscription', 'Invoice ' || v_num || ' is ready', 'Settings → Billing → Your invoices');
  return v_doc;
end $$;

create or replace function public._on_sub_payment_approved() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then perform public._issue_platform_invoice(new.id); end if;
  return new;
end $$;
drop trigger if exists sub_payment_invoice on public.subscription_payments;
create trigger sub_payment_invoice after update of status on public.subscription_payments
  for each row execute function public._on_sub_payment_approved();

-- Owner / manager: their invoices
create or replace function public.my_platform_invoices(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select coalesce(jsonb_agg(jsonb_build_object('number', number, 'issued_at', issued_at, 'total_paise', total_paise, 'doc', doc)
            order by issued_at desc), '[]'::jsonb) from public.platform_invoices where property_id = p_property);
end $$;

-- Admin: one property, or the latest across all
create or replace function public.admin_platform_invoices(p_property uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('number', i.number, 'issued_at', i.issued_at, 'total_paise', i.total_paise,
            'payment_id', i.payment_id, 'property', p.name, 'property_id', p.id, 'doc', i.doc) order by i.issued_at desc), '[]'::jsonb)
          from (select * from public.platform_invoices where p_property is null or property_id = p_property order by issued_at desc limit 300) i
          join public.properties p on p.id = i.property_id);
end $$;

-- Admin: create invoices for payments approved before this update
create or replace function public.admin_backfill_invoices() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  perform public._assert_platform_admin();
  for r in select sp.id from public.subscription_payments sp left join public.platform_invoices i on i.payment_id = sp.id
            where sp.status = 'approved' and i.id is null order by sp.reviewed_at loop
    perform public._issue_platform_invoice(r.id); n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- reminders
create table if not exists public.billing_reminders (
  id               uuid primary key default gen_random_uuid(),
  property_id      uuid not null references public.properties(id) on delete cascade,
  kind             text not null check (kind in ('trial_3d','trial_1d','trial_ended','renew_7d','renew_1d','expired')),
  ends_at          timestamptz not null,
  created_at       timestamptz not null default now(),
  emailed_at       timestamptz,
  whatsapp_done_at timestamptz,
  unique (property_id, kind, ends_at)
);
create index if not exists billing_reminders_todo on public.billing_reminders (created_at desc);
alter table public.billing_reminders enable row level security;
revoke all on public.billing_reminders from anon, authenticated;

create or replace function public._reminder_text(p_kind text, p_ends timestamptz) returns jsonb
language sql immutable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'title', case p_kind when 'trial_3d' then 'Your free trial ends in 3 days' when 'trial_1d' then 'Your free trial ends tomorrow'
             when 'trial_ended' then 'Your free trial has ended' when 'renew_7d' then 'Your NammaStay plan renews in 7 days'
             when 'renew_1d' then 'Your NammaStay plan ends tomorrow' else 'Your NammaStay plan has ended' end,
    'body', case when p_kind in ('trial_ended','expired') then 'Choose a plan in Settings → Billing to keep using NammaStay.'
             else 'Ends ' || to_char(p_ends at time zone 'Asia/Kolkata', 'DD Mon YYYY') || ' — Settings → Billing to choose a plan.' end)
$$;

-- Creates today's reminders (once each) + in-app notifications. Safe to run many times a day.
create or replace function public.run_billing_reminders() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_kind text; v_days int; v_id uuid; n int := 0; v_txt jsonb;
begin
  if auth.uid() is not null then perform public._assert_platform_admin(); end if;      -- cron (no user) or an admin
  for r in
    select s.property_id, s.trial_ends_at, s.paid_until,
           (s.paid_until is not null and s.paid_until >= s.trial_ends_at) as paid,
           greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at)) as ends_at
      from public.subscriptions s
     where not s.is_complimentary and not coalesce(s.is_suspended, false)
  loop
    v_days := (r.ends_at at time zone 'Asia/Kolkata')::date - (now() at time zone 'Asia/Kolkata')::date;
    v_kind := case
      when not r.paid and v_days between 2 and 3 then 'trial_3d'
      when not r.paid and v_days between 0 and 1 and r.ends_at > now() then 'trial_1d'
      when not r.paid and r.ends_at <= now() and v_days >= -6 then 'trial_ended'
      when r.paid and v_days between 4 and 7 then 'renew_7d'
      when r.paid and v_days between 0 and 1 and r.ends_at > now() then 'renew_1d'
      when r.paid and r.ends_at <= now() and v_days >= -6 then 'expired'
    end;
    continue when v_kind is null;
    insert into public.billing_reminders (property_id, kind, ends_at) values (r.property_id, v_kind, r.ends_at)
    on conflict (property_id, kind, ends_at) do nothing returning id into v_id;
    if v_id is not null then
      v_txt := public._reminder_text(v_kind, r.ends_at);
      insert into public.notifications (property_id, kind, title, body) values (r.property_id, 'subscription', v_txt->>'title', v_txt->>'body');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Admin: reminders to follow up (WhatsApp) — newest first
create or replace function public.admin_reminders(p_all boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', b.id, 'kind', b.kind, 'ends_at', b.ends_at, 'created_at', b.created_at, 'emailed_at', b.emailed_at,
             'whatsapp_done_at', b.whatsapp_done_at, 'property_id', p.id, 'property', p.name, 'city', p.city, 'phone', p.phone,
             'owner', (select coalesce(m.display_name, m.email) from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
             'email', (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1),
             'text', public._reminder_text(b.kind, b.ends_at)) x
      from public.billing_reminders b join public.properties p on p.id = b.property_id
     where p_all or (b.whatsapp_done_at is null and b.created_at > now() - interval '10 days')
     order by b.created_at desc limit 200) q);
end $$;

create or replace function public.admin_mark_reminder(p_id uuid, p_done boolean default true) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  update public.billing_reminders set whatsapp_done_at = case when p_done then now() end where id = p_id;
end $$;

-- Server only (billing-reminders edge function): reminders still to email, and mark them sent
create or replace function public.reminders_to_email() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'kind', b.kind, 'ends_at', b.ends_at, 'property', p.name,
           'email', m.email, 'name', coalesce(m.display_name, 'there'), 'text', public._reminder_text(b.kind, b.ends_at))), '[]'::jsonb)
    from public.billing_reminders b join public.properties p on p.id = b.property_id
    join lateral (select email, display_name from public.property_members where property_id = p.id and role = 'owner' and email is not null order by created_at limit 1) m on true
   where b.emailed_at is null and b.created_at > now() - interval '3 days'
$$;
create or replace function public.mark_reminders_emailed(p_ids uuid[]) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.billing_reminders set emailed_at = now() where id = any (p_ids)
$$;

-- ---------------------------------------------------------------- owner billing info now includes billing details
create or replace function public.my_billing_details(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  return (select jsonb_build_object('bill_name', bill_name, 'bill_gstin', bill_gstin, 'bill_address', bill_address, 'bill_state', bill_state, 'name', name)
            from public.properties where id = p_property);
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function public.set_billing_details(uuid, jsonb), public.admin_invoice_settings(), public.admin_save_invoice_settings(jsonb),
  public._issue_platform_invoice(uuid), public._on_sub_payment_approved(), public.my_platform_invoices(uuid), public.admin_platform_invoices(uuid),
  public.admin_backfill_invoices(), public._reminder_text(text, timestamptz), public.run_billing_reminders(), public.admin_reminders(boolean),
  public.admin_mark_reminder(uuid, boolean), public.reminders_to_email(), public.mark_reminders_emailed(uuid[]), public.my_billing_details(uuid)
  from public, anon, authenticated;
grant execute on function public.set_billing_details(uuid, jsonb), public.admin_invoice_settings(), public.admin_save_invoice_settings(jsonb),
  public.my_platform_invoices(uuid), public.admin_platform_invoices(uuid), public.admin_backfill_invoices(), public.run_billing_reminders(),
  public.admin_reminders(boolean), public.admin_mark_reminder(uuid, boolean), public.my_billing_details(uuid) to authenticated;
grant execute on function public.run_billing_reminders(), public.reminders_to_email(), public.mark_reminders_emailed(uuid[]) to service_role;
