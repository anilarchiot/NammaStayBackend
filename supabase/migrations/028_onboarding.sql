-- =====================================================================
-- NammaStay · 028_onboarding.sql — first-time setup wizard
-- New owners are guided through: property details → rooms & beds →
-- UPI payments → staff → first booking. The dashboard shows a setup
-- checklist until it's finished (or hidden).
-- Run AFTER 027_channex.sql.
-- =====================================================================
alter table public.properties add column if not exists setup_done_at timestamptz;
-- properties that already have bookings are clearly set up — don't show them the wizard
update public.properties p set setup_done_at = now()
 where setup_done_at is null and exists (select 1 from public.bookings b where b.property_id = p.id);

create or replace function public.setup_progress(p_property uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p public.properties%rowtype;
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  select * into p from public.properties where id = p_property;
  return jsonb_build_object(
    'done_at', p.setup_done_at,
    'details', p.phone is not null and p.address is not null and p.city is not null,
    'rooms', exists (select 1 from public.beds where property_id = p_property and is_active),
    'upi', p.upi_id is not null,
    'staff', (select count(*) from public.property_members where property_id = p_property) > 1,
    'booking', exists (select 1 from public.bookings where property_id = p_property));
end $$;

create or replace function public.setup_finish(p_property uuid, p_done boolean default true) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_role(p_property, array['owner','manager']::public.member_role[]);
  update public.properties set setup_done_at = case when p_done then coalesce(setup_done_at, now()) end where id = p_property;
end $$;

revoke execute on function public.setup_progress(uuid), public.setup_finish(uuid, boolean) from public, anon, authenticated;
grant execute on function public.setup_progress(uuid), public.setup_finish(uuid, boolean) to authenticated;
