# NammaStay — backend

Database, security rules and server functions for NammaStay, running on **Supabase**.
The website lives in the separate frontend repo (**NammaStayFrontend**, served by GitHub Pages).

> GitHub doesn't run this code — it's stored here for history and backup.
> Supabase runs it: the SQL is pasted into Supabase's SQL Editor, and the
> functions are deployed by the GitHub Action in `.github/workflows/`.

| Path | What it is |
|---|---|
| `supabase/SETUP_ALL.sql` | Complete database in one file (001 + 002 + 003 + 006 + 007 + 008). Paste once into SQL Editor on a new project. |
| `supabase/migrations/001_schema.sql` | Tables, indexes, double-booking guard, triggers |
| `supabase/migrations/002_security.sql` | Row Level Security, roles, private ID-photo bucket |
| `supabase/migrations/003_functions.sql` | Every query the app uses (bookings, payments, reports, self check-in…) |
| `supabase/migrations/006_marketing.sql` | Homepage contact form (leads) + admin |
| `supabase/migrations/007_subscriptions.sql` | Plans, 15-day trial, UPI subscription payments, access enforcement |
| `supabase/migrations/008_delete_booking.sql` | Delete bookings entered by mistake (copy kept in the activity log) |
| `supabase/migrations/009_edit_guest.sql` | Edit guest profiles (name, phone, email, DOB, ID, photo, notes) |
| `supabase/migrations/010_id_front_back.sql` | ID photos: front and back side |
| `supabase/migrations/011_admin_panel.sql` | Admin panel: overview of all properties, per-property detail, suspend / reactivate |
| `supabase/migrations/012_delete_guest.sql` | Delete a guest completely (profile, all bookings & payments, ID photos) |
| `supabase/migrations/013_admin_add_property.sql` | Admin adds a property for a customer; owner linked by email on sign-up |
| `supabase/migrations/014_hotels_homestays.sql` | Hotels & homestays: room capacity, adults/children, extra-guest charges |
| `supabase/migrations/015_plans_by_type.sql` | Subscription prices by property type and size |
| `supabase/migrations/016_extras.sql` | Extras on the bill: price list + charges (food, laundry, rentals…) |
| `supabase/migrations/017_role_permissions.sql` | Owner-configurable permissions per role, enforced in the database |
| `supabase/migrations/018_invoice_offers.sql` | GST invoices & receipts, regular-guest offers |
| `supabase/migrations/019_prices_oct_2026.sql` | New subscription prices (Oct 2026) |
| `supabase/migrations/020_ota_sync.sql` | OTA calendar sync (iCal): export links per bed/room, imported OTA bookings |
| `supabase/functions/ical`, `supabase/functions/ota-sync` | Serve calendar links · import OTA calendars every 30 min |
| `supabase/migrations/021_expenses_paylinks.sql` | Expenses & profit; Razorpay payment links (keys write-only) |
| `supabase/migrations/022_admin_2fa.sql` | Admin website: 2-step login required for all admin actions |
| `supabase/migrations/023_platform_invoices_reminders.sql` | GST invoices for subscriptions; trial/renewal reminders |
| `supabase/setup/undo_guest_app.sql` | Only if you ran the earlier 024_guest_app.sql — removes the guest app |
| `supabase/functions/billing-reminders` | Daily: creates reminders, emails owners (Resend) |
| `supabase/setup/reminders_schedule.sql` | Runs billing reminders every morning |
| `supabase/functions/razorpay` | Creates payment links, checks status, receives Razorpay webhooks |
| `supabase/setup/ota_schedule.sql` | Runs OTA sync every 30 minutes (edit project ref + secret first) |
| `supabase/setup/004_seed.sql` | Your hostel, rooms, 9 beds and owner login — edit the email first |
| `supabase/setup/005_schedule.sql` | Nightly ID-photo cleanup — edit project ref + secret first |
| `supabase/setup/undo_direct_booking.sql` | Only if you ran the earlier 018 with the booking page — removes the page |
| `supabase/setup/undo_formc_badges_expenses.sql` | Only if you ran the earlier Form C / badges / expenses migration — removes it |
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
