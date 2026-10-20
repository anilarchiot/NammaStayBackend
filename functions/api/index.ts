// NammaStay · api — public REST API for one property, authenticated with an API key
// (owner creates keys in NammaStay → Settings → API keys).
//
// Base URL:  https://<project-ref>.supabase.co/functions/v1/api/v1
// Auth:      header  X-Api-Key: ns_live_…      (or  Authorization: Bearer ns_live_…)
//
//   GET  /v1/property
//   GET  /v1/rooms
//   GET  /v1/availability?from=YYYY-MM-DD&to=YYYY-MM-DD[&room_type_id=…]
//   GET  /v1/bookings?from=YYYY-MM-DD&to=YYYY-MM-DD[&status=…&limit=…]      scope: bookings
//   GET  /v1/bookings/{id or code}                                         scope: bookings
//   POST /v1/bookings            JSON body, optional Idempotency-Key header  scope: bookings
//   POST /v1/bookings/{id or code}/cancel   {"reason": "…"}                 scope: bookings
//
// Money is in rupees (INR). Dates are the property's local dates. Errors: {"error": {"code", "message"}}.
// Deploy: supabase functions deploy api --no-verify-jwt   (the function checks the API key itself)
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "x-api-key, authorization, content-type, idempotency-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", ...extra } });
const fail = (status: number, code: string, message: string) => json({ error: { code, message } }, status);

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const STATUS_FOR: Record<string, [number, string]> = {
  P0404: [404, "not_found"], P0409: [409, "conflict"], P0402: [402, "subscription_expired"],
  "22P02": [400, "invalid_value"], "22007": [400, "invalid_date"], "22008": [400, "invalid_date"],
};

async function call(fn: string, args: Record<string, unknown>) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) {
    const [status, code] = STATUS_FOR[error.code ?? ""] ?? [error.code?.startsWith("P0") ? 400 : 500, error.code?.startsWith("P0") ? "invalid_request" : "server_error"];
    throw Object.assign(new Error(status === 500 ? "Something went wrong on our side. Please try again." : error.message), { status, code });
  }
  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const url = new URL(req.url);
    // …/api/v1/rooms — take the part after the function name "api" (works with or without the /functions/v1 prefix)
    const parts = url.pathname.split("/").filter(Boolean);
    const a = parts.lastIndexOf("api");
    const i = a >= 0 && parts[a + 1] === "v1" ? a + 1 : -1;
    if (i < 0) return fail(404, "not_found", "Use /v1/… — e.g. GET /functions/v1/api/v1/rooms");
    const route = parts.slice(i + 1);

    const key = req.headers.get("x-api-key") ?? (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const auth = await call("api_auth", { p_key: key.trim() });
    if (auth?.status) return fail(auth.status, auth.code, auth.message);
    const P = auth.property_id as string;
    const can = (s: string) => (auth.scopes as string[]).includes(s);
    const needBookings = () => { if (!can("bookings")) throw Object.assign(new Error("This API key can only read rooms and availability. Create a key with the Bookings permission."), { status: 403, code: "forbidden" }); };
    const q = url.searchParams;
    const dates = (a: string, b: string) => {
      const f = q.get(a), t = q.get(b);
      if (!f || !t || !DATE.test(f) || !DATE.test(t)) throw Object.assign(new Error(`${a} and ${b} are required, as YYYY-MM-DD.`), { status: 400, code: "invalid_request" });
      return [f, t];
    };

    const [res, id, action] = route;
    if (req.method === "GET" && res === "property" && !id) return json({ data: await call("api_property", { p_property: P }) });
    if (req.method === "GET" && res === "rooms" && !id) return json({ data: await call("api_rooms", { p_property: P }) });
    if (req.method === "GET" && res === "availability" && !id) {
      const [f, t] = dates("from", "to");
      return json({ data: await call("api_availability", { p_property: P, p_from: f, p_to: t, p_room_type: q.get("room_type_id") || null }) });
    }
    if (res === "bookings") {
      needBookings();
      if (req.method === "GET" && !id) {
        const [f, t] = dates("from", "to");
        return json({ data: await call("api_bookings", { p_property: P, p_from: f, p_to: t, p_status: q.get("status") || null, p_limit: Number(q.get("limit") || 100) }) });
      }
      if (req.method === "GET" && id && !action) {
        const b = await call("api_booking_get", { p_property: P, p_ref: id });
        return b ? json({ data: b }) : fail(404, "not_found", "Booking not found.");
      }
      if (req.method === "POST" && !id) {
        const body = await req.json().catch(() => null);
        if (!body || typeof body !== "object") return fail(400, "invalid_json", "Send a JSON body.");
        const idem = req.headers.get("idempotency-key")?.slice(0, 100) || null;
        return json({ data: await call("api_booking_create", { p_property: P, p_key_id: auth.key_id, p: body, p_idem: idem }) }, 201);
      }
      if (req.method === "POST" && id && action === "cancel") {
        const body = await req.json().catch(() => ({}));
        return json({ data: await call("api_booking_cancel", { p_property: P, p_ref: id, p_reason: typeof body?.reason === "string" ? body.reason : null }) });
      }
    }
    return fail(404, "not_found", `No such endpoint: ${req.method} /v1/${route.join("/")}`);
  } catch (e) {
    const err = e as { status?: number; code?: string; message?: string };
    if (!err.status || err.status >= 500) console.error(e);
    return fail(err.status ?? 500, err.code ?? "server_error", err.message ?? "Something went wrong.");
  }
});
