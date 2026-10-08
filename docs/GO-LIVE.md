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
| `supabase/migrations/001–003, 006–028` | The database structure: run in order (or `SETUP_ALL.sql`). |
| `supabase/setup/004_seed.sql`, `005_schedule.sql` | One-time setup you edit before running. |
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
4. `supabase/migrations/006_marketing.sql` — homepage contact form (leads)
5. `supabase/migrations/007_subscriptions.sql` — plans, 15-day trial, UPI subscription payments
6. `supabase/migrations/008_delete_booking.sql` — delete bookings entered by mistake
7. `supabase/migrations/009_edit_guest.sql` — edit guest profiles
8. `supabase/migrations/010_id_front_back.sql` — ID photos: front and back
9. `supabase/migrations/011_admin_panel.sql` — admin panel & account suspension
10. `supabase/migrations/012_delete_guest.sql` — delete a guest completely
11. `supabase/migrations/013_admin_add_property.sql` — add a property for a customer
12. `supabase/migrations/014_hotels_homestays.sql` — hotels & homestays: rooms, guests, extra-guest charges
13. `supabase/migrations/015_plans_by_type.sql` — subscription prices by property type and size
14. `supabase/migrations/016_extras.sql` — extras on the bill (food, laundry, rentals…)
15. `supabase/migrations/017_role_permissions.sql` — what each role can do
16. `supabase/migrations/018_invoice_offers.sql` — GST invoices & receipts, regular-guest offers
17. `supabase/migrations/019_prices_oct_2026.sql` — new subscription prices
18. `supabase/migrations/020_ota_sync.sql` — OTA calendar sync (iCal)
19. `supabase/migrations/021_expenses_paylinks.sql` — expenses & profit, Razorpay payment links
20. `supabase/migrations/022_admin_2fa.sql` — 2-step login for the admin website
21. `supabase/migrations/023_platform_invoices_reminders.sql` — GST invoices for subscriptions + billing reminders
22. `supabase/migrations/024_form_c.sql` — Form C for foreign guests
23. `supabase/migrations/025_admin_growth.sql` — admin: health, revenue, coupons, activity log, lead → property
24. `supabase/migrations/026_pricing_housekeeping.sql` — seasonal & weekend pricing, housekeeping board
25. `supabase/migrations/027_channex.sql` — two-way channel manager (Channex)
26. `supabase/migrations/028_onboarding.sql` — setup wizard for new owners

