-- Replacing a property's Channex ID also replaces its room/rate-plan mappings.
create or replace function public.cx_save_setup(p_property uuid, p_cx_property text, p_maps jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g jsonb;
begin
  if exists (
    select 1 from public.channex_links
     where property_id = p_property and cx_property_id is distinct from p_cx_property
  ) then
    delete from public.channex_room_map where property_id = p_property;
  end if;

  insert into public.channex_links (property_id, cx_property_id, enabled, dirty_at) values (p_property, p_cx_property, true, now())
  on conflict (property_id) do update set cx_property_id = excluded.cx_property_id, enabled = true, dirty_at = now(), last_error = null;
  for g in select * from jsonb_array_elements(coalesce(p_maps, '[]'::jsonb)) loop
    insert into public.channex_room_map (property_id, group_key, room_id, rate_paise, title, bed_ids, cx_room_type_id, cx_rate_plan_id)
    values (p_property, g->>'group_key', (g->>'room_id')::uuid, (g->>'rate_paise')::int, g->>'title',
            array(select (x)::uuid from jsonb_array_elements_text(g->'bed_ids') x), g->>'cx_room_type_id', g->>'cx_rate_plan_id')
    on conflict (property_id, group_key) do update set title = excluded.title, bed_ids = excluded.bed_ids,
       cx_room_type_id = coalesce(excluded.cx_room_type_id, public.channex_room_map.cx_room_type_id),
       cx_rate_plan_id = coalesce(excluded.cx_rate_plan_id, public.channex_room_map.cx_rate_plan_id);
  end loop;
end $$;
