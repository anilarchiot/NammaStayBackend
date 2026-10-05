// NammaStay · notify-lead
// Emails you when someone fills "Get early access" on the homepage,
// and sends the person a short thank-you (if they gave an email).
//
// Triggered by a Database Webhook on leads INSERT (see GO-LIVE.md step 7b).
// Secrets:  RESEND_API_KEY, MAIL_FROM, WEBHOOK_SECRET, SITE_URL, LEADS_NOTIFY_EMAIL
// Deploy:   supabase functions deploy notify-lead --no-verify-jwt
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const MAIL_FROM = Deno.env.get("MAIL_FROM") ?? "NammaStay <hello@thenammastay.com>";
const SITE_URL = (Deno.env.get("SITE_URL") ?? "https://thenammastay.com").replace(/\/$/, "");
const SECRET = Deno.env.get("WEBHOOK_SECRET") ?? "";
const NOTIFY = Deno.env.get("LEADS_NOTIFY_EMAIL") ?? "";

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function send(to: string, subject: string, html: string, replyTo?: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: MAIL_FROM, to: [to], subject, html, ...(replyTo ? { reply_to: replyTo } : {}) }),
  });
  if (!r.ok) throw new Error(`Email to ${to} failed: ${r.status} ${await r.text()}`);
}

Deno.serve(async (req) => {
  if (!SECRET || req.headers.get("x-webhook-secret") !== SECRET) return new Response("Unauthorized", { status: 401 });
  const payload = await req.json().catch(() => null);
  const l = payload?.record;
  if (payload?.type !== "INSERT" || payload?.table !== "leads" || !l?.id) return new Response("Ignored");

  const errors: string[] = [];
  const row = (k: string, v: unknown) => (v ? `<tr><td style="padding:4px 12px 4px 0;color:#6B7280">${k}</td><td style="padding:4px 0"><b>${esc(v)}</b></td></tr>` : "");
  const wa = l.phone ? `https://wa.me/${String(l.phone).replace(/\D/g, "")}` : "";

  if (NOTIFY) {
    await send(NOTIFY, `New NammaStay lead — ${l.name}${l.city ? " · " + l.city : ""}`,
      `<div style="font-family:system-ui,sans-serif;color:#101A3D">
        <h2 style="margin:0 0 12px">New early-access request</h2>
        <table style="font-size:14px;border-collapse:collapse">
          ${row("Name", l.name)}${row("Phone", l.phone)}${row("Email", l.email)}${row("Property", l.property_name)}
          ${row("Type", l.property_type)}${row("Beds / rooms", l.beds)}${row("City", l.city)}${row("Message", l.message)}${row("Came from", l.source)}
        </table>
        <p style="margin:16px 0 0">
          ${wa ? `<a href="${wa}" style="margin-right:16px">WhatsApp them</a>` : ""}
          <a href="${SITE_URL}/leads.html">Open leads in NammaStay</a></p>
      </div>`, l.email || undefined).catch((e) => errors.push(String(e)));
  }

  if (l.email) {
    await send(l.email, "Thanks for your interest in NammaStay",
      `<div style="font-family:system-ui,sans-serif;color:#101A3D;line-height:1.6">
        <h2 style="margin:0 0 12px">Thanks, ${esc(String(l.name).split(" ")[0])}!</h2>
        <p style="margin:0 0 12px">We’ve got your request${l.property_name ? ` for <b>${esc(l.property_name)}</b>` : ""} and will get in touch shortly to set things up.</p>
        <p style="margin:0 0 16px">Meanwhile, you can click around the live demo — it’s loaded with a sample 9-bed hostel.</p>
        <p style="margin:0"><a href="${SITE_URL}" style="background:#1C9A6C;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none;font-weight:700">Visit NammaStay</a></p>
      </div>`).catch((e) => errors.push(String(e)));
  }

  if (errors.length) console.error(errors.join("\n"));
  return new Response(JSON.stringify({ ok: !errors.length }), { status: errors.length ? 500 : 200, headers: { "Content-Type": "application/json" } });
});
