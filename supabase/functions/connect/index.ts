// NammaStay · connect — NammaStay Connect, NammaStay's own OTA connectivity (045) + OTA sync through Beds24 (046)
//   POST {action:"rooms", connection_id}                        owner/manager → fetch the OTA's room types & rate plans for matching
//   POST {action:"sync",  connection_id}                        owner/manager → pull reservations + send changed availability/prices now
//   POST {action:"link",  property_id, code, b24_property_id?, own?}  NammaStay admin (managed "Do it for me") or owner (own: their Beds24)
//                                                                 → link Beds24 with an invite code, build the rooms, match them
//   POST {} + header x-cron-secret          every minute: every live connection — pull, then push what changed
//                                             (a full 365-day refresh once a day; failures back off 2→64 min)
//   POST {kick: connection_id} + x-cron-secret   from the database (046) the moment beds/prices change → send now
//   GET|POST ?hook=beds24&c=<connection>&k=<key>  Beds24 booking webhook → read bookings now
// Adapters per OTA are in adapters.ts. "Test OTA" is a built-in simulator; real OTAs work once that OTA has
// approved NammaStay and its credentials are added as secrets (and a NammaStay admin switches it on).
// Secrets: CRON_SECRET (+ BEDS24_API only to point at a test server). Deploy: supabase functions deploy connect --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";
import { adapterFor, b24CreateRooms, b24Exchange, b24Properties, b24RoomName, b24SaveTokens, type Conn, type Night, type NormRes } from "./adapters.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SECRET = Deno.env.get("CRON_SECRET") ?? "";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const msg = (e: unknown) => (e instanceof Error ? e.message : String(e));
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}
const log = (id: string, dir: "out" | "in" | "info", kind: string, ok: boolean, summary: string, detail?: unknown) =>
  rpc("cn_log_add", { p_connection: id, p_dir: dir, p_kind: kind, p_ok: ok, p_summary: summary.slice(0, 300),
    p_detail: detail === undefined ? null : (typeof detail === "string" ? detail : JSON.stringify(detail)).slice(0, 20000) }).catch(() => {});

// ---------------------------------------------------------------- one connection: pull, then push (one run at a time)
type SyncOut = { imported: number; problems: string[]; nights_sent: number; skipped?: boolean; reason?: string };
async function syncOne(id: string, opts: { push: boolean; full: boolean }): Promise<SyncOut> {
  if (!(await rpc("cn_lease", { p_connection: id, p_seconds: 120 }).catch(() => true))) {     // (no lease table before 046 → just run)
    return { skipped: true, reason: "A sync is already running for this connection — it picks up the latest changes.", imported: 0, problems: [], nights_sent: 0 };
  }
  try {
    const out = await syncInner(id, opts);
    // changes that arrived while this run was busy: send them now rather than next minute (at most twice more)
    for (let i = 0; i < 2 && !out.skipped && (await rpc("cn_is_dirty", { p_connection: id }).catch(() => false)); i++) {
      const more = await syncInner(id, { push: true, full: false }, true);
      out.nights_sent += more.nights_sent;
    }
    return out;
  } finally {
    await rpc("cn_release", { p_connection: id }).catch(() => {});
  }
}