Shortcut: `supabase/SETUP_ALL.sql` contains all sixteen in one file — paste it once and Run.

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
- Keep **"Allow new users to sign up" ON** — owners start their free trial from `/signup.html`. New accounts can't see anything until they create their own property (Row Level Security), and each account can create only one.
- Keep **"Confirm email" ON**, so every sign-up proves it owns the email.
- Minimum password length: **10**.
- Set up **custom SMTP** (below) *before* sharing the sign-up link — the built-in sender can't handle public sign-ups.

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
     WEBHOOK_SECRET=$WEBHOOK_SECRET CRON_SECRET=$CRON_SECRET APP_URL=https://app.thenammastay.com
   supabase functions deploy notify-booking --no-verify-jwt
   supabase functions deploy purge-id-docs  --no-verify-jwt
   ```
   (`--no-verify-jwt` is right here: these functions check their own secret header instead of a staff login.)
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


---

## 16. Subscriptions (manual UPI)

How it works:
1. An owner signs up at `/signup.html`, creates their property, and gets a **15-day free trial** (Settings → Billing shows days left; a banner appears on every screen).
2. To pay, they pick Monthly or Yearly in **Settings → Billing**, pay **your** UPI ID by QR, and submit the UTR.
3. You open **Subscribers** in the app, check the UTR arrived in your bank app, and click **Approve** — their access is extended by the plan period (from the later of today, their trial end, or their current paid-until date, so nobody loses days).
4. When access ends there are **3 grace days**; after that the database refuses new bookings, new/changed rooms & beds and new staff. Existing guests can still be checked out and paid; all data stays visible.

Set up once (Subscribers → Billing settings): your UPI ID, payee name, support WhatsApp/email, prices, trial days, grace days.
Your own hostel is marked **complimentary** (never expires). Partners too: Subscribers → Manage → Complimentary.

**Already live?** Run only `supabase/migrations/007_subscriptions.sql`, then turn sign-ups back on (step 4).


---

## 17. Deleting wrong bookings & booking from the calendar (008)

**Already live?** Run `supabase/migrations/008_delete_booking.sql` in SQL Editor.
(If you ran `008_formc_badges_expenses.sql` earlier, first run `supabase/setup/undo_formc_badges_expenses.sql`. If you ran the earlier `008_delete_guest.sql`, that's harmless — leave it.)

**Delete booking** — on the booking screen (bottom left), the trash icon on each row of a guest's **stay history**, or tap the guest's bar on the **Calendar** → Delete booking. For a stay entered by mistake, including a guest who is checked in now:
- Removes only that booking; the bed becomes free. The guest's profile and other stays are untouched.
- Payments on that booking are deleted with it (the dialog warns you first).
- Owner/manager: any booking. Front desk: only bookings made in the last 24 hours with no payment.
- A full copy (booking, guest, payments, reason, who, when) is kept — Settings → Notifications → **Deleted bookings**.
- To end a real stay early, use **Check out**, not Delete.

**Book from the calendar:** drag across a bed's free nights (on a phone: tap the first night, then the last). A quick form opens with the bed and dates filled in — name, phone (finds returning guests), status, payment. "Open the full form" goes to Check-in with the same bed and dates for ID details.


## 18. WhatsApp booking details — poster card or text

After saving a booking (Check-in page or calendar) — or any time from a booking → **WhatsApp details** — NammaStay prepares the confirmation two ways:
- **🖼 Picture card** — a tall **poster** (story size) with the guest's first name, big check-in / check-out dates and times, bed or room, booking number, guests (hotels/homestays) or nights, balance due or total, and your address and phone.
  - Phone: **Share card** → WhatsApp → the guest (image + short caption with the online check-in link).
  - Computer: **Copy image** → paste (Ctrl+V) in the WhatsApp Web chat (**Open chat** opens it), or **Download**.
- **💬 Text message**: editable text → **Open WhatsApp** (free click-to-chat link).
WhatsApp's click-to-chat link can only carry text, which is why images go through Share / Copy. Fully automatic sending would need the paid WhatsApp Business API.

## 19. Edit guest profile (009)

**Already live?** Run `supabase/migrations/009_edit_guest.sql`.
Guest profile → **✎ Edit profile** (owner, manager, front desk): name, phone, email, date of birth, nationality, ID type & number, ID photo (the old photo is deleted when replaced) and notes. Phone numbers get +91 when 10 digits; Aadhaar is kept masked (last 4 digits). Each edit is logged (which fields changed, not the values).

## 20. ID photos — front & back (010)

**Already live?** Run `supabase/migrations/010_id_front_back.sql`.
Staff (Check-in page, Edit profile) and guests (online check-in link) can upload a **front** and a **back** photo; each shows a preview before saving. **View ID** now opens inside the app with both sides, plus **Open full size** and **Download** (links expire after 5 minutes). Both sides are deleted automatically after the retention period.

## 21. Admin panel (011)

**Already live?** Run `supabase/migrations/011_admin_panel.sql` (needs 007 first). Only platform admins (step 3) see it — menu → **NammaStay admin → Admin panel**.
- **Overview:** paying / trial / payment due / ended / suspended counts, estimated monthly revenue, sign-ups per week, bookings made across all properties, payments waiting for confirmation.
- **Needs attention:** trials ending in 3 days, payment due, properties not active for 2+ weeks.
- **Each property:** owner & contact (WhatsApp / email), usage (beds, bookings, last active), team, subscription payments, private notes.
- **Actions:** +30 days, +1 year, extend by any days, make free, **suspend / reactivate** (the owner sees your reason; new bookings, rooms, beds and staff are blocked by the database until you reactivate).

## 22. Delete a guest completely (012)

**Already live?** Run `supabase/migrations/012_delete_guest.sql`.
Guest profile → **Delete guest**, or the 🗑 on a row in the **Guests** list (owner and manager only). Removes the guest's profile, all their bookings (any status), the payments on them and their ID photos. The dialog shows how many bookings and how much money will be removed and asks you to tick "I understand". A copy of each deleted booking is kept in Settings → Notifications → Deleted bookings ("Guest deleted: <reason>").
To remove only one stay, use the 🗑 on that row in the guest's Stay history instead.

## 23. Adding a property for a customer (013)

**Already live?** Run `supabase/migrations/013_admin_add_property.sql` (needs 007 and 011).
Two ways a new hostel/hotel gets on NammaStay:
1. **They sign up themselves** at `/signup.html` → create login → name their property → 15-day trial.
2. **You add it:** Admin panel → **+ Add property** → property name, type, city, address, owner's name, phone and **email**, free trial (days) or complimentary, optional private note. Tick **Add me as manager** to set up their rooms, beds and rates yourself (switch property by tapping the property name under your name in the menu).
   - If that email already has a NammaStay login, the property is added to their account straight away (they can switch between properties).
   - Otherwise NammaStay gives you a ready message with their sign-up link (email pre-filled) to send by **WhatsApp** or **email**. When they create a login with that email, they're linked as **owner** automatically. The property page shows "Waiting for the owner to sign up" until then, with **Send sign-up link** to resend.

## 24. Hotels & homestays (014)

**Already live?** Run `supabase/migrations/014_hotels_homestays.sql` (needs 010).
The property type (chosen at sign-up, or Settings → Property details → Type) changes how NammaStay works:
- **Hostel / PG:** sells **beds**; menu says "Rooms & beds"; 1 guest per bed; reports show RevPAB.
- **Hotel / Homestay:** sells **rooms**; menu says "Rooms"; reports show RevPAR.
  - **Rooms → + Add room type:** name (e.g. Deluxe Double), description, **how many rooms** and the **first room number** (101 → 101, 102, 103…), rate per night, **max guests**, **guests included** in the rate, **extra adult ₹/night** (children free).
  - **Bookings** ask for **adults + children**, refuse more guests than the room fits, and add the extra-adult charge: total = nights × (rate + extra).
  - **Several rooms in one booking** (families, groups): Check-in → **+ Add another room**. One booking per room for the same guest; any payment taken is recorded on the first.
  - WhatsApp message and ticket show **Room** and **Guests**.
Hostels can also book several beds at once (**+ Add another bed**) for groups.

## 25. Prices by property type & size (015)

**Already live?** Run `supabase/migrations/015_plans_by_type.sql` (needs 007).

| Type | Size | Monthly | Yearly |
|---|---|---|---|
| Homestay | up to 6 rooms | ₹999 | ₹9,990 |
| Hostel / PG | any size | ₹1,650 | ₹16,500 |
| Hotel | up to 20 rooms | ₹2,499 | ₹24,990 |
| Hotel | 21–50 rooms | ₹3,999 | ₹39,990 |
| Hotel | 51+ rooms | custom quote ("Contact us", no online payment) | — |

Each owner's **Settings → Billing** shows only the plans that fit their property (type + number of active rooms/beds); a homestay above 6 rooms gets hotel prices. The homepage Pricing section has Hostel / Homestay / Hotel tabs and loads the live prices.
Change prices, labels, room limits or switch a plan off in **Subscribers → Billing settings**. "Rooms" means active beds for hostels.

## 26. Sign-in safety (frontend only — no SQL)

- **Demo never switches on by itself.** With Supabase keys in `config.js`, sign-in always needs a real account. Keys missing → "Not connected yet" and nobody can sign in. The sample-data demo opens only via `login.html?demo=1` (homepage "Try the live demo"); it runs in the visitor's browser, never touches real data, and has **Exit demo**.
- **No silent skip:** if someone is already signed in on a device, the sign-in page asks "You're signed in as … — Continue / Not you? Sign out".
- **Keep me signed in:** unticked → signed out when the browser is closed (use this on shared front-desk computers).
- **Sign out on all devices:** Settings → Users & roles (or My account).
- **Settings → My account:** change your password (needs the current one), change your email (confirmed by a link to the new address).

## 27. Maintenance on the calendar & guest export (frontend only — no SQL)

- **Block for maintenance:** Calendar → drag across a bed's/room's free nights (phone: tap first and last night) → switch to **🔧 Maintenance** → reason (or tap Repair / Deep cleaning / Pest control / Painting / Owner use) → **Block for maintenance**.
- **Change or remove:** tap the 🔧 bar → edit reason/dates → **Save changes**, or **Remove maintenance**. Also on **Rooms**: tap a Maintenance tile → **Remove**.
- **Export guests:** Guests → **Export CSV** (owner/manager): name, phone, email, nationality, date of birth, ID type, ID number (Aadhaar masked), stays, nights, upcoming bookings, total paid, last stay, added on, notes. Contains personal data — keep it private.

## 28. Check-in list (frontend only — no SQL)

Menu → **Check-in** now opens on a list instead of the form:
- **Arriving today** (late arrivals from earlier days flagged) with a **Check in** button — if money is still due, the booking opens after check-in so you can take it.
- **Checked in today**, with **WhatsApp** to send the welcome poster.
- **Next 7 days** of arrivals. Search by guest, booking number or bed/room.
- **+ New registration** opens the guest registration form. All "+ New booking" buttons elsewhere open the form directly.

## 29. Extras — food, laundry & other services (016)

**Already live?** Run `supabase/migrations/016_extras.sql` (needs 014).
- **Price list:** Settings → Room types & pricing → **Extras & services** → **Add suggested items** (breakfast, lunch, dinner, tea, laundry, towel, locker, bike, airport pickup, city tour) or **+ Add item**; set price and "per" (plate, kg, day, trip…); untick **Offered** to hide one; **Save extras**. Owner/manager only.
- **Add to a bill:** booking → **+ Add extra** → tap an item (or **Something else…**), quantity (0.5 steps, e.g. 2.5 kg), adjust the price if needed, note → **Add to bill**. Front desk can do this too.
- The booking **total and balance due include extras**; collect with Record payment. Changing the stay dates keeps the extras. The WhatsApp poster shows the new balance.
- **Remove** with 🗑 — not possible once that money has been paid (record a refund instead). Every add/remove appears in the booking's Activity.

## 30. Role permissions & country dropdown (017)

**Already live?** Run `supabase/migrations/017_role_permissions.sql` (needs 016).
- **Settings → Users & roles → What each role can do** (owner edits; others can only look): tick per role — see reports & revenue, see payments, take payments, give refunds, cancel bookings, delete bookings, delete guests, change rooms/beds/prices, add extras, export CSV. 🔒 = never possible for that role (e.g. front desk can't refund or delete a whole guest; the accountant can't change bookings). **Reset to defaults** restores the standard setup.
- Enforced in the database (payments, refunds, cancelling, deleting, rooms & prices, extras, reports and the payments list), and the app hides what a role can't use. Staff see changes next time they open a page.
- The owner can always do everything; the platform admin keeps the Admin panel.
- **Nationality** is now a country dropdown (India first) on the check-in form, Edit guest profile and the guest's online check-in.

## 31. GST invoices, languages, regular-guest offers (018)

**Already live?** Run `supabase/migrations/018_invoice_offers.sql` (needs 017).
(If you ran the earlier `018_invoice_directbook_offers.sql`, run `supabase/setup/undo_direct_booking.sql` instead — it removes only the booking page.)

**Invoices & receipts** — Settings → Property details → **Invoices & GST**: Not registered (simple bill) · Automatic by room rate (nil ≤ ₹1,000 · 5% ≤ ₹7,500 · 18% above) · Fixed rate; GSTIN, legal name, food/extras GST %, invoice prefix. Prices include GST; CGST + SGST split. Open an invoice from: the **Booking saved** pop-up (🧾 Invoice / bill), the booking screen (**🧾 Invoice**), or the 🧾 icon on each row of a guest's **Stay history**. Numbered per financial year (INV/2026-27/0001; same bill → same number); **Bill to a company (GSTIN)**; Print / Download PDF / Share. Each payment has a **Receipt**. Confirm GST rates with your CA.

**Languages** — Tamil, Kannada, Telugu, Malayalam: switch at the bottom of the menu, on the sign-in page and on the guest check-in page. Menus, buttons, labels and headings are translated; longer messages stay in English for now (have a native speaker review the wording).

**Regular-guest offers** — Settings → **Regular-guest offers** → On; e.g. from stay no. 2 get 5% off, from stay no. 5 get 10%. Applied automatically when staff book a returning guest (room charge only, max 50%); shown on the booking and the invoice. Owner/manager: **Change** (0 removes) or **Discount** on any booking.

## 32. Existing guests fill in automatically (frontend only — no SQL)

Check-in → **+ New registration**: start typing the guest's **name (3+ letters)** or **phone (6+ digits)** → a list of matching past guests appears (face, phone, nationality, last stay) → tap one → name, phone, email, date of birth, nationality and ID fill in, and the booking goes on their **existing profile** (no duplicate guest). A green banner shows how many stays they've had and whether a regular-guest offer applies; **Not them? Clear** starts fresh; **Edit profile** opens their profile. If they have no ID photo yet, add one here and it's saved to their profile. The calendar's quick-booking form also finds guests by name or phone.

## 33. Move a booking on the calendar (frontend only — no SQL)

- **Computer:** drag a guest's bar to other dates and/or another bed/room. Target nights glow green (free) or red (booked/blocked); drop → **Move booking?** shows From → To → confirm.
- **Phone:** tap the bar → **Move…** → tap the new first night on any bed/room → confirm.
- Same number of nights and the same check-in/check-out times; moving to another bed/room uses that bed's rate.
- Checked-in guests can only change bed/room (same dates); checked-out stays can't be moved. The database re-checks everything (double bookings, maintenance, capacity, already-paid amounts).

## 34. Subscription prices — October 2026 (019)

**Already live?** Run `supabase/migrations/019_prices_oct_2026.sql`.

| Type | Size | Monthly | Yearly |
|---|---|---|---|
| Hostel / PG | any | ₹3,999 | ₹27,999 (save ₹19,989) |
| Homestay | ≤ 6 rooms | ₹1,999 | ₹12,999 (save ₹10,989) |
| Hotel | ≤ 20 rooms | ₹3,999 | ₹27,999 (save ₹19,989) |
| Hotel | 21–50 rooms | ₹6,999 | ₹45,999 (save ₹37,989) |
| Hotel | 51+ | custom quote | — |

Existing paid-until dates stay; the new price applies at the next payment. Change any price later in Subscribers → Billing settings.

## 35. OTA calendar sync — Airbnb, Booking.com, Agoda, Vrbo (020)

**1. Database** — SQL Editor → run `supabase/migrations/020_ota_sync.sql`.

**2. Server functions** — two new functions: `ical` (serves each bed/room's calendar link) and `ota-sync` (imports OTA calendars).
- If you set up the GitHub Action (Secrets `SUPABASE_ACCESS_TOKEN` + `SUPABASE_PROJECT_ID`), pushing the backend repo deploys them.
- Otherwise, on a computer with the Supabase CLI: `supabase functions deploy ical --no-verify-jwt` and `supabase functions deploy ota-sync --no-verify-jwt`.
- Make sure the secret exists: `supabase secrets set CRON_SECRET=<a long random text>` (the same one used for the ID-photo clean-up).

**3. Every 30 minutes** — Database → Extensions → enable **pg_cron** and **pg_net**; then edit `supabase/setup/ota_schedule.sql` (project ref + CRON_SECRET) and run it.

**4. Connect your OTAs** — app → **OTA sync** (owner/manager):
- **Export:** for each bed/room, pick the OTA, **Copy** the NammaStay link, paste it into the OTA's "import / connect calendar".
- **Import:** copy the OTA's own calendar (export / iCal) link, choose the OTA, paste it next to that bed/room → **Add**. **Sync now** pulls it at once.
- OTA bookings show on the calendar as coloured 🔗 bars ("🔗 Airbnb") and can't be double-booked; change or cancel them on the OTA. Clashes with a NammaStay booking send a notification.
- If a link was shared by mistake, **Make a new link** and update it on the OTAs.

**Limits (iCal):** dates only (no prices or guest details); OTAs refresh imported calendars on their own schedule (often every few hours), so near-simultaneous bookings can still clash. Hostelworld, MakeMyTrip/Goibibo and Booking.com hotel/hostel listings generally need a certified channel manager (two-way API) rather than iCal.

## 36. Expenses & profit + online payment links (021)

**Database:** run `supabase/migrations/021_expenses_paylinks.sql`.

**Expenses & profit** (menu → Expenses & profit; owner, manager, accountant with "See reports & revenue"): add rent, salaries, bills, supplies, OTA commission… See money received − expenses = profit, margin, last 6 months and where the money went. Export CSV.

**Online payment links (Razorpay)** — money goes to each property's own Razorpay account:
1. Deploy the function: GitHub Action (pushing the backend repo), or `supabase functions deploy razorpay --no-verify-jwt`.
2. Owner → Settings → Property details → **Online payments (Razorpay)**: paste **Key ID** + **Key Secret** (Razorpay → Account & Settings → API Keys) and a **Webhook secret** you choose → Save → **Test connection**. Keys are stored write-only (nobody can read them back from the app).
3. Razorpay → Webhooks → Add: URL shown in that card (`…/functions/v1/razorpay?p=<property id>`), the same webhook secret, events **payment_link.paid**, **payment_link.expired**, **payment_link.cancelled**.
4. Booking → **💳 Payment link** → amount → Create → Copy / **Send on WhatsApp**. When the guest pays, the payment is recorded automatically ("Paid online — Razorpay payment link"); without a webhook, NammaStay checks whenever the booking is opened.
Start with test keys (rzp_test_…) and Razorpay's test payment methods, then switch to live keys.

## 37. Admin website — admin.thenammastay.com (022)

The admin screens (Overview, Subscribers, Leads) are now a **separate website** in their own GitHub repo
(`nammastay-admin-site.zip`). The hostel app no longer contains them; its old links (`/admin.html`,
`/subscribers.html`, `/leads.html`, `/admin-login.html`) redirect to the admin website.

Admins sign in with **password + a 6-digit code** from an authenticator app (set up on first sign-in by
scanning a QR code). After setup, the database refuses every admin action unless that sign-in used the code.

Setup: run `022_admin_2fa.sql`; Supabase → Authentication → MFA → TOTP on; add
`https://admin.thenammastay.com/**` to Redirect URLs; new GitHub repo + Pages; GoDaddy CNAME `admin` →
`anilarchiot.github.io`; Enforce HTTPS. Step-by-step: README.md in the admin site.
Lost phone: `delete from auth.mfa_factors where user_id = (select id from auth.users where lower(email) = lower('admin@…'));`

