// NammaStay Connect · OTA adapters. Every OTA speaks its own language; each adapter turns it into
// the same four operations so the rest of NammaStay never needs to know which OTA it is talking to.
//
//   listRooms(conn)        → the OTA's room types / rate plans (for the matching dropdowns)
//   push(conn, nights)     → send availability, price (paise) and minimum stay for these nights
//   pull(conn)             → new / modified / cancelled reservations, normalised (see NormRes)
//   confirm(conn, resIds)  → tell the OTA these reservations were saved in NammaStay
//
// A real OTA adapter needs that OTA's partner credentials (Supabase secrets). Until an OTA has approved
// NammaStay, its adapter explains that instead of pretending to work.

export type Conn = {
  id: string; property_id: string; ota: string; ota_hotel_id: string; status: string; ota_enabled: boolean;
  property: { name: string; timezone: string; kind: string };
  groups: { group_key: string; title: string; units: number; rate_paise: number; ota_room_id: string | null; ota_rate_id: string | null }[];
};
export type Night = { group_key: string; ota_room_id: string; ota_rate_id: string; date: string; avail: number; rate_paise: number; min_stay: number };
export type OtaRoom = { ota_room_id: string; ota_rate_id: string; room_name: string; rate_name?: string };
export type NormRes = {
  res_id: string; revision: string; status: "new" | "modified" | "cancelled"; ota_code?: string;
  customer?: { name?: string; surname?: string; phone?: string; mail?: string; country?: string };
  rooms: { ota_room_id: string; ota_rate_id?: string; checkin_date: string; checkout_date: string; amount?: number; adults?: number; is_cancelled?: boolean }[];
  amount?: number; currency?: string; arrival_date?: string; departure_date?: string; notes?: string; payment_collect?: "ota" | "property";
};
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<unknown>;
export interface Adapter {
  listRooms(c: Conn): Promise<OtaRoom[]>;
  push(c: Conn, nights: Night[]): Promise<{ messages: number }>;
  pull(c: Conn): Promise<NormRes[]>;
  confirm(c: Conn, resIds: string[]): Promise<void>;
}

// Merge consecutive nights with identical values into date ranges (OTAs prefer fewer, larger messages)
export function toRanges(nights: Night[]) {
  const out: (Omit<Night, "date"> & { date_from: string; date_to: string })[] = [];
  const next = (d: string) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + 1); return x.toISOString().slice(0, 10); };
  const sorted = [...nights].sort((a, b) => a.ota_room_id.localeCompare(b.ota_room_id) || a.ota_rate_id.localeCompare(b.ota_rate_id) || a.date.localeCompare(b.date));
  for (const n of sorted) {
    const last = out[out.length - 1];
    if (last && last.ota_room_id === n.ota_room_id && last.ota_rate_id === n.ota_rate_id && last.avail === n.avail && last.rate_paise === n.rate_paise
        && last.min_stay === n.min_stay && next(last.date_to) === n.date) last.date_to = n.date;
    else { const { date, ...rest } = n; out.push({ ...rest, date_from: date, date_to: date }); }
  }
  return out;
}

// ---------------------------------------------------------------- Test OTA (simulator, lives in the database)
export function testAdapter(rpc: Rpc): Adapter {
  return {
    async listRooms(c) { return (await rpc("cn_sim_rooms", { p_connection: c.id })) as OtaRoom[]; },
    async push(c, nights) {
      for (let i = 0; i < nights.length; i += 1000) await rpc("cn_sim_push", { p_connection: c.id, p_rows: nights.slice(i, i + 1000) });
      return { messages: Math.ceil(nights.length / 1000) };
    },
    async pull(c) { return (await rpc("cn_sim_pull", { p_connection: c.id })) as NormRes[]; },
    async confirm(c, ids) { if (ids.length) await rpc("cn_sim_confirm", { p_connection: c.id, p_res_ids: ids }); },
  };
}

// ---------------------------------------------------------------- real OTAs (switched on one by one after approval)
class NotApprovedYet extends Error {}
function pendingAdapter(otaName: string, secretNames: string[]): Adapter {
  const why = () => new NotApprovedYet(`${otaName} hasn’t approved NammaStay as a connectivity partner yet (needs the ${secretNames.join(" / ")} secrets). Keep using iCal for now.`);
  return {
    listRooms: () => Promise.reject(why()),
    push: () => Promise.reject(why()),
    pull: () => Promise.reject(why()),
    confirm: () => Promise.reject(why()),
  };
}

