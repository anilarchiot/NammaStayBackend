-- Let NammaStay platform admins delete room inventory and extras even when
-- their membership role does not have the manage_rooms permission.
create or replace function public._perm_rooms() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' and public.is_platform_admin() then return old; end if;
  perform public._require_perm(coalesce(new.property_id, old.property_id), 'manage_rooms');
  return coalesce(new, old);
end $$;

drop policy if exists rooms_admin_delete on public.rooms;
create policy rooms_admin_delete on public.rooms for delete to authenticated
  using (public.is_platform_admin());

drop policy if exists beds_admin_delete on public.beds;
create policy beds_admin_delete on public.beds for delete to authenticated
  using (public.is_platform_admin());

drop policy if exists blocks_admin_delete on public.bed_blocks;
create policy blocks_admin_delete on public.bed_blocks for delete to authenticated
  using (public.is_platform_admin());

drop policy if exists extras_admin_delete on public.extra_items;
create policy extras_admin_delete on public.extra_items for delete to authenticated
  using (public.is_platform_admin());
