-- Undo 046 (OTA sync through Beds24). Removes its tables, trigger and functions, and the Beds24 channel with its
-- connections. Bookings already created from OTA reservations stay (they are normal NammaStay bookings).
-- 045 (NammaStay Connect) keeps working.
drop trigger if exists cn_kick on public.cn_connections;
drop function if exists public._cn_kick(), public._b24_status_json(uuid, boolean),
  public.cn_b24_status(uuid), public.cn_b24_pay(uuid, text), public.cn_b24_owner_step(uuid, text, boolean), public.cn_b24_cancel(uuid),
  public.cn_b24_can_link(uuid, boolean), public.cn_b24_queue(), public.cn_b24_admin_pay(uuid, text, boolean, text), public.cn_b24_admin_set(uuid, jsonb),
  public.cn_b24_admin_map(uuid, jsonb), public.cn_b24_admin_go_live(uuid), public.cn_admin_check(uuid),
  public.cn_b24_link_save(uuid, text, boolean, uuid), public.cn_b24_propinfo(uuid), public.cn_b24_automap(uuid, jsonb), public.cn_secret_get(uuid),
  public.cn_secret_set(uuid, text, text, timestamptz), public.cn_b24_hook(uuid, text), public.cn_b24_conn(uuid),
  public.cn_res_known(uuid, text[]), public.cn_lease(uuid, int), public.cn_release(uuid), public.cn_is_dirty(uuid), public.cn_b24_expire();
drop table if exists public.cn_leases, public.cn_kicks, public.cn_secrets, public.cn_b24_setup, public.cn_settings;
delete from public.cn_connections where ota = 'beds24';
delete from public.cn_otas where ota = 'beds24';
alter table public.cn_otas drop constraint if exists cn_otas_ota_check;
alter table public.cn_otas add constraint cn_otas_ota_check check (ota ~ '^[a-z]{2,20}$');
