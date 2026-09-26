# NammaStay — backend

Database, security rules and server functions for NammaStay, running on **Supabase**.
The website lives in the separate frontend repo (**NammaStayFrontend**, served by GitHub Pages).

> GitHub doesn't run this code — it's stored here for history and backup.
> Supabase runs it: the SQL is pasted into Supabase's SQL Editor, and the
> functions are deployed by the GitHub Action in `.github/workflows/`.

| Path | What it is |
|---|---|
| `supabase/SETUP_ALL.sql` | Complete database in one file (001 + 002 + 003 + 006). Paste once into SQL Editor on a new project. |
| `supabase/migrations/001_schema.sql` | Tables, indexes, double-booking guard, triggers |
| `supabase/migrations/002_security.sql` | Row Level Security, roles, private ID-photo bucket |
| `supabase/migrations/003_functions.sql` | Every query the app uses (bookings, payments, reports, self check-in…) |
| `supabase/migrations/006_marketing.sql` | Homepage early-access form (leads) + admin |
| `supabase/setup/004_seed.sql` | Your hostel, rooms, 9 beds and owner login — edit the email first |
| `supabase/setup/005_schedule.sql` | Nightly ID-photo cleanup — edit project ref + secret first |
| `supabase/functions/` | `notify-booking`, `notify-lead` (emails via Resend), `purge-id-docs` |
| `supabase/tests/` | Security checks + lakhs-of-rows load test (test project only) |
| `docs/GO-LIVE.md` | Step-by-step launch guide |

## Secrets — never in this repo
Set them in Supabase, not in files:
```bash
supabase secrets set RESEND_API_KEY=... MAIL_FROM="..." WEBHOOK_SECRET=... CRON_SECRET=... \
  SITE_URL=https://thenammastay.com LEADS_NOTIFY_EMAIL=you@example.com
```
The only key that goes in the frontend is the **anon public** key (in its `assets/js/config.js`). The **service_role** key never goes anywhere public.

## Making changes later
1. Add a new numbered file, e.g. `supabase/migrations/007_something.sql`.
2. Try it on a test Supabase project first.
3. Run it on the live project in SQL Editor, then re-run `supabase/tests/01_security_checks.sql`.
4. Commit it here so the history stays complete.