async function syncInner(id: string, opts: { push: boolean; full: boolean }, pushOnly = false): Promise<SyncOut> {
  const c = (await rpc("cn_conn", { p_connection: id })) as Conn | null;
  if (!c) throw new Error("Connection not found.");
  if (c.status !== "live" || !c.ota_enabled) {
    return { skipped: true, imported: 0, problems: [], nights_sent: 0,
      reason: c.status === "paused" ? "Paused." : c.status === "setup" ? "Match rooms and go live first." : "Waiting — this OTA isn’t switched on for NammaStay yet." };
  }
  const ad = adapterFor(c.ota, rpc);
  const out: SyncOut = { imported: 0, problems: [], nights_sent: 0 };

  // 1. reservations in
  if (!pushOnly) {
    try {
      const list = (await ad.pull(c)) as NormRes[];
      const saved: string[] = [];
      for (const r of list) {
        try {
          const res = (await rpc("cn_import", { p_connection: c.id, p_res: r })) as { problem?: string; duplicate?: boolean };
          saved.push(r.res_id); if (!res?.duplicate) out.imported++;
          if (res?.problem) out.problems.push(res.problem);
        } catch (e) { out.problems.push(msg(e)); await log(c.id, "in", "reservation", false, `Couldn’t save ${r.res_id}: ${msg(e)}`, r); }   // not confirmed → the OTA sends it again
      }
      if (saved.length) {
        await ad.confirm(c, saved);
        await rpc("cn_res_confirmed", { p_connection: c.id, p_res_ids: saved });
        await log(c.id, "out", "confirm", true, `Confirmed ${saved.length} reservation(s) to the OTA`, saved);
      }
      await rpc("cn_mark", { p_connection: c.id, p_kind: "pull", p_error: null });
    } catch (e) {
      await rpc("cn_mark", { p_connection: c.id, p_kind: "pull", p_error: msg(e) });
      await log(c.id, "in", "pull", false, `Reading reservations failed: ${msg(e)}`);
      throw e;
    }
  }

  // 2. availability, price, minimum stay out (only nights that changed, unless full)
  if (opts.push || out.imported > 0) {                                  // a reservation just changed availability: send it now, not next minute
    try {
      const nights = (await rpc("cn_ari_changes", { p_connection: c.id, p_days: 365, p_full: opts.full })) as Night[];
      if (nights.length) {
        const r = await ad.push(c, nights);
        await log(c.id, "out", "ari", true, `Sent ${nights.length} night(s) in ${r.messages} message(s)${opts.full ? " — full refresh" : ""}`, nights.slice(0, 60));
      }
      await rpc("cn_ari_ack", { p_connection: c.id, p_rows: nights, p_full: opts.full });
      out.nights_sent = nights.length;
    } catch (e) {
      await rpc("cn_mark", { p_connection: c.id, p_kind: "push", p_error: msg(e) });
      await log(c.id, "out", "ari", false, `Sending availability failed: ${msg(e)}`);
      throw e;
    }
  }
  return out;
}

