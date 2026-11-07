-- =====================================================================
-- NammaStay · 051 — a room (or price group) that no longer exists must leave the OTA sync too.
-- cx_prune: drops map rows whose room / price group is gone, refreshes the beds of the ones that stay,
-- and returns the Channex ids of the dropped ones so the edge function can remove them from Channex.
-- Run once in Supabase → SQL Editor. Undo: drop function public.cx_prune(uuid);
-- =====================================================================
create or replace function public.cx_prune(p_property uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_gone jsonb;
begin
  with live as (select g->>'group_key' as group_key, g->>'title' as title, g->'bed_ids' as bed_ids
                  from jsonb_array_elements(public.cx_groups(p_property)) g),
  gone as (
    delete from public.channex_room_map m
     where m.property_id = p_property and not exists (select 1 from live l where l.group_key = m.group_key)
     returning m.cx_room_type_id, m.cx_rate_plan_id)
  select coalesce(jsonb_agg(jsonb_build_object('cx_room_type_id', cx_room_type_id, 'cx_rate_plan_id', cx_rate_plan_id)), '[]'::jsonb)
    into v_gone from gone;
  update public.channex_room_map m
     set title = l.title, bed_ids = array(select (x)::uuid from jsonb_array_elements_text(l.bed_ids) x)
    from (select g->>'group_key' as group_key, g->>'title' as title, g->'bed_ids' as bed_ids
            from jsonb_array_elements(public.cx_groups(p_property)) g) l
   where m.property_id = p_property and m.group_key = l.group_key;
  return v_gone;
end $$;
revoke execute on function public.cx_prune(uuid) from public, anon, authenticated;
grant execute on function public.cx_prune(uuid) to service_role;