## 38. Subscription GST invoices + billing reminders (023)

**Database:** run `supabase/migrations/023_platform_invoices_reminders.sql`.

**Invoices (NammaStay → property)** — admin website → Subscribers → **Invoice settings**: legal name, your GSTIN (optional), address, state, SAC, GST %, prefix → Save → **Create invoices for past payments** (once). From then on every approved subscription payment gets an invoice automatically (NS/2026-27/0001…). Prices include GST; customer in your state → CGST + SGST, other state → IGST (by their GSTIN or chosen state). Owners: Settings → Billing → **Billing details** (name, GSTIN, address, state) and **Your invoices** (view / PDF / share). Admin: each property's payments show their invoice. Confirm SAC/rate with your CA.

**Reminders** — trial ending in 3 days / 1 day / ended, renewal in 7 days / 1 day / ended:
- In-app notification to the owner (always), email (if Resend is set up), and a **Reminders to follow up** card on the admin Overview with one-tap **WhatsApp** + **Done**.
- Daily schedule: edit and run `supabase/setup/reminders_schedule.sql` — option A (in-app + email, needs the `billing-reminders` function: GitHub Action or `supabase functions deploy billing-reminders --no-verify-jwt`; secrets CRON_SECRET, RESEND_API_KEY, MAIL_FROM, SITE_URL) or option B (in-app only, pure SQL). **Check now** on the admin Overview runs it at any time.

