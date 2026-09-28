# NammaStay — Go-live guide

How to take NammaStay from a clickable demo to a real system holding lakhs of bookings, with the checks to run before you trust it with guests.

**Stack:** the website stays on GitHub Pages (free). The backend is **Supabase** — a hosted Postgres database with login, file storage, live updates and small server functions. There is no server for you to maintain.

```
Browser (thenammastay.in)  ──►  Supabase
  HTML + assets/js              ├─ Postgres: tables, rules, functions (supabase/migrations)
                                ├─ Auth: staff logins
                                ├─ Storage: private "guest-ids" bucket
                                ├─ Realtime: notification badge
                                └─ Edge Functions: emails, ID-photo cleanup
```

Budget about 2–3 hours for the first setup.

---

## 0. What's in the repo

This guide lives in the **backend repo**. The website is in the separate **frontend repo** (NammaStayFrontend).

| Path | What it is |
|---|---|
| `index.html` | Marketing homepage. Edit the WhatsApp/email at the bottom of the file. |
| `login.html` + other `*.html`, `assets/` | The app. Works as a demo until `assets/js/config.js` is filled in. |
| `assets/js/core.js` | Login check, roles, formatting, dialogs, notification bell. |
| `assets/js/pages/*.js` | One script per screen; each calls the database functions. |
| `supabase/migrations/001–003, 006` | The database structure: run in order (or `SETUP_ALL.sql`). |
| `supabase/setup/004_seed.sql`, `005_schedule.sql` | One-time setup you edit before running (your email, project ref). |
| `supabase/tests/01_security_checks.sql` | Security checks — run before launch and after every change. |
| `supabase/tests/02_load_test.sql` | 1.5 lakh-booking load test — **separate test project only**. |
| `supabase/functions/` | `notify-booking` (booking emails), `notify-lead` (homepage leads), `purge-id-docs` (privacy cleanup). |
| `supabase/SETUP_ALL.sql` | 001 + 002 + 003 + 006 in one file. |

---

## 1. Create the Supabase project

1. Sign up at supabase.com → **New project**.
2. **Region: Mumbai (ap-south-1)** — closest to Chennai, fastest for you and keeps data in India.
3. Set a long database password and store it in a password manager.
4. Wait ~2 minutes for it to start.

**Which plan?** Free is fine for building and testing. Before real guest data goes in, move to **Pro (about US$25/month)**, because the free plan has no automatic backups and pauses projects that go unused for a week. Pro also raises the database to 8 GB and file storage to 100 GB.

## 2. Build the database

Supabase → **SQL Editor** → New query. Paste and **Run** each file, in order, one at a time:

1. `supabase/migrations/001_schema.sql` — tables, indexes, double-booking guard
2. `supabase/migrations/002_security.sql` — row-level security, grants, private ID bucket
3. `supabase/migrations/003_functions.sql` — every query the app uses
4. `supabase/migrations/006_marketing.sql` — homepage early-access form (leads)

Shortcut: `supabase/SETUP_ALL.sql` contains all four in one file — paste it once and Run.

If a file errors, fix and re-run that file only after dropping what it created (simplest on a new project: **Settings → General → Reset/delete project** and start again).

## 3. Create your login and seed your hostel

1. **Authentication → Users → Add user → Create new user**: your email + strong password, tick **Auto confirm**.
2. Open `supabase/setup/004_seed.sql`, replace `owner@example.com` with that email, run it.
   It creates Social Backpackers Hostel, the 6-bed dorm (3 lower ₹700, 3 upper ₹600) and the 3-bed dorm (3 lower ₹850), and makes you the owner. Rename beds or change rates later in **Rooms & beds**.

**Make yourself the NammaStay admin** (to see homepage leads at `/leads.html`), with your own email:
```sql
insert into public.platform_admins (user_id)
  select id from auth.users where lower(email) = lower('you@example.com')
on conflict do nothing;
```

## 4. Lock down login

**Authentication → Sign In / Providers → Email**
- Turn **off** "Allow new users to sign up". Only people you invite can get in.
- Minimum password length: **10**.

**Authentication → URL Configuration**
- Site URL: `https://thenammastay.in`
- Redirect URLs: add `https://thenammastay.in/**` and `https://www.thenammastay.in/**`

**Authentication → Emails → SMTP settings** — set up custom SMTP before inviting staff. Supabase's built-in sender is only meant for testing and has a very low hourly limit. Use the same Resend account as step 7 (SMTP host `smtp.resend.com`, port 465, user `resend`, password = your Resend API key).

## 5. Run the security checks

Run `supabase/tests/01_security_checks.sql` in the SQL Editor. Expected:

