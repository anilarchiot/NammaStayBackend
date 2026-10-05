// NammaStay · ical
// Public calendar link for one bed/room: https://<project>.supabase.co/functions/v1/ical?t=<token>[&c=airbnb]
// OTAs (Airbnb, Booking.com, Agoda, Vrbo…) import it so nights booked or blocked in NammaStay are closed there.
// Only dates are shared — "Reserved" / "Not available" — never guest names or prices.
// Deploy: supabase functions deploy ical --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CHANNELS = new Set(["airbnb", "booking", "agoda", "vrbo", "google", "other"]);
const esc = (s: string) => String(s).replace(/[\\;,]/g, (m) => "\\" + m).replace(/\r?\n/g, "\\n");
const ymd = (s: string) => String(s).slice(0, 10).replace(/-/g, "");

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const token = url.searchParams.get("t") ?? "";
  const channel = url.searchParams.get("c");
  if (!/^[0-9a-f-]{36}$/i.test(token)) return new Response("Not found", { status: 404 });
  const { data, error } = await sb.rpc("ota_export", { p_token: token, p_exclude: channel && CHANNELS.has(channel) ? channel : null });
  if (error) return new Response("Calendar unavailable", { status: 500 });
  if (!data) return new Response("Not found", { status: 404 });

  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const out = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//NammaStay//Calendar//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "X-WR-CALNAME:" + esc(data.name), "X-WR-TIMEZONE:" + (data.tz || "Asia/Kolkata")];
  for (const e of data.events ?? []) {
    out.push("BEGIN:VEVENT", `UID:${e.uid}@thenammastay.com`, `DTSTAMP:${stamp}`,
      `DTSTART;VALUE=DATE:${ymd(e.start)}`, `DTEND;VALUE=DATE:${ymd(e.end)}`, `SUMMARY:${esc(e.summary)}`, "END:VEVENT");
  }
  out.push("END:VCALENDAR");
  return new Response(out.join("\r\n") + "\r\n", {
    headers: { "Content-Type": "text/calendar; charset=utf-8", "Cache-Control": "no-store", "Content-Disposition": 'inline; filename="nammastay.ics"' },
  });
});