// Booking.com: the connector is written to Booking.com's Connectivity API (OTA XML / B.XML over HTTPS) once
// Booking.com accepts NammaStay and issues credentials (phase 2). Secrets: BOOKING_USERNAME, BOOKING_PASSWORD.
export function bookingAdapter(_rpc: Rpc): Adapter {
  const user = Deno.env.get("BOOKING_USERNAME"); const pass = Deno.env.get("BOOKING_PASSWORD");
  if (!user || !pass) return pendingAdapter("Booking.com", ["BOOKING_USERNAME", "BOOKING_PASSWORD"]);
  return pendingAdapter("Booking.com (connector build pending certification access)", ["BOOKING_USERNAME", "BOOKING_PASSWORD"]);
}

// ---------------------------------------------------------------- Beds24 (OTA sync, update 046)
// Beds24 API V2. NammaStay sends free units, price and minimum stay to a Beds24 property; Beds24 carries them to
// Booking.com, Agoda, Goibibo… and hands their bookings back. Each connection has its own Beds24 keys (cn_secrets).
// The few names Beds24's wiki doesn't spell out are kept in B24 below — check them against the Swagger docs
// (beds24.com/api/v2) before going live, and change them here only.
export const B24 = {
  base: (Deno.env.get("BEDS24_API") ?? "https://beds24.com/api/v2").replace(/\/$/, ""),
  inviteHeader: "code",             // GET /authentication/setup — the header that carries the invite code
  minStayField: "minStay",          // POST /inventory/rooms/calendar — minimum stay per date range
  changedFilter: "modifiedFrom",    // GET /bookings — "changed since"
  upcomingFilter: "departureFrom",  // GET /bookings — first read after linking: every booking not yet departed
};
export class B24Error extends Error { constructor(m: string, public status = 0) { super(m); } }
type B24Tokens = { token: string; expiresIn?: number; refreshToken?: string };
type B24Room = { id: number | string; name?: string; qty?: number };
type B24Property = { id: number | string; name?: string; roomTypes?: B24Room[] };
// deno-lint-ignore no-explicit-any
type Any = any;

