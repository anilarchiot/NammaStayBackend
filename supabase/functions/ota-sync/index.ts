// NammaStay · ota-sync
// Imports OTA calendars (iCal links from Airbnb, Booking.com, Agoda, Vrbo, Google…) into NammaStay as blocks.
//   • every 30 minutes from pg_cron  (header x-cron-secret: CRON_SECRET)  → all feeds
//   • "Sync now" in the app           (staff login, body { property_id })  → that property's feeds
// Secrets: CRON_SECRET.   Deploy: supabase functions deploy ota-sync --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SECRET = Deno.env.get("CRON_SECRET") ?? "";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

type Ev = { uid: string; start: string; end: string };
const toDay = (v: string) => { const m = v.match(/(\d{4})(\d{2})(\d{2})/); return m ? `${m[1]}-${m[2]}-${m[3]}` : ""; };
const addDay = (d: string) => { const t = new Date(d + "T12:00:00Z"); t.setUTCDate(t.getUTCDate() + 1); return t.toISOString().slice(0, 10); };

function parseIcs(text: string): Ev[] {
  const lines = text.replace(/\r\n[ \t]/g, "").replace(/\n[ \t]/g, "").split(/\r?\n/);    // unfold
  const out: Ev[] = []; let cur: Record<string, string> | null = null;
  for (const line of lines) {
    if (line === "BEGIN:VEVENT") { cur = {}; continue; }
    if (line === "END:VEVENT") {
      if (cur && cur.DTSTART && (cur.STATUS ?? "").toUpperCase() !== "CANCELLED") {
        const start = toDay(cur.DTSTART); let end = cur.DTEND ? toDay(cur.DTEND) : "";
        if (!end || end <= start) end = addDay(start);
        const uid = cur.UID || `${start}-${end}-${cur.SUMMARY ?? ""}`;
        if (start) out.push({ uid: uid.slice(0, 300), start, end });
      }
      cur = null; continue;
    }
    if (!cur) continue;
    const i = line.indexOf(":"); if (i < 0) continue;
    const key = line.slice(0, i).split(";")[0].toUpperCase(); const val = line.slice(i + 1).trim();
    if (["UID", "DTSTART", "DTEND", "SUMMARY", "STATUS"].includes(key)) cur[key] = val;
  }
  return out;
}

async function syncFeed(feed: { id: string; import_url: string }) {
  try {
    const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), 20000);
    const r = await fetch(feed.import_url, { signal: ctl.signal, headers: { "User-Agent": "NammaStay-Calendar-Sync/1.0" } });
    clearTimeout(timer);
    if (!r.ok) throw new Error(`The OTA answered ${r.status} — check the link is still valid.`);
    const text = await r.text();
    if (text.length > 3_000_000) throw new Error("Calendar file is too large.");
    if (!text.includes("BEGIN:VCALENDAR")) throw new Error("That link doesn’t return a calendar (.ics). Copy the iCal/export link again.");
    const { data, error } = await admin.rpc("ota_apply", { p_feed: feed.id, p_events: parseIcs(text), p_error: null });
    if (error) throw new Error(error.message);
    return { feed: feed.id, ...data };
  } catch (e) {
    const msg = e instanceof Error ? (e.name === "AbortError" ? "The OTA took too long to answer." : e.message) : String(e);
    await admin.rpc("ota_apply", { p_feed: feed.id, p_events: [], p_error: msg });
    return { feed: feed.id, error: msg };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let feeds: { id: string; import_url: string }[] = [];
  if (SECRET && req.headers.get("x-cron-secret") === SECRET) {
    const { data, error } = await admin.rpc("ota_due_feeds", { p_limit: 300 });
    if (error) return json({ error: error.message }, 500);
    feeds = data ?? [];
  } else {
    const auth = req.headers.get("Authorization") ?? "";
    if (!auth.startsWith("Bearer ")) return json({ error: "Please sign in." }, 401);
    const user = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const body = await req.json().catch(() => ({}));
    const { data: ids, error } = await user.rpc("ota_feeds_for_sync", { p_property: body.property_id });
    if (error) return json({ error: error.message }, 403);
    if (!ids?.length) return json({ synced: 0, results: [] });
    const { data } = await admin.from("ota_feeds").select("id, import_url").in("id", ids);
    feeds = data ?? [];
  }
  const results = [];
  for (let i = 0; i < feeds.length; i += 5) results.push(...(await Promise.all(feeds.slice(i, i + 5).map(syncFeed))));
  return json({ synced: results.length, results });
});
