NammaStay - complete SQL, one file per feature (16 Oct 2026)
=============================================================
Exported from a complete install of updates 001-043, so every function is its latest version.
Each file has the full code for its feature: CREATE TABLE, indexes, constraints, row-level security
policies, triggers, functions, grants, plus its storage bucket and default rows where it has one.

01_core_types_and_helpers.sql                  0 tables  33 functions   Enum types, access checks (role, permission, subscription), time helpers, trigger functions. Every other file needs this one.
02_properties_team_permissions.sql             5 tables   9 functions   Properties, team members, roles & permissions, owner invites, activity log, notifications
03_rooms_beds_prices.sql                       5 tables   8 functions   Rooms, beds, blocked beds, weekend & season prices, extras catalogue
04_guests_bookings_calendar.sql                2 tables  19 functions   Guests, bookings, calendar, dashboard, delete booking
05_checkin_id_formc.sql                        4 tables  12 functions   Self check-in, ID photos (bucket guest-ids) & automatic clean-up, more guests per booking, Form C
06_payments_invoices_expenses_reports.sql      7 tables  20 functions   Payments, extras charged, GST invoices, Razorpay payment links, expenses & profit, reports
07_housekeeping_setup_wizard.sql               0 tables   5 functions   Housekeeping board, first-time setup wizard
08_ota_channex_public_api.sql                  7 tables  31 functions   iCal OTA sync, Channex channel manager, public API
09_admin_subscriptions_leads.sql              11 tables  43 functions   NammaStay admin: leads, plans & subscriptions (with default plans), platform invoices, reminders, coupons, admin panel
10_pg_coliving.sql                             4 tables  28 functions   PG / co-living: tenants, monthly rent, deposits, PG screens
11_homestay_meals_guide.sql                    3 tables   9 functions   Homestay: meal plans, kitchen list, house guide
12_resort.sql                                 12 tables  40 functions   Resort: activities & spa, day-out visitors, stay packages, groups, extra beds
13_owner_tools.sql                            11 tables  37 functions   Owner tools: my investment, licences & documents (bucket owner-docs), business health, my business
14_company.sql                                 7 tables  22 functions   Company: NammaStay's own business numbers (platform admins only)
15_smart_pricing.sql                           6 tables  20 functions   Smart pricing (pack 041) - ready to deploy
16_branches.sql                                0 tables   7 functions   Branches (pack 043) - ready to deploy
17_booking_page.sql                            3 tables  28 functions   Booking page (pack 038, bucket stay-photos) - NOT integrated yet, hold back
18_staff.sql                                   9 tables  30 functions   Staff (pack 042, bucket staff-docs) - NOT integrated yet, hold back

Total: 96 tables, 401 functions.

HOW TO USE
- Reading / reviewing a feature: open its file.
- New, empty Supabase project: run the files in number order, 01 first (SQL Editor -> paste -> Run).
  Tested: running 01-18 in order builds a database identical to 1_NEW_PROJECT_SETUP_ALL.sql
  (same tables, columns, functions, indexes, constraints, triggers, policies, grants, buckets, default plans).
  To leave out the booking page and staff, skip 17 and 18.
- LIVE database (already has data): do NOT run these files there. Use 4_check_which_updates_to_run.sql
  and the files in updates/ (in nammastay-sql-complete.zip); those are written to be added on top of live data.
- A table that links to a table in a later file gets that link (and any rule that mentions it) in the later file,
  so the number order always works.