| Check | Expected |
|---|---|
| 1. Tables without RLS | 0 rows |
| 2. Anonymous table grants | 0 rows |
| 3. Direct staff writes to bookings/payments | 0 rows |
| 4. Functions anonymous visitors can call | exactly `checkin_upload_allowed`, `selfcheckin_get`, `selfcheckin_submit`, `submit_lead` |
| 5. Definer functions without fixed search_path | 0 rows |
| 6. `guest-ids` bucket | `public = false` |
| 7. Double booking | NOTICE `PASS` |
| 8. Payments append-only | `PASS` (or `SKIP` until the first payment) |

Also open **Advisors → Security Advisor** and **Performance Advisor** in Supabase and clear anything marked as an error.

## 6. Connect the website

1. Supabase → **Project Settings → API**: copy the **Project URL** and the **anon public** key.
2. Edit `assets/js/config.js`:
   ```js
   supabaseUrl: 'https://abcdxyz.supabase.co',
   supabaseAnonKey: 'eyJhbGciOi...',
   ```
   The anon key is meant to be public; RLS protects the data. **Never** put the `service_role` key in the website.
3. Upload the changed `config.js` to the **frontend repo** (`assets/js/`). Pages redeploys in 1–2 minutes.
4. Open `https://thenammastay.in/login.html`, sign in, and you should see an empty live dashboard with 9 beds.
   (`https://thenammastay.in` itself is the marketing homepage — `index.html`.)


## 7. Booking emails (Resend)

1. Create an account at resend.com → **Domains → Add** `thenammastay.in` → add the DNS records it shows at your domain provider → wait until verified.
2. Create an API key.
3. Install the Supabase CLI on a computer (`npm i -g supabase`), then from the repo folder:
   ```bash
   supabase login
   supabase link --project-ref YOUR-PROJECT-REF
   WEBHOOK_SECRET=$(openssl rand -hex 24); CRON_SECRET=$(openssl rand -hex 24)
   echo "$WEBHOOK_SECRET  $CRON_SECRET"      # save both in your password manager
   supabase secrets set RESEND_API_KEY=re_xxx MAIL_FROM="Social Backpackers <bookings@thenammastay.in>" \
     WEBHOOK_SECRET=$WEBHOOK_SECRET CRON_SECRET=$CRON_SECRET SITE_URL=https://thenammastay.in
   supabase functions deploy notify-booking --no-verify-jwt
   supabase functions deploy purge-id-docs  --no-verify-jwt
   ```
   (`--no-verify-jwt` is right here: these functions check their own secret header instead of a staff login.)
   **Or let GitHub deploy them for you:** this repo has `.github/workflows/deploy-functions.yml`. Add two repository secrets on GitHub (Settings → Secrets and variables → Actions): `SUPABASE_ACCESS_TOKEN` (supabase.com → Account → Access Tokens) and `SUPABASE_PROJECT_ID` (the `xxxx` in your Supabase URL). Then open **Actions → Deploy Supabase functions → Run workflow**. After that, every change to `supabase/functions/` deploys automatically. (You still set the `supabase secrets` above once.)
4. Supabase → **Database → Webhooks → Create**: table `bookings`, event **Insert**, type **Supabase Edge Function** → `notify-booking`, add HTTP header `x-webhook-secret: <your WEBHOOK_SECRET>`.
5. Settings page in NammaStay → fill **Booking alerts email**.

Staff also see every new booking and online check-in instantly via the bell badge (no setup needed).

### 7b. Homepage lead emails
```bash
supabase secrets set LEADS_NOTIFY_EMAIL=you@example.com
supabase functions deploy notify-lead --no-verify-jwt
```
Then **Database → Webhooks → Create**: table `leads`, event **Insert**, Edge Function `notify-lead`, header `x-webhook-secret: <your WEBHOOK_SECRET>`.
Every early-access request then emails you, sends the person a thank-you, and appears in the app under **Leads**.

## 8. Automatic ID-photo deletion

1. **Database → Extensions**: enable `pg_cron` and `pg_net`.
2. Edit `supabase/setup/005_schedule.sql` (project ref + CRON_SECRET) and run it.
3. The function deletes ID photos once a guest's last stay is older than the retention days in Settings (default 180). Adjust to what your legal advisor recommends.

## 9. Invite staff

1. Supabase → **Authentication → Users → Invite user** (their email). They get a link, land on the sign-in page, and choose a password.
2. In NammaStay → **Settings → Add member**: same email, their name and role.

| Role | Can do |
|---|---|
| Owner | Everything, including team |
| Manager | Bookings, rooms & rates, payments, reports, property settings |
| Front desk | New bookings, check-in/out, guests, payments |
| Accountant | Payments & reports; sees guest names only, no ID data |