**Guest app removed.** If you ran `024_guest_app.sql` earlier, run `supabase/setup/undo_guest_app.sql` once.

## 40. Form C — foreign guests (024_form_c)

**Database:** run `supabase/migrations/024_form_c.sql`.

Every foreign guest must be reported to FRRO on Form C within 24 hours of arrival (indianfrro.gov.in/frro/FormC), and again after check-out. NammaStay:
- **Form C** menu (owner, manager, front desk) with a badge for reports due: tabs **Arrival due** (24-hour countdown, red when overdue), **Departure due**, **Arriving soon**, **Done**.
- **Passport & visa:** passport no/place/dates, visa no/type/place/dates, arrival in India, port, next destination, purpose, home address.
- **Copy for FRRO:** every value in the portal's order (dates dd/mm/yyyy) with a Copy button each, plus the guest's ID photos. Submit on the FRRO portal (captcha), then **Arrival submitted / Departure submitted** saves the FRRO number on the booking.
- Dashboard card "Form C due", a Form C line on foreign guests' bookings, and a reminder on the check-in form when a foreign nationality is chosen.
- Your property must be registered on indianfrro.gov.in for Form C (accommodation login) — that's done once with FRRO, outside NammaStay.

## 41. Admin: customer health, revenue & coupons, activity log, lead → property (025)

