// NammaStay · razorpay — online payment links (each property uses its own Razorpay account)
//   POST {action:"create", booking_id, amount_paise}  (staff login) → creates a Razorpay Payment Link
//   POST {action:"check",  booking_id}                (staff login) → asks Razorpay if open links were paid
//   POST {action:"test",   property_id}               (owner/manager) → checks the saved keys work
//   POST ?p=<property_id> with header X-Razorpay-Signature → Razorpay webhook (payment_link.paid / expired / cancelled)
// Deploy: supabase functions deploy razorpay --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const RZP = "https://api.razorpay.com/v1";

async function keysFor(propertyId: string) {
  const { data } = await admin.rpc("paylink_keys", { p_property: propertyId });
  if (!data?.key_id || !data?.key_secret) throw new Error("Razorpay isn’t connected for this property (Settings → Property details → Online payments).");
  return data as { key_id: string; key_secret: string; webhook_secret: string | null };
}
async function rzp(keys: { key_id: string; key_secret: string }, path: string, init: RequestInit = {}) {
  const r = await fetch(RZP + path, { ...init, headers: { "Content-Type": "application/json", Authorization: "Basic " + btoa(`${keys.key_id}:${keys.key_secret}`), ...(init.headers ?? {}) } });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body?.error?.description || `Razorpay error ${r.status}`);
  return body;
}
async function hmacHex(secret: string, text: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEqual(a: string, b: string) { if (a.length !== b.length) return false; let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i); return x === 0; }
const cleanPhone = (p?: string | null) => { const d = String(p ?? "").replace(/[^\d+]/g, ""); return /^\+?\d{10,15}$/.test(d) ? d : null; };

async function markIfPaid(keys: { key_id: string; key_secret: string }, linkId: string) {
  const l = await rzp(keys, `/payment_links/${linkId}`);
  if (l.status === "paid") {
    const pay = (l.payments ?? []).find((p: { status?: string }) => p.status === "captured") ?? (l.payments ?? [])[0] ?? {};
    const { data } = await admin.rpc("paylink_mark_paid", { p_link_id: linkId, p_payment_id: pay.payment_id ?? linkId, p_method: pay.method ?? null, p_amount: l.amount_paid ?? l.amount });
    return data?.already ? 0 : 1;
  }
  if (l.status === "expired" || l.status === "cancelled") await admin.rpc("paylink_set_status", { p_link_id: linkId, p_status: l.status });
  return 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);

  // ---------- webhook from Razorpay ----------
  const signature = req.headers.get("x-razorpay-signature");
  if (signature) {
    const propertyId = url.searchParams.get("p") ?? "";
    const raw = await req.text();
    try {
      const keys = await keysFor(propertyId);
      if (!keys.webhook_secret) return json({ error: "no webhook secret" }, 400);
      if (!safeEqual(await hmacHex(keys.webhook_secret, raw), signature)) return json({ error: "bad signature" }, 401);
      const ev = JSON.parse(raw);
      const link = ev?.payload?.payment_link?.entity; const pay = ev?.payload?.payment?.entity;
      if (ev.event === "payment_link.paid" && link?.id) {
        await admin.rpc("paylink_mark_paid", { p_link_id: link.id, p_payment_id: pay?.id ?? link.id, p_method: pay?.method ?? null, p_amount: pay?.amount ?? link.amount_paid ?? link.amount });
      } else if ((ev.event === "payment_link.expired" || ev.event === "payment_link.cancelled") && link?.id) {
        await admin.rpc("paylink_set_status", { p_link_id: link.id, p_status: ev.event.split(".")[1] });
      }
      return json({ ok: true });
    } catch (e) { return json({ error: e instanceof Error ? e.message : String(e) }, 400); }
  }

  // ---------- staff actions ----------
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Please sign in." }, 401);
  const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const body = await req.json().catch(() => ({}));
  try {
    if (body.action === "create") {
      const { data: prep, error } = await user.rpc("paylink_prepare", { p_booking: body.booking_id, p_amount: body.amount_paise });
      if (error) throw new Error(error.message);
      const keys = await keysFor(prep.property_id);
      const phone = cleanPhone(prep.guest_phone);
      const link = await rzp(keys, "/payment_links", { method: "POST", body: JSON.stringify({
        amount: prep.amount_paise, currency: "INR",
        reference_id: `${prep.code}-${Date.now().toString(36)}`.slice(0, 40),
        description: `${prep.property_name} · booking ${prep.code}`.slice(0, 2048),
        customer: { name: prep.guest_name ?? "Guest", ...(phone ? { contact: phone } : {}), ...(prep.guest_email ? { email: prep.guest_email } : {}) },
        notify: { sms: !!phone, email: !!prep.guest_email }, reminder_enable: true,
        expire_by: Math.floor(Date.now() / 1000) + 7 * 24 * 3600,
        notes: { booking_id: prep.booking_id, property_id: prep.property_id, booking_code: prep.code },
      }) });
      const { data: u } = await user.auth.getUser();
      await admin.rpc("paylink_store", { p_property: prep.property_id, p_booking: prep.booking_id, p_link_id: link.id, p_url: link.short_url, p_amount: prep.amount_paise, p_user: u?.user?.id ?? null });
      return json({ id: link.id, short_url: link.short_url, amount_paise: prep.amount_paise });
    }
    if (body.action === "check") {
      const { data: links, error } = await user.rpc("paylink_list", { p_booking: body.booking_id });
      if (error) throw new Error(error.message);
      const open = (links ?? []).filter((l: { status: string }) => l.status === "created");
      if (!open.length) return json({ paid: 0 });
      const { data: b } = await admin.from("bookings").select("property_id").eq("id", body.booking_id).single();
      const keys = await keysFor(b.property_id);
      let paid = 0; for (const l of open) paid += await markIfPaid(keys, l.rzp_link_id);
      return json({ paid });
    }
    if (body.action === "test") {
      const { data: st, error } = await user.rpc("razorpay_status", { p_property: body.property_id });
      if (error) throw new Error(error.message);
      if (!st?.connected) throw new Error("Save your Razorpay keys first.");
      await rzp(await keysFor(body.property_id), "/payment_links?count=1");
      return json({ ok: true, mode: st.mode });
    }
    return json({ error: "Unknown action." }, 400);
  } catch (e) { return json({ error: e instanceof Error ? e.message : String(e) }, 400); }
});
