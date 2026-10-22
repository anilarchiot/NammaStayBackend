-- Undo 045 (NammaStay Connect). Removes its tables, triggers and functions. Bookings already created from OTA
-- reservations stay (they are normal NammaStay bookings). Channex (027) and iCal sync (020) are not touched.
do $$ declare t text; begin
  foreach t in array array['bookings','bed_blocks','rate_rules','beds'] loop
    execute format('drop trigger if exists cn_touch on public.%I', t);
  end loop;
end $$;
drop function if exists public._cn_touch(), public._cn_conn_role(uuid, public.member_role[]), public._cn_sync_groups(uuid),
  public.cn_status(uuid), public.cn_save_connection(uuid, text, text), public.cn_save_map(uuid, jsonb), public.cn_go_live(uuid),
  public.cn_pause(uuid, boolean), public.cn_resync(uuid), public.cn_delete(uuid), public.cn_check(uuid),
  public.cn_admin_overview(), public.cn_admin_log(uuid, int), public.cn_admin_set_ota(text, boolean), public.cn_admin_retry(uuid),
  public.cn_admin_sim_view(uuid, int), public.cn_admin_sim_booking(uuid, jsonb),
  public.cn_due(), public.cn_conn(uuid), public.cn_ari_changes(uuid, int, boolean), public.cn_ari_ack(uuid, jsonb, boolean),
  public.cn_mark(uuid, text, text), public.cn_log_add(uuid, text, text, boolean, text, text), public.cn_rooms_save(uuid, jsonb),
  public.cn_import(uuid, jsonb), public.cn_res_confirmed(uuid, text[]),
  public.cn_sim_push(uuid, jsonb), public.cn_sim_pull(uuid), public.cn_sim_confirm(uuid, text[]), public.cn_sim_rooms(uuid);
drop table if exists public.cn_sim_res, public.cn_sim_ari, public.cn_log, public.cn_reservations, public.cn_ari_sent,
  public.cn_ota_rooms, public.cn_room_map, public.cn_connections, public.cn_otas;