// ---------------------------------------------------------------- Beds24: link an account with an invite code (046)
async function b24Link(propertyId: string, code: string, wantId: string | null, managed: boolean) {
  code = code.trim();
  if (!/^[A-Za-z0-9._~+\/=-]{8,600}$/.test(code)) throw new Error("Paste the invite code from Beds24 → Settings → Marketplace → API.");
  if (wantId !== null && !/^[0-9]{1,12}$/.test(wantId)) throw new Error("The Beds24 property ID is numbers only.");
  const info = (await rpc("cn_b24_propinfo", { p_property: propertyId })) as { name: string; groups: { title: string; units: number }[] } | null;
  if (!info) throw new Error("Property not found.");
  const t = await b24Exchange(code);
  let props = await b24Properties(t.token);
  let p = wantId ? props.find((x) => String(x.id) === wantId) : props.length === 1 ? props[0] : undefined;
  if (wantId && !p) throw new Error(`Beds24 property ${wantId} isn’t in this Beds24 account.`);
  if (!p && props.length > 1) throw new Error(`This Beds24 account has ${props.length} properties — enter the Beds24 property ID to link.`);
  let created = 0;
  if (!p) {                                                              // empty account (a new sub-account): create the property with the rooms
    const newId = await b24CreateRooms(t.token, null, info.name, info.groups);
    props = await b24Properties(t.token);
    p = props.find((x) => String(x.id) === newId) ?? props.find((x) => (x.name ?? "").trim() === info.name.trim().slice(0, 60)) ?? props[0];
    if (!p) throw new Error("Beds24 didn’t create the property. Create it in Beds24, then link again.");
    created = (p.roomTypes ?? []).length;
  }
  const connId = (await rpc("cn_b24_link_save", { p_property: propertyId, p_b24_property: String(p.id), p_managed: managed, p_by: null })) as string;
  await b24SaveTokens(rpc, connId, t);
  if (!(p.roomTypes ?? []).length) {                                     // property without rooms: create one Beds24 room per NammaStay room type
    await b24CreateRooms(t.token, String(p.id), info.name, info.groups);
    [p] = await b24Properties(t.token, String(p.id));
    created = (p?.roomTypes ?? []).length;
  }
  const rooms = (p?.roomTypes ?? []).map((r) => ({ ota_room_id: String(r.id), ota_rate_id: "",
    room_name: `${r.name || "Room " + r.id}${r.qty ? ` · ${r.qty} unit${r.qty === 1 ? "" : "s"}` : ""}` }));
  await rpc("cn_rooms_save", { p_connection: connId, p_rooms: rooms });
  // match by name: rooms NammaStay just created carry the room type's name
  const conn = (await rpc("cn_conn", { p_connection: connId })) as Conn;
  const maps = conn.groups.filter((g) => !g.ota_room_id && g.units > 0).map((g) => {
    const r = (p?.roomTypes ?? []).find((x) => b24RoomName(x.name ?? "").toLowerCase() === b24RoomName(g.title).toLowerCase());
    return r ? { group_key: g.group_key, ota_room_id: String(r.id) } : null;
  }).filter(Boolean);
  const auto = maps.length ? ((await rpc("cn_b24_automap", { p_connection: connId, p_maps: maps })) as number) : 0;
  const after = (await rpc("cn_conn", { p_connection: connId })) as Conn;
  const groups = after.groups.filter((g) => g.units > 0);
  const mapped = groups.filter((g) => g.ota_room_id).length;
  await log(connId, "in", "link", true, `Beds24 property ${p!.id} linked · ${rooms.length} room(s)${created ? `, ${created} created by NammaStay` : ""} · ${mapped}/${groups.length} matched`, rooms);
  return { connection_id: connId, b24_property_id: String(p!.id), b24_property_name: p!.name ?? "", rooms: rooms.length, created, auto_matched: auto, mapped, groups: groups.length };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);

  // -------- Beds24 booking webhook: right connection + key → read bookings now
  if (url.searchParams.get("hook") === "beds24") {
    const id = url.searchParams.get("c") ?? "";
    if (!UUID.test(id)) return json({ error: "Unknown connection." }, 404);
    const ok = await rpc("cn_b24_hook", { p_connection: id, p_key: url.searchParams.get("k") ?? "" }).catch(() => false);
    if (ok !== true) return json({ error: "Not allowed." }, 403);
    try { return json({ ok: true, ...(await syncOne(id, { push: false, full: false })) }); }
    catch (e) { return json({ ok: false, error: msg(e) }); }                // 200: the every-minute run retries; Beds24 needn't
  }

  // -------- cron (every minute) and instant "send now" pings from the database
  if (SECRET && req.headers.get("x-cron-secret") === SECRET) {
    const body = await req.json().catch(() => ({}));
    if (body?.kick) {
      if (!UUID.test(String(body.kick))) return json({ error: "Unknown connection." }, 404);
      try { return json({ ok: true, kick: body.kick, ...(await syncOne(String(body.kick), { push: true, full: false })) }); }
      catch (e) { return json({ ok: false, kick: body.kick, error: msg(e) }); }
    }
    await rpc("cn_b24_expire", {}).catch(() => 0);                         // managed OTA sync unpaid > 3 days past due → pause
    const due = ((await rpc("cn_due", {})) || []) as { id: string; push: boolean; full: boolean }[];
    const out: unknown[] = [];
    for (const d of due) {
      try { out.push({ id: d.id, ...(await syncOne(d.id, { push: d.push, full: d.full })) }); }
      catch (e) { out.push({ id: d.id, error: msg(e) }); }
    }
    return json({ ok: true, connections: due.length, out });
  }

  // -------- signed-in staff
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Please sign in." }, 401);
  const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const body = await req.json().catch(() => ({}));

  if (body.action === "link") {                                            // Beds24 invite code (046)
    if (!UUID.test(String(body.property_id ?? ""))) return json({ error: "Choose a property." }, 400);
    const { data: who, error: e1 } = await user.rpc("cn_b24_can_link", { p_property: body.property_id, p_own: body.own === true });
    if (e1 || !who) return json({ error: e1?.message || "Not allowed." }, 403);
    try {
      const wantId = body.b24_property_id === undefined || body.b24_property_id === null || String(body.b24_property_id).trim() === "" ? null : String(body.b24_property_id).trim();
      return json({ ok: true, ...(await b24Link(String(body.property_id), String(body.code ?? ""), wantId, !!(who as { managed?: boolean }).managed)) });
    } catch (e) { return json({ error: msg(e) }, 400); }
  }

  let { data: chk, error: roleErr } = await user.rpc("cn_check", { p_connection: body.connection_id });     // owner / manager of that property
  if (roleErr || !chk) {                                                                                    // …or a NammaStay admin (046)
    const a = await user.rpc("cn_admin_check", { p_connection: body.connection_id });
    if (!a.error && a.data) { chk = a.data; roleErr = null; }
  }
  if (roleErr || !chk) return json({ error: roleErr?.message || "Not allowed." }, 403);
  try {
    if (body.action === "rooms") {
      const c = (await rpc("cn_conn", { p_connection: body.connection_id })) as Conn;
      const rooms = await adapterFor(c.ota, rpc).listRooms(c);
      const n = await rpc("cn_rooms_save", { p_connection: c.id, p_rooms: rooms });
      await log(c.id, "in", "rooms", true, `OTA lists ${n} room/rate combination(s)`, rooms);
      return json({ ok: true, rooms });
    }
    if (body.action === "sync") return json({ ok: true, ...(await syncOne(body.connection_id, { push: true, full: !!body.full })) });
    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    return json({ error: msg(e) }, 400);
  }
});
