// NammaStay · channex — two-way channel manager through Channex (white-label API)
//   POST {action:"setup", property_id, cx_property_id?}  owner/manager → create/link Channex property, room types, rate plans; first full push
//   POST {action:"sync",  property_id}                   owner/manager → pull OTA bookings + push availability & prices now
//   POST {action:"pull", property_id}                    owner/manager → check Channex for new / changed bookings only
//   POST {action:"plans", property_id}                   owner/manager → room types and rate plans as they are in Channex
//   POST {action:"restrictions", property_id, rows}      owner/manager → ONE Channex call with only the changed rate / min stay / stop sell values (ari.ts)
//   POST {action:"availability", property_id, rows}      owner/manager → ONE Channex call with the changed availability
//   POST {action:"iframe", property_id}                  owner/manager → link to Channex's "connect OTAs" screen (shown inside NammaStay)
//   POST {} + header x-cron-secret                        every few minutes: pull bookings for all, push where something changed
//   POST {action:"key_test"}                             NammaStay admin → check the saved Channex key works (044)
// Channex key: saved by a NammaStay admin in Admin → Channel manager (044, table cx_settings);
//   if none is saved, the secrets CHANNEX_API_KEY / CHANNEX_URL are used (default https://staging.channex.io). Also CRON_SECRET.
// Deploy: supabase functions deploy channex --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";
import { availabilityValues, fullSyncValues, responseWarnings, restrictionValues, type Night } from "./ari.ts";
const FULL_SYNC_BATCH = 2000;

const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const ENV_CX = (Deno.env.get("CHANNEX_URL") ?? "https://staging.channex.io").replace(/\/$/, "");
const ENV_KEY = Deno.env.get("CHANNEX_API_KEY") ?? "";
let CX = ENV_CX; let KEY = ENV_KEY;
// Key saved from the admin screen (044) wins over the secrets; read fresh on every request.
async function loadKey() {
  CX = ENV_CX; KEY = ENV_KEY;
  const { data, error } = await admin.rpc("_cx_key");
  if (!error && data?.api_key) { KEY = String(data.api_key); CX = String(data.base_url || ENV_CX).replace(/\/$/, ""); }
}
const SECRET = Deno.env.get("CRON_SECRET") ?? "";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function cx(path: string, init: RequestInit = {}) {
  if (!KEY) throw new Error("Channex isn’t switched on yet — an admin from TheNammaStay adds the API key in Admin → Channel manager.");
  const r = await fetch(CX + "/api/v1" + path, { ...init, headers: { "Content-Type": "application/json", "user-api-key": KEY, ...(init.headers ?? {}) } });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) {
    const d = body?.errors?.details; const msg = body?.errors?.title || `Channex error ${r.status}`;
    throw new Error(d ? `${msg}: ${typeof d === "string" ? d : JSON.stringify(d)}` : msg);
  }
  return body;
}
const rp = (v: number) => Math.max(0, Math.round(v));                 // paise (Channex takes the minimum currency unit)

// ---------------------------------------------------------------- setup: property + one room type & rate plan per group
async function setup(propertyId: string, existingCx?: string) {
  const { data: d, error } = await admin.rpc("cx_setup_data", { p_property: propertyId });
  if (error || !d) throw new Error(error?.message || "Property not found.");
  let cxProp = existingCx || d.link?.cx_property_id;
  if (!cxProp) {
    const res = await cx("/properties", { method: "POST", body: JSON.stringify({ property: {
      title: d.property.name, currency: "INR", country: "IN", timezone: d.property.timezone || "Asia/Kolkata",
      email: d.property.email || undefined, phone: d.property.phone || undefined, city: d.property.city || undefined, address: d.property.address || undefined } }) });
    cxProp = res.data.id;
  }
  const replacingProperty = !!d.link?.cx_property_id && d.link.cx_property_id !== cxProp;
  const known = Object.fromEntries((replacingProperty ? [] : d.maps || []).map((m: { group_key: string }) => [m.group_key, m]));
  const maps = [];
  for (const g of d.groups) {
    const m = known[g.group_key] || {};
    let rt = m.cx_room_type_id; let rpId = m.cx_rate_plan_id;
    if (!rt) {
      const res = await cx("/room_types", { method: "POST", body: JSON.stringify({ room_type: {
        property_id: cxProp, title: g.title, count_of_rooms: g.count, occ_adults: g.occ_adults, occ_children: 0, occ_infants: 0,
        default_occupancy: Math.min(g.default_occupancy, g.occ_adults), room_kind: g.room_kind, capacity: g.room_kind === "dorm" ? g.capacity : null } }) });
      rt = res.data.id;
    } else {
      await cx(`/room_types/${rt}`, { method: "PUT", body: JSON.stringify({ room_type: { title: g.title, count_of_rooms: g.count, occ_adults: g.occ_adults,
        occ_children: 0, occ_infants: 0, default_occupancy: Math.min(g.default_occupancy, g.occ_adults) } }) }).catch(() => {});
    }
    if (!rpId) {
      const res = await cx("/rate_plans", { method: "POST", body: JSON.stringify({ rate_plan: {
        title: `${g.title} — Standard`.slice(0, 255), property_id: cxProp, room_type_id: rt, currency: "INR", sell_mode: "per_room", rate_mode: "manual",
        options: [{ occupancy: g.occ_adults, is_primary: true, rate: rp(g.rate_paise) }] } }) });
      rpId = res.data.id;
    }
    maps.push({ ...g, cx_room_type_id: rt, cx_rate_plan_id: rpId });
  }
  const { error: e2 } = await admin.rpc("cx_save_setup", { p_property: propertyId, p_cx_property: cxProp, p_maps: maps });
  if (e2) throw new Error(e2.message);
  return { cx_property_id: cxProp, rooms: maps.length };
}

