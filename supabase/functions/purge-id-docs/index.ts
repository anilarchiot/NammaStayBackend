// NammaStay · purge-id-docs
// Deletes guest ID photos once a guest's last stay is older than the
// property's retention period (Settings → Property, default 180 days).
// Runs daily from pg_cron (see migrations/005_schedule.sql).
// Secrets:  CRON_SECRET
// Deploy:   supabase functions deploy purge-id-docs --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SECRET = Deno.env.get("CRON_SECRET") ?? "";

Deno.serve(async (req) => {
  if (!SECRET || req.headers.get("x-cron-secret") !== SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }
  let purged = 0;
  for (let round = 0; round < 20; round++) {           // up to 4,000 files per run
    const { data, error } = await sb.rpc("id_docs_due_for_purge", { p_limit: 200 });
    if (error) return new Response(error.message, { status: 500 });
    if (!data?.length) break;
    const paths = data.map((r: { path: string }) => r.path);
    const { error: rmErr } = await sb.storage.from("guest-ids").remove(paths);
    if (rmErr) return new Response(rmErr.message, { status: 500 });
    for (const r of data) await sb.rpc("mark_id_doc_purged", { p_guest: r.guest_id });
    purged += data.length;
  }
  return new Response(JSON.stringify({ purged }), { headers: { "Content-Type": "application/json" } });
});