const b24Msg = (d: Any): string => {
  if (!d) return "";
  if (typeof d === "string") return d.slice(0, 300);
  const e = d.error ?? d.errors ?? d.message;
  if (Array.isArray(e)) return e.map((x: Any) => x?.message ?? x?.error ?? (typeof x === "string" ? x : JSON.stringify(x))).join("; ").slice(0, 300);
  return typeof e === "string" ? e : e ? JSON.stringify(e).slice(0, 300) : "";
};
async function b24(path: string, init: { method?: string; token?: string; headers?: Record<string, string>; body?: unknown } = {}) {
  const res = await fetch(B24.base + path, {
    method: init.method ?? "GET",
    headers: { accept: "application/json", ...(init.token ? { token: init.token } : {}), ...(init.body !== undefined ? { "content-type": "application/json" } : {}), ...(init.headers ?? {}) },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  const text = await res.text();
  let data: Any = null; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  const where = `${init.method ?? "GET"} ${path.split("?")[0]}`;
  if (res.status === 429) {
    const wait = res.headers.get("x-five-min-limit-resets-in");
    throw new B24Error(`Beds24 usage limit reached — trying again shortly${wait ? ` (resets in ${wait} s)` : ""}.`, 429);
  }
  if (!res.ok) throw new B24Error(`Beds24 ${where} → ${res.status}: ${b24Msg(data) || res.statusText}`, res.status);
  if (Array.isArray(data)) {                                    // POST answers: one {success, errors, warnings…} per item sent
    const bad = data.filter((x: Any) => x && x.success === false);
    if (bad.length) throw new B24Error(`Beds24 ${where}: ${bad.map(b24Msg).join("; ").slice(0, 400) || "not accepted"}`);
  } else if (data && data.success === false) throw new B24Error(`Beds24 ${where}: ${b24Msg(data) || "not accepted"}`);
  return data;
}

// Invite code (Beds24 → Settings → Marketplace → API) → long-term refresh token + a token for the next 24 hours
export async function b24Exchange(code: string): Promise<B24Tokens> {
  const d = await b24("/authentication/setup", { headers: { [B24.inviteHeader]: code.trim() } }).catch((e) => {
    throw new B24Error(e.status === 401 || e.status === 403 || e.status === 400
      ? "Beds24 didn’t accept this invite code. Make a new one (they work for 24 hours) and paste it again." : e.message, e.status);
  });
  if (!d?.refreshToken || !d?.token) throw new B24Error("Beds24 didn’t accept this invite code. Make a new one (they work for 24 hours) and paste it again.");
  return d;
}
export async function b24SaveTokens(rpc: Rpc, connId: string, t: B24Tokens) {
  await rpc("cn_secret_set", { p_connection: connId, p_refresh: t.refreshToken ?? null, p_access: t.token,
    p_expires: new Date(Date.now() + (Number(t.expiresIn) || 3600) * 1000).toISOString() });
}
async function b24Token(rpc: Rpc, connId: string): Promise<string> {
  const s = (await rpc("cn_secret_get", { p_connection: connId })) as { refresh_token?: string; access_token?: string; access_expires_at?: string } | null;
  if (!s?.refresh_token) throw new B24Error("Beds24 isn’t linked yet — link it with an invite code.");
  if (s.access_token && s.access_expires_at && Date.parse(s.access_expires_at) > Date.now() + 5 * 60_000) return s.access_token;
  const d = await b24("/authentication/token", { headers: { refreshToken: s.refresh_token } }).catch((e) => {
    throw new B24Error(e.status === 401 || e.status === 403 ? "Beds24 refused the saved key — link Beds24 again with a new invite code." : e.message, e.status);
  });
  if (!d?.token) throw new B24Error("Beds24 refused the saved key — link Beds24 again with a new invite code.");
  await b24SaveTokens(rpc, connId, { token: d.token, expiresIn: d.expiresIn });
  return d.token;
}
export async function b24Properties(token: string, id?: string): Promise<B24Property[]> {
  const d = await b24(`/properties?includeAllRooms=true${id ? `&id=${encodeURIComponent(id)}` : ""}`, { token });
  return (Array.isArray(d) ? d : d?.data ?? []) as B24Property[];
}
// Beds24-safe room name for a NammaStay room type ("6-Bed Mixed Dorm · ₹600" → "6-Bed Mixed Dorm - Rs 600")
export const b24RoomName = (title: string) => title.replace(/\s*·\s*/g, " - ").replace(/₹\s*/g, "Rs ").replace(/[^\x20-\x7E]/g, "").replace(/\s+/g, " ").trim().slice(0, 60);
const sameName = (a: string, b: string) => b24RoomName(a).toLowerCase() === b24RoomName(b).toLowerCase();
// Create the Beds24 property (when the account has none) and/or one Beds24 room per NammaStay room type (units = beds/rooms)
export async function b24CreateRooms(token: string, propertyId: string | null, name: string, groups: { title: string; units: number }[]): Promise<string | null> {
  const roomTypes = groups.filter((g) => g.units > 0).map((g) => ({ name: b24RoomName(g.title), qty: g.units }));
  const d = await b24("/properties", { method: "POST", token,
    body: [propertyId ? { id: Number(propertyId), roomTypes } : { name: name.slice(0, 60), currency: "INR", roomTypes }] });
  const r = Array.isArray(d) ? d[0] : d;
  const id = propertyId ?? r?.new?.id ?? r?.new?.[0]?.id ?? r?.id ?? null;
  return id == null ? null : String(id);
}

const fnv = (s: string) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(36); };
const B24_SKIP = new Set(["black", "inquiry", "request"]);       // blocked dates, enquiries and unconfirmed requests are not stays
// One Beds24 booking group (bookings sharing masterId = one reservation) → NammaStay's normalised reservation
export function b24Norm(group: Any[], known: Record<string, string>): NormRes | null {
  const id = String(group[0].masterId || group[0].id);
  const live = group.filter((b) => String(b.status ?? "").toLowerCase() !== "cancelled");
  const rev = fnv(group.map((b) => [b.id, b.status, b.modifiedTime ?? b.modified ?? b.bookingTime ?? "", b.arrival, b.departure, b.roomId, b.price, b.numAdult].join(":")).sort().join("|"));
  const seen = Object.prototype.hasOwnProperty.call(known, id);
  if (!live.length && !seen) return null;                           // cancelled before NammaStay ever saw it
  if (seen && known[id] === rev) return null;                       // nothing changed since last time
  const f = live[0] ?? group[0];
  const amount = live.reduce((s, b) => s + (Number(b.price) || 0), 0);
  const via = f.referer || f.apiSource || f.channel;
  return {
    res_id: id, revision: rev, status: !live.length ? "cancelled" : seen ? "modified" : "new",
    ota_code: String(f.apiReference || f.id),
    customer: { name: f.firstName ?? "", surname: f.lastName ?? "", phone: f.mobile || f.phone || "", mail: f.email ?? "", country: f.country2 || f.country || "" },
    rooms: live.map((b) => ({ ota_room_id: String(b.roomId), checkin_date: String(b.arrival).slice(0, 10), checkout_date: String(b.departure).slice(0, 10),
      amount: Number(b.price) || undefined, adults: Number(b.numAdult) || 1 })),
    amount: amount || undefined, currency: f.currency || "INR",
    arrival_date: live.length ? live.map((b) => String(b.arrival).slice(0, 10)).sort()[0] : String(f.arrival ?? "").slice(0, 10) || undefined,
    departure_date: live.length ? live.map((b) => String(b.departure).slice(0, 10)).sort().pop() : String(f.departure ?? "").slice(0, 10) || undefined,
    notes: [via ? `Via ${via} (Beds24 ${f.id})` : `Beds24 ${f.id}`, f.notes ? String(f.notes).slice(0, 300) : ""].filter(Boolean).join(" · "),
  };
}

export function beds24Adapter(rpc: Rpc): Adapter {
  return {
    async listRooms(c) {
      const token = await b24Token(rpc, c.id);
      const [p] = await b24Properties(token, c.ota_hotel_id);
      if (!p) throw new B24Error(`Beds24 property ${c.ota_hotel_id} isn’t in this Beds24 account.`);
      return (p.roomTypes ?? []).map((r) => ({ ota_room_id: String(r.id), ota_rate_id: "",
        room_name: `${r.name || "Room " + r.id}${r.qty ? ` · ${r.qty} unit${r.qty === 1 ? "" : "s"}` : ""}` }));
    },
    async push(c, nights) {
      const token = await b24Token(rpc, c.id);
      const byRoom = new Map<string, Record<string, unknown>[]>();
      for (const r of toRanges(nights)) {
        const list = byRoom.get(r.ota_room_id) ?? [];
        list.push({ from: r.date_from, to: r.date_to, numAvail: r.avail, price1: Math.round(r.rate_paise) / 100, [B24.minStayField]: r.min_stay });
        byRoom.set(r.ota_room_id, list);
      }
      const rooms = [...byRoom.entries()].map(([id, calendar]) => ({ roomId: Number(id), calendar }));
      let messages = 0;
      for (let i = 0; i < rooms.length; i += 20) { await b24("/inventory/rooms/calendar", { method: "POST", token, body: rooms.slice(i, i + 20) }); messages++; }
      return { messages };
    },
    async pull(c) {
      const token = await b24Token(rpc, c.id);
      const meta = (await rpc("cn_b24_conn", { p_connection: c.id })) as { last_pull_at?: string | null } | null;
      const q = new URLSearchParams({ propertyId: c.ota_hotel_id });
      if (meta?.last_pull_at) q.set(B24.changedFilter, new Date(Date.parse(meta.last_pull_at) - 10 * 60_000).toISOString().slice(0, 19) + "Z");   // 10-minute overlap
      else q.set(B24.upcomingFilter, new Date().toISOString().slice(0, 10));
      const all: Any[] = [];
      for (let page = 1; page <= 20; page++) {
        q.set("page", String(page));
        const d = await b24(`/bookings?${q}`, { token });
        all.push(...(Array.isArray(d) ? d : d?.data ?? []));
        if (Array.isArray(d) || !(d?.pages?.nextPageExists || d?.pages?.nextPageLink)) break;
      }
      const groups = new Map<string, Any[]>();
      for (const b of all) {
        if (B24_SKIP.has(String(b.status ?? "").toLowerCase())) continue;
        if (String(b.propertyId ?? c.ota_hotel_id) !== String(c.ota_hotel_id)) continue;
        const k = String(b.masterId || b.id); groups.set(k, [...(groups.get(k) ?? []), b]);
      }
      if (!groups.size) return [];
      const known = ((await rpc("cn_res_known", { p_connection: c.id, p_ids: [...groups.keys()] })) ?? {}) as Record<string, string>;
      return [...groups.values()].map((g) => b24Norm(g, known)).filter((r): r is NormRes => !!r);
    },
    async confirm() { /* Beds24 needs no acknowledgement; the "changed since" cursor moves on after each read */ },
  };
}

export function adapterFor(ota: string, rpc: Rpc): Adapter {
  switch (ota) {
    case "beds24": return beds24Adapter(rpc);
    case "test": return testAdapter(rpc);
    case "booking": return bookingAdapter(rpc);
    case "mmt": return pendingAdapter("MakeMyTrip / Goibibo", ["MMT_ACCESS_TOKEN"]);
    case "agoda": return pendingAdapter("Agoda", ["AGODA_API_KEY"]);
    case "expedia": return pendingAdapter("Expedia", ["EXPEDIA_USERNAME", "EXPEDIA_PASSWORD"]);
    case "hostelworld": return pendingAdapter("Hostelworld", ["HOSTELWORLD_API_KEY"]);
    default: return pendingAdapter(ota, ["partner credentials"]);
  }
}