// ---------------------------------------------------------------- push availability + prices + restrictions
// Builders live in ari.ts (unit-tested against the Channex certification scenarios).
async function post(path: "/availability" | "/restrictions", values: unknown[]) {
  const res = await cx(path, { method: "POST", body: JSON.stringify({ values }) });
  const warnings = responseWarnings(res);
  if (warnings.length) throw new Error(`Channex rejected part of the update: ${warnings.slice(0, 3).join("; ")}`);   // 200 OK can still carry rejected values
}
// Full sync: every restriction (rate, min stay, stop sell) and availability for the next days, one call per kind.
// Rooms deleted (or regrouped) in NammaStay: forget them and take them off Channex too, so they stop being sold.
async function pruneDeleted(propertyId: string, cxProp: string) {
  const { data } = await admin.rpc("cx_prune", { p_property: propertyId });
  for (const g of (data || []) as { cx_room_type_id?: string; cx_rate_plan_id?: string }[]) {
    if (g.cx_rate_plan_id) await cx(`/rate_plans/${g.cx_rate_plan_id}`, { method: "DELETE" }).catch(() => {});
    if (g.cx_room_type_id) {
      await cx(`/room_types/${g.cx_room_type_id}`, { method: "DELETE" }).catch(async () => {
        // Channex won't delete a room type that has bookings: close it instead (0 available).
        const days = Array.from({ length: 500 }, (_, i) => new Date(Date.now() + i * 864e5).toISOString().slice(0, 10));
        await post("/availability", [{ property_id: cxProp, room_type_id: g.cx_room_type_id, date_from: days[0], date_to: days[499], availability: 0 }]).catch(() => {});
      });
    }
  }
}

async function push(propertyId: string, cxProp: string) {
  await pruneDeleted(propertyId, cxProp);
  const { data, error } = await admin.rpc("cx_ari", { p_property: propertyId, p_days: 500 });
  if (error) throw new Error(error.message);
  // Rooms mapped to a different / deleted Channex property make Channex answer "Not found room_type": send only what exists there.
  const { rooms, plans } = await channexPlans(cxProp);
  const roomIds = new Set(rooms.map((r: { id: string }) => r.id));
  const planIds = new Set(plans.map((p: { id: string }) => p.id));
  const nights = ((data || []) as Night[]).filter((n) => roomIds.has(n.room_type_id) && planIds.has(n.rate_plan_id));
  if (!nights.length && (data || []).length) {
    throw new Error("None of your NammaStay rooms are linked to room types in this Channex property. Tap “Update rooms”, or use the Channex screen for rates and availability.");
  }
  const { availability, restrictions } = fullSyncValues(cxProp, nights);
  for (let i = 0; i < availability.length; i += FULL_SYNC_BATCH) await post("/availability", availability.slice(i, i + FULL_SYNC_BATCH));
  for (let i = 0; i < restrictions.length; i += FULL_SYNC_BATCH) await post("/restrictions", restrictions.slice(i, i + FULL_SYNC_BATCH));
  await admin.rpc("cx_mark", { p_property: propertyId, p_kind: "push", p_error: null });
  return { availability_updates: availability.length, price_updates: restrictions.length };
}

// Rate plans and room types as they exist in Channex (for the rates / availability screen).
async function channexPlans(cxProp: string) {
  const [rt, rpl] = await Promise.all([
    cx(`/room_types?filter[property_id]=${cxProp}&pagination[limit]=200`),
    cx(`/rate_plans?filter[property_id]=${cxProp}&pagination[limit]=200`),
  ]);
  const rooms = (rt.data || []).map((r: { id: string; attributes?: { title?: string } }) => ({ id: r.id, title: r.attributes?.title || r.id }));
  const title = Object.fromEntries(rooms.map((r: { id: string; title: string }) => [r.id, r.title]));
  const plans = (rpl.data || []).map((p: { id: string; attributes?: { title?: string; room_type_id?: string; currency?: string } }) => ({
    id: p.id, title: p.attributes?.title || p.id, room_type_id: p.attributes?.room_type_id || "", room: title[p.attributes?.room_type_id || ""] || "", currency: p.attributes?.currency || "",
  }));
  return { rooms, plans };
}

