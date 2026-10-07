// NammaStay · billing-reminders — daily (pg_cron, header x-cron-secret).
// 1) creates today's reminders (trial ending/ended, renewal due/ended) + in-app notifications
// 2) emails each owner once (Resend), if RESEND_API_KEY is set
// Secrets: CRON_SECRET, RESEND_API_KEY (optional), MAIL_FROM (e.g. "NammaStay <billing@thenammastay.com>"), APP_URL (optional)
// Deploy: supabase functions deploy billing-reminders --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SECRET = Deno.env.get("CRON_SECRET") ?? "";
const RESEND = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("MAIL_FROM") ?? "NammaStay <onboarding@resend.dev>";
const SITE = (Deno.env.get("APP_URL") ?? "https://app.thenammastay.com").replace(/\/$/, "");   // the hostel app
const esc = (s: string) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

type R = { id: string; kind: string; property: string; email: string; name: string; text: { title: string; body: string } };

Deno.serve(async (req) => {
  if (!SECRET || req.headers.get("x-cron-secret") !== SECRET) return new Response("Forbidden", { status: 403 });
  const { data: created, error } = await admin.rpc("run_billing_reminders");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!RESEND) return Response.json({ created, emailed: 0, note: "RESEND_API_KEY not set — in-app reminders only" });

  const { data: list } = await admin.rpc("reminders_to_email");
  const sent: string[] = [];
  for (const r of (list ?? []) as R[]) {
    const html = `<div style="font-family:Arial,sans-serif;max-width:520px;margin:auto;color:#101A3D">
      <h2 style="margin:0 0 8px">${esc(r.text.title)}</h2>
      <p>Hello ${esc(r.name)},</p>
      <p>${esc(r.text.body)}</p>
      <p style="margin:20px 0"><a href="${SITE}/settings.html?tab=billing" style="background:#1C9A6C;color:#fff;padding:12px 18px;border-radius:8px;text-decoration:none;font-weight:bold">Choose a plan</a></p>
      <p style="color:#6B7280;font-size:13px">${esc(r.property)} · NammaStay</p></div>`;
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to: [r.email], subject: `${r.text.title} · ${r.property}`, html }),
    });
    if (res.ok) sent.push(r.id);
  }
  if (sent.length) await admin.rpc("mark_reminders_emailed", { p_ids: sent });
  return Response.json({ created, emailed: sent.length });
});