**Database:** run `supabase/migrations/025_admin_growth.sql`. **Admin website:** upload the new admin-site zip (new pages `revenue.html`, `activity.html`).

- **Customer health** (Overview, and each property's page): setup checklist — rooms, UPI, staff, first booking, first payment, regular use — and a 0–100 score (setup 40 + bookings in 14 days 30 + active days in 7 days 30). Lowest first: call the at-risk ones.
- **Revenue & coupons:** MRR (yearly plans ÷ 12), ARR, collected this month, paying vs trial, trial → paid in 90 days, ended in 30 days, 12-month chart, plan mix. **Coupons:** % or ₹ off, optional plans, max uses and expiry; owners enter the code in Settings → Billing; uses count when you approve the payment; the coupon shows on the pending payment.
- **Activity log:** every change made by an admin — payments approved/rejected, subscriptions extended/suspended/made free, prices, settings, properties, coupons, leads, admins — with before → after values.
- **Lead → property:** Leads → a lead → **Create property from this lead** opens Add property pre-filled; the lead is marked Won and linked.

## 42. Three websites: homepage, hostel app, admin

| Website | Address | GitHub repo | Zip |
|---|---|---|---|
| Homepage (marketing) | thenammastay.com | NammaStayFrontend (existing) | `nammastay-marketing-site.zip` |
| Hostel app | **app.thenammastay.com** | **NammaStayApp** (new) | `nammastay-hostel-app.zip` |
| Admin | admin.thenammastay.com | NammaStayAdmin | `nammastay-admin-site.zip` |

All three use the **same Supabase project** — paste the same Project URL + anon key into each repo's `assets/js/config.js`.

**Set up the hostel app (once):**
1. GitHub → New repository **NammaStayApp** → upload `nammastay-hostel-app.zip` contents (keep `CNAME`) → edit `assets/js/config.js` (keys).
2. Settings → Pages → Deploy from branch main / root → Custom domain `app.thenammastay.com`.
3. GoDaddy → DNS → Add **CNAME**: Name `app`, Value `anilarchiot.github.io`.
4. GitHub Pages → wait for "DNS check successful" → **Enforce HTTPS**.
5. Supabase → Authentication → URL Configuration: **Site URL** `https://app.thenammastay.com`; **Redirect URLs** add `https://app.thenammastay.com/**` (keep the others).
6. Supabase → Edge Functions → Secrets: remove `SITE_URL` if you set it; optional `APP_URL=https://app.thenammastay.com` (that's the default anyway).

**Then the homepage repo (NammaStayFrontend):** delete the old app files and upload `nammastay-marketing-site.zip` contents (keep your `config.js`). It contains the homepage plus small redirect pages, so old links — guests' check-in links, bookmarks like thenammastay.com/login.html — open on app.thenammastay.com automatically.

**Admin repo:** upload `nammastay-admin-site.zip` (keep your `config.js`, but check `siteUrl` is now `https://app.thenammastay.com`).

## 43. Seasonal & weekend pricing + housekeeping (026)

**Database:** run `supabase/migrations/026_pricing_housekeeping.sql`. **Hostel app:** upload the new app zip.

**Pricing** — Settings → Room types & pricing → **Seasonal & weekend pricing**:
- **Every week** (e.g. Fri & Sat nights +20%) or **Dates / season** (e.g. 20 Dec – 5 Jan +30%, optionally only some nights of the week).
- Change by % (+/−), ₹ a night (+/−), or a fixed price a night; all rooms or chosen rooms; optional minimum stay (2–7 nights).
- Dates beat weekends when both apply. New bookings (and date / bed changes) use the rules: the booking's nightly rate is the average of its nights, so totals, discounts, extras and invoices stay correct. Existing bookings keep their price. The booking form shows the price for the chosen dates; "Next 14 nights" previews each bed/room.

**Housekeeping** — menu → **Housekeeping** (badge = beds/rooms to clean):
- Check-out marks the bed/room **Dirty** automatically. Tap **Start cleaning → Mark ready**; ⋯ for Check / note ("change bedsheet").
- Beds with a guest **arriving today** come first ("clean first"). Dashboard card "N beds to clean".

## 44. Two-way channel manager — Channex (027) — TEST MODE first

Real-time, two-way connection with Booking.com, Agoda, Expedia, Airbnb, MakeMyTrip/Goibibo, Hostelworld, Yatra, Trip.com… through **Channex** (white-label channel manager API).

**What syncs**
- NammaStay → OTAs: free beds/rooms per night, prices for each night (your seasonal & weekend rules included), minimum stays. Pushed within minutes of any change (bookings, blocks, maintenance, price rules) and fully once a day.
- OTAs → NammaStay: new / changed / cancelled bookings, placed on a free bed/room of the mapped type with guest name, phone, email, amount, OTA reference ("Booking.com · 4417302981") and source "OTA". Each booking is acknowledged to Channex only after it is saved. If nothing is free (overbooking) or a guest is already checked in, the booking is listed with ⚠ and a notification.
- Each NammaStay room + price group (e.g. "6-Bed Mixed Dorm · ₹700" = 3 beds) is one Channex room type (`dorm` for hostels) with one "Standard" rate plan in INR.

**Set up the test account (free)**
1. Sign up at **https://staging.channex.io** → Settings → **API keys** → create a key.
2. Database: run `supabase/migrations/027_channex.sql`.
3. Supabase → Edge Functions → Secrets: `CHANNEX_API_KEY=<staging key>`, `CHANNEX_URL=https://staging.channex.io` (CRON_SECRET already set).
4. Deploy: GitHub Action (push the backend repo) or `supabase functions deploy channex --no-verify-jwt`.
5. Every 5 minutes: edit and run `supabase/setup/channex_schedule.sql`.
6. Hostel app → **OTA sync** → **Set up channel manager** (creates the property, room types, rate plans and sends 500 days of prices & availability) → **Connect your OTAs** (Channex's own screen inside NammaStay) → **Sync now**.
7. Test bookings: in the staging dashboard create an **Open Channel** (or the Booking.com test account Channex provides), map the rooms, create a test booking → it appears in NammaStay after Sync now / within 5 minutes.

**Going live:** sign the Channex WhiteLabel plan ($130/month + $7 per connected property), switch the secrets to the production URL and production key, and connect real OTA accounts. MakeMyTrip / Hostelworld connections are mapped and certified by Channex during onboarding. Keep iCal sync for anyone not on the channel manager.

## 45. Legal pages + setup wizard (028)

**Legal pages** (homepage site): `terms.html`, `privacy.html` (DPDP Act 2023: NammaStay is data fiduciary for owners' data and processor for guests' data; guests' data belongs to each property), `refund.html` (15-day trial; monthly not refundable once started; yearly full refund within 14 days; duplicates refunded; refunds in 7 working days). Linked from the homepage footer, sign-up ("I agree to the Terms and Privacy Policy") and guest online check-in. **Before launch:** fill in the Grievance Officer's name in `privacy.html` ([NAME]) and have a lawyer review all three. Razorpay asks for these pages when activating your account.

**Setup wizard** — run `supabase/migrations/028_onboarding.sql`. New owners go from sign-up to `setup.html`: property details → rooms & beds (hostel: dorm lines with bed type and price; hotel: room types numbered 101…) → UPI ID → invite team → "You're ready" with first booking, OTA connection and pricing shortcuts. The dashboard shows a "Finish setting up" checklist until done (or hidden). Properties with bookings are marked as set up automatically.