// ---------------------------------------------------------------- pull OTA bookings (feed) → NammaStay, then acknowledge
async function pull(cxProp?: string) {
  let saved = 0; const problems: string[] = [];
  for (let page = 0; page < 10; page++) {
    const q = `/booking_revisions/feed?order[inserted_at]=asc${cxProp ? `&filter[property_id]=${cxProp}` : ""}`;
    const res = await cx(q);
    const list = res.data || [];
    if (!list.length) break;
    for (const rev of list) {
      const a = rev.attributes || {};
      const { data: pid } = await admin.rpc("cx_property_for", { p_cx_property: a.property_id });
      if (!pid) continue;                                              // not ours / switched off: leave unacknowledged
      const { data: r, error } = await admin.rpc("cx_import", { p_property: pid, p_rev: { ...a, revision_id: rev.id } });
      if (error) { problems.push(error.message); continue; }           // not saved → don't ack; Channex will send it again
      await cx(`/booking_revisions/${rev.id}/ack`, { method: "POST" });
      saved++; if (r?.problem) problems.push(r.problem);
    }
    if (list.length < 10) break;
  }
  return { saved, problems };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  await loadKey();
  // -------- cron
  if (SECRET && req.headers.get("x-cron-secret") === SECRET) {
    const out: unknown[] = [];
    try { out.push({ pull: await pull() }); } catch (e) { out.push({ pull_error: String(e) }); }
    const { data: due } = await admin.rpc("cx_links_due");
    for (const l of due || []) {
      if (!l.push) continue;
      try { out.push({ property: l.property_id, ...(await push(l.property_id, l.cx_property_id)) }); }
      catch (e) { await admin.rpc("cx_mark", { p_property: l.property_id, p_kind: "push", p_error: String(e instanceof Error ? e.message : e) }); }
    }
    return json({ ok: true, out });
  }
  // -------- staff
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Please sign in." }, 401);
  const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const body = await req.json().catch(() => ({}));
  if (body.action === "key_test") {                                                    // TheNammaStay admins only (044)
    const { data: isAdmin } = await user.rpc("is_platform_admin");
    if (isAdmin !== true) return json({ error: "Only TheNammaStay admins can do this." }, 403);
    try {
      const r = await cx("/properties?pagination[page]=1&pagination[limit]=100");
      return json({ ok: true, live: CX.includes("app.channex.io"), properties: (r.data || []).map((p: { id: string; attributes?: { title?: string } }) => ({ id: p.id, title: p.attributes?.title || "" })) });
    } catch (e) { return json({ error: e instanceof Error ? e.message : String(e) }, 400); }
  }
  const { error: roleErr } = await user.rpc("cx_status", { p_property: body.property_id });     // owner / manager only
  if (roleErr) return json({ error: roleErr.message }, 403);
  try {
    if (body.action === "setup") {
      const s = await setup(body.property_id, body.cx_property_id || undefined);
      const p = await push(body.property_id, s.cx_property_id);
      return json({ ok: true, ...s, ...p });
    }
    const { data: d } = await admin.rpc("cx_setup_data", { p_property: body.property_id });
    const cxProp = d?.link?.cx_property_id;
    if (!cxProp) throw new Error("Set up the channel manager first.");
    if (body.action === "sync") {
      const pulled = await pull(cxProp);
      await admin.rpc("cx_mark", { p_property: body.property_id, p_kind: "pull", p_error: null });
      const pushed = await push(body.property_id, cxProp);
      return json({ ok: true, ...pulled, ...pushed });
    }
    if (body.action === "plans") return json({ ok: true, cx_property_id: cxProp, ...(await channexPlans(cxProp)) });
    if (body.action === "pull") {
      const pulled = await pull(cxProp);
      await admin.rpc("cx_mark", { p_property: body.property_id, p_kind: "pull", p_error: null });
      return json({ ok: true, ...pulled });
    }
    // One save = one Channex call containing only the values that were changed.
    if (body.action === "restrictions") {
      await post("/restrictions", restrictionValues(cxProp, body.rows));
      await admin.rpc("cx_mark", { p_property: body.property_id, p_kind: "push", p_error: null });
      return json({ ok: true, sent: body.rows.length });
    }
    if (body.action === "availability") {
      await post("/availability", availabilityValues(cxProp, body.rows));
      await admin.rpc("cx_mark", { p_property: body.property_id, p_kind: "push", p_error: null });
      return json({ ok: true, sent: body.rows.length });
    }
    if (body.action === "iframe") {
      const t = await cx("/auth/one_time_token", { method: "POST", body: JSON.stringify({ one_time_token: { property_id: cxProp } }) });
      const token = t?.data?.token;
      if (!token) throw new Error("Channex didn’t return a token.");
      return json({ url: `${CX}/auth/exchange?oauth_session_key=${encodeURIComponent(token)}&app_mode=headless&redirect_to=/channels&property_id=${cxProp}` });
    }
    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await admin.rpc("cx_mark", { p_property: body.property_id, p_kind: "push", p_error: msg });
    return json({ error: msg }, 400);
  }
});
