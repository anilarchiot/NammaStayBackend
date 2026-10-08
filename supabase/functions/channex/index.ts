// NammaStay · channex — two-way channel manager through Channex (white-label API)
//   POST {action:"setup", property_id, cx_property_id?}  owner/manager → create/link Channex property, room types, rate plans; first full push
//   POST {action:"sync",  property_id}                   owner/manager → pull OTA bookings + push availability & prices now
//   POST {action:"iframe", property_id}                  owner/manager → link to Channex's "connect OTAs" screen (shown inside NammaStay)
//   POST {} + header x-cron-secret                        every few minutes: pull bookings for all, push where something changed
// Secrets: CHANNEX_API_KEY, CHANNEX_URL (default https://staging.channex.io), CRON_SECRET.
// Deploy: supabase functions deploy channex --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CX = (Deno.env.get("CHANNEX_URL") ?? "https://staging.channex.io").replace(/\/$/, "");
const KEY = Deno.env.get("CHANNEX_API_KEY") ?? "";
const SECRET = Deno.env.get("CRON_SECRET") ?? "";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function cx(path: string, init: RequestInit = {}) {
  if (!KEY) throw new Error("Channex isn’t set up on the server yet (CHANNEX_API_KEY secret missing).");
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
  const known = Object.fromEntries((d.maps || []).map((m: { group_key: string }) => [m.group_key, m]));
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

// ---------------------------------------------------------------- push availability + prices + minimum stay (date ranges)
type Night = { room_type_id: string; rate_plan_id: string; date: string; availability: number; rate: number; min_stay: number };
// Merge consecutive nights that send the same values into one date range (fewer, smaller API calls)
function ranges<T extends Record<string, unknown>>(rows: Night[], value: (n: Night) => T) {
  const out: (T & { date_from: string; date_to: string })[] = []; let lastKey = "";
  const next = (dt: string) => { const x = new Date(dt + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + 1); return x.toISOString().slice(0, 10); };
  for (const n of rows) {
    const v = value(n); const k = JSON.stringify(v); const last = out[out.length - 1];
    if (last && k === lastKey && next(last.date_to) === n.date) last.date_to = n.date;
    else { out.push({ ...v, date_from: n.date, date_to: n.date }); lastKey = k; }
  }
  return out;
}
async function push(propertyId: string, cxProp: string) {
  const { data, error } = await admin.rpc("cx_ari", { p_property: propertyId, p_days: 500 });
  if (error) throw new Error(error.message);
  const nights = (data || []) as Night[];
  const byRoom = [...nights].sort((a, b) => a.room_type_id.localeCompare(b.room_type_id) || a.date.localeCompare(b.date));
  const avail = ranges(byRoom, (n) => ({ property_id: cxProp, room_type_id: n.room_type_id, availability: n.availability }));
  const rates = ranges(byRoom, (n) => ({ property_id: cxProp, rate_plan_id: n.rate_plan_id, rate: rp(n.rate), min_stay_arrival: n.min_stay }));
  for (let i = 0; i < avail.length; i += 500) await cx("/availability", { method: "POST", body: JSON.stringify({ values: avail.slice(i, i + 500) }) });
  for (let i = 0; i < rates.length; i += 500) await cx("/restrictions", { method: "POST", body: JSON.stringify({ values: rates.slice(i, i + 500) }) });
  await admin.rpc("cx_mark", { p_property: propertyId, p_kind: "push", p_error: null });
  return { availability_updates: avail.length, price_updates: rates.length };
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
