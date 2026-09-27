-- =====================================================================
-- NammaStay · 013_admin_add_property.sql
-- Let the platform admin add a property FOR a customer:
--   • creates the property (+ free trial or complimentary access)
--   • links the owner by email — right away if they already have a login,
--     otherwise when they sign up with that email (property_invites)
--   • optionally adds you as manager so you can set up rooms & beds
-- Run AFTER 007_subscriptions.sql and 011_admin_panel.sql.
-- =====================================================================

create table public.property_invites (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  email        text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role         public.member_role not null default 'owner',
  display_name text check (char_length(display_name) <= 80),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  claimed_by   uuid references auth.users(id) on delete set null,
  claimed_at   timestamptz,
  unique (property_id, email)
);
create index property_invites_email on public.property_invites (lower(email)) where claimed_at is null;
alter table public.property_invites enable row level security;       -- only reachable through the functions below
revoke all on public.property_invites from anon, authenticated;

create or replace function public.admin_create_property(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_email text := lower(btrim(coalesce(p->>'owner_email', '')));
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_owner uuid;
  v_prop  uuid;
  v_days  int := nullif(p->>'trial_days', '')::int;
begin
  perform public._assert_platform_admin();
  if char_length(v_name) < 2 then raise exception 'Enter the property name.'; end if;
  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the owner’s email address.'; end if;
  if v_days is not null and (v_days < 0 or v_days > 365) then raise exception 'Trial days must be between 0 and 365.'; end if;

  insert into public.properties (name, kind, city, address, phone, email)
  values (left(v_name, 120), coalesce(nullif(p->>'kind', ''), 'hostel'),
          left(nullif(btrim(p->>'city'), ''), 80), left(nullif(btrim(p->>'address'), ''), 300),
          left(nullif(btrim(p->>'phone'), ''), 20), v_email)
  returning id into v_prop;                                   -- trigger starts the standard free trial

  update public.subscriptions set
    trial_ends_at    = case when v_days is not null then now() + make_interval(days => v_days) else trial_ends_at end,
    is_complimentary = coalesce((p->>'complimentary')::boolean, false),
    admin_note       = nullif(left(btrim(coalesce(p->>'admin_note', '')), 4000), '')
  where property_id = v_prop;

  -- optional: you as manager, to set up rooms and beds for them
  if coalesce((p->>'add_me')::boolean, false) then
    insert into public.property_members (property_id, user_id, role, display_name, email)
    select v_prop, auth.uid(), 'manager', 'NammaStay support', u.email from auth.users u where u.id = auth.uid()
    on conflict do nothing;
  end if;

  -- owner: link now if they already have a login, otherwise when they sign up
  select id into v_owner from auth.users where lower(email) = v_email;
  insert into public.property_invites (property_id, email, role, display_name, claimed_by, claimed_at)
  values (v_prop, v_email, 'owner', nullif(left(btrim(coalesce(p->>'owner_name', '')), 80), ''),
          v_owner, case when v_owner is not null then now() end);
  if v_owner is not null then
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (v_prop, v_owner, 'owner', nullif(left(btrim(coalesce(p->>'owner_name', '')), 80), ''), v_email)
    on conflict (property_id, user_id) do update set role = 'owner';
  end if;

  return jsonb_build_object('property_id', v_prop, 'owner_linked', v_owner is not null,
    'trial_ends_at', (select trial_ends_at from public.subscriptions where property_id = v_prop));
end $$;

-- Called by the app after sign-in: link any properties waiting for this email
create or replace function public.claim_property_invites() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_email text; v_n int := 0; r record;
begin
  if v_uid is null then return 0; end if;
  select lower(email) into v_email from auth.users where id = v_uid;
  for r in select * from public.property_invites where lower(email) = v_email and claimed_at is null for update loop
    insert into public.property_members (property_id, user_id, role, display_name, email)
    values (r.property_id, v_uid, r.role, r.display_name, v_email)
    on conflict (property_id, user_id) do update set role = excluded.role;
    update public.property_invites set claimed_by = v_uid, claimed_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.admin_property_invites(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('email', email, 'role', role, 'name', display_name,
            'created_at', created_at, 'claimed_at', claimed_at) order by created_at), '[]'::jsonb)
            from public.property_invites where property_id = p_property);
end $$;

revoke execute on function public.admin_create_property(jsonb), public.claim_property_invites(), public.admin_property_invites(uuid)
  from public, anon, authenticated;
grant execute on function public.admin_create_property(jsonb), public.claim_property_invites(), public.admin_property_invites(uuid)
  to authenticated;
