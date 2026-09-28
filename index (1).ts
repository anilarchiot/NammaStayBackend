// NammaStay · notify-booking
// Sends emails when a booking is created:
//   • an alert to the property's email address
//   • a confirmation + self check-in link to the guest (if staff ticked the box)
//
// Triggered by a Database Webhook on bookings INSERT (see GO-LIVE.md, step 7).
// Secrets:  RESEND_API_KEY, MAIL_FROM, WEBHOOK_SECRET, SITE_URL
// Deploy:   supabase functions deploy notify-booking --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const MAIL_FROM = Deno.env.get("MAIL_FROM") ?? "NammaStay <bookings@thenammastay.in>";
const SITE_URL = (Deno.env.get("SITE_URL") ?? "https://thenammastay.in").replace(/\/$/, "");
const SECRET = Deno.env.get("WEBHOOK_SECRET") ?? "";

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const rupees = (p: number) => "₹" + (p / 100).toLocaleString("en-IN");
const when = (iso: string) =>
  new Intl.DateTimeFormat("en-IN", { timeZone: "Asia/Kolkata", day: "numeric", month: "short", year: "numeric",
    hour: "numeric", minute: "2-digit" }).format(new Date(iso));

async function send(to: string, subject: string, html: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: MAIL_FROM, to: [to], subject, html }),
  });
  if (!r.ok) throw new Error(`Email to ${to} failed: ${r.status} ${await r.text()}`);
}

Deno.serve(async (req) => {
  if (!SECRET || req.headers.get("x-webhook-secret") !== SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }
  const payload = await req.json().catch(() => null);
  const b = payload?.record;
  if (payload?.type !== "INSERT" || payload?.table !== "bookings" || !b?.id) {
    return new Response("Ignored", { status: 200 });
  }

  const [{ data: guest }, { data: bed }, { data: prop }] = await Promise.all([
    sb.from("guests").select("full_name, email, phone").eq("id", b.guest_id).single(),
    sb.from("beds").select("label, rooms(name)").eq("id", b.bed_id).single(),
    sb.from("properties").select("name, email, phone, address, city").eq("id", b.property_id).single(),
  ]);
  if (!guest || !bed || !prop) return new Response("Missing data", { status: 200 });

  // deno-lint-ignore no-explicit-any
  const room = (bed as any).rooms?.name ?? "";
  const summary = `
    <p style="margin:0 0 4px"><b>${esc(b.code)}</b> · ${esc(room)} · ${esc(bed.label)}</p>
    <p style="margin:0 0 4px">Check-in: ${esc(when(b.check_in_at))}</p>
    <p style="margin:0 0 4px">Check-out: ${esc(when(b.check_out_at))}</p>
    <p style="margin:0">${b.nights} night(s) · Total ${rupees(b.total_paise)}</p>`;
  const errors: string[] = [];

  if (prop.email) {
    await send(prop.email, `New booking ${b.code} — ${guest.full_name}`,
      `<div style="font-family:system-ui,sans-serif;color:#101A3D">
         <h2 style="margin:0 0 12px">New booking</h2>
         <p style="margin:0 0 8px">${esc(guest.full_name)} · ${esc(guest.phone ?? "")}</p>${summary}
         <p style="margin:16px 0 0"><a href="${SITE_URL}/booking-detail.html?id=${b.id}">Open in NammaStay</a></p>
       </div>`).catch((e) => errors.push(String(e)));
  }

  if (b.send_confirmation && guest.email) {
    const link = `${SITE_URL}/self-check-in.html?t=${b.self_checkin_token}`;
    await send(guest.email, `Your booking at ${prop.name} (${b.code})`,
      `<div style="font-family:system-ui,sans-serif;color:#101A3D">
         <h2 style="margin:0 0 12px">See you soon, ${esc(guest.full_name.split(" ")[0])}!</h2>
         <p style="margin:0 0 12px">Your bed at <b>${esc(prop.name)}</b> is booked.</p>${summary}
         <p style="margin:16px 0 8px">Save time at the front desk — check in online:</p>
         <p style="margin:0 0 16px"><a href="${link}" style="background:#1C9A6C;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none;font-weight:700">Check in online</a></p>
         <p style="margin:0;color:#6B7280;font-size:13px">${esc([prop.address, prop.city].filter(Boolean).join(", "))}${prop.phone ? " · " + esc(prop.phone) : ""}</p>
       </div>`).catch((e) => errors.push(String(e)));
  }

  if (errors.length) console.error(errors.join("\n"));
  return new Response(JSON.stringify({ ok: errors.length === 0 }), {
    status: errors.length ? 500 : 200, headers: { "Content-Type": "application/json" },
  });
});