## 10. UPI payments (direct, no gateway)

Settings → **Your UPI ID** (e.g. `name@okaxis`). On any booking → **Record payment** shows a QR for the exact amount with the booking code as the note. The guest pays from any UPI app straight into your account.

There is no gateway, so the app can't see the money arrive by itself. The rule for staff: **check the credit in your bank/UPI app, then type the 12-digit UTR** from the guest's screen. The database refuses the same UTR twice, so a screenshot can't be reused.

## 11. Load test (proves "lakhs of data")

1. Create a **second, throwaway** Supabase project (free plan allows 2).
2. Run 001–003 there, create a test login, put its email in `supabase/tests/02_load_test.sql`, run it.
3. It creates ~1.5 lakh bookings (1 lakh in one property), then prints the time each screen's query takes. Target: under ~300 ms each. The final EXPLAIN should show index scans, not `Seq Scan` on bookings.
4. Delete the test project afterwards.

**Why it stays fast:** every list uses keyset pagination (page 5,000 is as fast as page 1), searches use trigram indexes, calendar/occupancy use range (GiST) indexes, dashboards compute totals inside the database and return a few rows, never the whole table.

**Size planning (rough estimates — confirm with the size query in the test):**

| Data | Approx. |
|---|---|
| 1 lakh bookings + guests + payments, with indexes | ~150–250 MB |
| Free plan database | 500 MB → roughly 2 lakh bookings |
| Pro plan database | 8 GB included → tens of lakhs |
| ID photo (compressed in browser) | ~150–300 KB each → ~4,000 per GB |

At 9 beds you'll add roughly 2,000–3,000 bookings a year, so the database itself will never be the constraint. ID photos are: keep the retention cleanup on, or be on Pro.

## 12. Backups

- **Pro plan:** daily backups are automatic (Database → Backups). Test a restore once.
- **Extra safety (any plan):** weekly export from your computer:
  ```bash
  supabase db dump --linked -f backup-$(date +%F).sql          # schema
  supabase db dump --linked --data-only -f data-$(date +%F).sql # data
  ```
  Store the files somewhere private (they contain guest data), not in the public GitHub repo.
- Payments/Reports → **Export CSV** monthly for your accountant.

## 13. Legal & privacy checklist (India)

- **Foreign guests — Form C:** hotels, hostels and guest houses must report foreign guests to the FRRO within 24 hours of arrival via indianfrro.gov.in. Register your property there before your first foreign guest. NammaStay stores the passport details you'll need, but doesn't file Form C for you.
- **Aadhaar:** NammaStay keeps only the last 4 digits. Ask guests for a masked Aadhaar where possible.
- **DPDP Act:** collect only what you need, say why (the consent tick box on self check-in does this), keep ID photos only as long as required (retention setting), and delete on request.
- Show a short privacy notice at the front desk and on the website.

## 14. Pre-launch test script (do it on your phone and laptop)

1. Sign in; wrong password shows an error; "Forgot?" sends an email.
2. New booking for tonight → **Confirm booking & check in** → shows as checked in on Dashboard, Rooms and Calendar.
3. Try booking the **same bed, same dates** → blocked with "already booked".
4. Record a partial UPI payment with a UTR → balance updates. Re-enter the same UTR → refused.
5. Try checking out with a balance → warning appears.
6. Copy the online check-in link → open it in a private window on your phone → fill it in with an ID photo → bell badge lights up; photo opens from the booking.
7. Sign in as a front-desk test user: Reports and Settings are hidden; opening `reports.html` directly says no access.
8. Sign out → opening `dashboard.html` sends you to sign in.
9. Cancel a booking → bed becomes free again.
10. Export payments CSV → opens correctly in Excel/Sheets.

## 15. Running it

- **Monitoring:** Supabase → Reports (API, database) and Logs; Edge Function logs for email failures.
- **Changes to the database:** write a new numbered file (`006_...sql`), try it on the test project first, then run on live, then re-run the security checks.
- **Updating the site:** edit files → upload to GitHub. Hard-refresh (Ctrl+Shift+R) to see changes.
- **If something breaks:** the website itself can't lose data; all data is in Supabase. Worst case, restore yesterday's backup.

## Monthly cost at launch

| Item | Cost |
|---|---|
| GitHub Pages | Free (public repo) |
| Domain | What you already pay |
| Supabase | Free while testing; Pro ≈ US$25/month for live guest data |
| Resend email | Has a free tier; check its current limits against your booking volume |
| UPI | ₹0 — no gateway fees |
