-- =====================================================================
-- NammaStay · 011_admin_panel.sql
-- Admin panel for you (platform admin) to run NammaStay for other properties:
--   • overview: counts by status, est. monthly revenue, sign-ups per week,
--     bookings across all properties, "needs attention" lists
--   • one property in detail: owner, staff, usage, subscription history
--   • actions: extend, complimentary, SUSPEND / reactivate, private notes
-- Suspension is enforced in the database like expiry (no new bookings,
-- rooms, beds or staff). Run AFTER 007_subscriptions.sql.
-- =====================================================================

alter table public.subscriptions
  add column if not exists is_suspended boolean not null default false,
  add column if not exists suspended_reason text check (char_length(suspended_reason) <= 300),
  add column if not exists suspended_at timestamptz,
  add column if not exists admin_note text check (char_length(admin_note) <= 4000);

-- complimentary | trial | active | grace | expired | suspended
create or replace function public._access_state(p_property uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; v_end timestamptz; v_grace int;
begin
  select * into s from public.subscriptions where property_id = p_property;
  if not found then return 'expired'; end if;
  if s.is_suspended then return 'suspended'; end if;
  if s.is_complimentary then return 'complimentary'; end if;
  if s.paid_until is not null and s.paid_until > now() then return 'active'; end if;
  if s.trial_ends_at > now() and (s.paid_until is null or s.paid_until <= now()) then return 'trial'; end if;
  v_end := greatest(s.trial_ends_at, coalesce(s.paid_until, s.trial_ends_at));
  select grace_days into v_grace from public.platform_settings where id = 1;
  if now() < v_end + make_interval(days => v_grace) then return 'grace'; end if;
  return 'expired';
end $$;

create or replace function public._require_access() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public._access_state(new.property_id) = 'suspended' then
    raise exception 'This property''s NammaStay account is suspended. Please contact NammaStay support.'
      using errcode = 'P0402', hint = 'account_suspended';
  end if;
  if public._access_state(new.property_id) = 'expired' then
    raise exception 'This property''s NammaStay subscription has ended. The owner can renew in Settings → Billing.'
      using errcode = 'P0402', hint = 'subscription_expired';
  end if;
  return new;
end $$;

-- ---------- Overview ----------
create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform public._assert_platform_admin();
  with st as (
    select p.id, p.name, p.city, p.created_at, s.trial_ends_at, s.paid_until, s.plan_id, s.is_complimentary,
           public._access_state(p.id) as state,
           (select m.email from public.property_members m where m.property_id = p.id and m.role = 'owner' order by m.created_at limit 1) as owner_email,
           (select max(b.created_at) from public.bookings b where b.property_id = p.id) as last_booking_at,
           (select max(m.last_seen_at) from public.property_members m where m.property_id = p.id) as last_seen_at
      from public.properties p join public.subscriptions s on s.property_id = p.id)
  select jsonb_build_object(
    'total', (select count(*) from st),
    'counts', (select coalesce(jsonb_object_agg(state, n), '{}'::jsonb) from (select state, count(*) n from st group by state) c),
    'mrr_paise', (select coalesce(round(sum(pl.price_paise::numeric / pl.period_months)), 0)
                    from st join public.plans pl on pl.id = st.plan_id where st.state = 'active'),
    'signups_30d', (select count(*) from st where created_at > now() - interval '30 days'),
    'bookings_30d', (select count(*) from public.bookings where created_at > now() - interval '30 days'),
    'guest_payments_30d_paise', (select coalesce(sum(case kind when 'payment' then amount_paise else -amount_paise end), 0)
                                   from public.payments where received_at > now() - interval '30 days'),
    'pending_payments', (select count(*) from public.subscription_payments where status = 'pending'),
    'weekly_signups', (select coalesce(jsonb_agg(jsonb_build_object('week', w::date,
                          'n', (select count(*) from st where created_at >= w and created_at < w + interval '7 days')) order by w), '[]'::jsonb)
                         from generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '1 week') w),
    'trial_ending', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'ends_at', trial_ends_at) order by trial_ends_at), '[]'::jsonb)
                       from st where state = 'trial' and trial_ends_at < now() + interval '3 days'),
    'payment_due', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'ended_at', greatest(trial_ends_at, coalesce(paid_until, trial_ends_at))) order by paid_until), '[]'::jsonb)
                      from st where state = 'grace'),
    'inactive', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'last_booking_at', last_booking_at, 'last_seen_at', last_seen_at) order by coalesce(last_seen_at, created_at)), '[]'::jsonb)
                   from st where state in ('trial','active') and created_at < now() - interval '7 days'
                     and coalesce(last_booking_at, created_at) < now() - interval '14 days'),
    'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city, 'owner_email', owner_email,
                        'state', state, 'created_at', created_at, 'trial_ends_at', trial_ends_at, 'paid_until', paid_until, 'plan_id', plan_id,
                        'beds', (select count(*) from public.beds b where b.property_id = st.id and b.is_active),
                        'bookings_30d', (select count(*) from public.bookings b where b.property_id = st.id and b.created_at > now() - interval '30 days'),
                        'last_seen_at', last_seen_at) order by created_at desc), '[]'::jsonb) from st)
  ) into v;
  return v;
end $$;

-- ---------- One property in detail ----------
create or replace function public.admin_property(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  if not exists (select 1 from public.properties where id = p_property) then raise exception 'Property not found.'; end if;
  return (select jsonb_build_object(
    'property', jsonb_build_object('id', p.id, 'name', p.name, 'kind', p.kind, 'address', p.address, 'city', p.city,
                                   'phone', p.phone, 'email', p.email, 'upi_id', p.upi_id, 'created_at', p.created_at),
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

-- ---------- Actions ----------
-- p: { extend_days?, complimentary?, suspend?, suspend_reason?, admin_note? }
create or replace function public.admin_set_property(p_property uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_days int := nullif(p->>'extend_days', '')::int;
begin
  perform public._assert_platform_admin();
  if v_days is not null and (v_days < -3650 or v_days > 3650) then raise exception 'Enter a sensible number of days.'; end if;
  if coalesce((p->>'suspend')::boolean, false) and coalesce(btrim(p->>'suspend_reason'), '') = '' then
    raise exception 'Add a short reason for suspending (the owner sees it).';
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
  if p ? 'suspend' then
    insert into public.notifications (property_id, kind, title, body)
    values (p_property, 'subscription',
            case when (p->>'suspend')::boolean then 'Account suspended' else 'Account reactivated' end,
            case when (p->>'suspend')::boolean then left(btrim(p->>'suspend_reason'), 300) else 'You can take new bookings again.' end);
  end if;
end $$;

-- Owners see why they're suspended (banner + Billing tab)
create or replace function public.property_suspension(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager','front_desk','accountant']::public.member_role[]);
  return (select jsonb_build_object('suspended', is_suspended, 'reason', suspended_reason, 'since', suspended_at)
            from public.subscriptions where property_id = p_property);
end $$;

revoke execute on function public.admin_overview(), public.admin_property(uuid), public.admin_set_property(uuid, jsonb),
  public.property_suspension(uuid) from public, anon, authenticated;
grant execute on function public.admin_overview(), public.admin_property(uuid), public.admin_set_property(uuid, jsonb),
  public.property_suspension(uuid) to authenticated;
