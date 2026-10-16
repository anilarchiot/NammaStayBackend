NammaStay — SQL for Supabase (complete set, updates 001–043 · 16 Oct 2026)
==========================================================================
Everything is pasted into: supabase.com → your project → SQL Editor → New query → Run.
After each file you should see "Success. No rows returned" (or a small result table).
If you see a red error, STOP and send a screenshot.

A) BRAND-NEW, EMPTY SUPABASE PROJECT
   1. 1_NEW_PROJECT_SETUP_ALL.sql      ← builds the whole database in one go
   2. Authentication → Users → Add user (your email + strong password, tick "Auto Confirm User")
   3. 2_add_your_hostel_004_seed.sql   ← change owner@example.com to your email first
   4. 3_admin_access.sql               ← change your@email.com first
   5. 5_security_checks.sql            ← everything locked down? (see comments inside)
   (optional) optional_005_schedule.sql ← nightly ID-photo clean-up; fill in your project ref + secret first
   (optional) optional_ota_schedule.sql ← OTA calendar sync every 30 min (after deploying the ical + ota-sync functions)
   (optional) optional_channex_schedule.sql ← two-way channel manager every 5 min (after deploying the channex function)
   (optional) optional_reminders_schedule.sql ← trial/renewal reminders every morning (option A with email, or B in-app only)
   (optional) optional_pg_schedule.sql ← PG / co-living: create rent every night (pg_cron; else done when the page opens)

B) DATABASE ALREADY LIVE (most likely you)
   1. 4_check_which_updates_to_run.sql ← shows true/false for every update
   2. For every "false", run that file from the "updates" folder, in number order
      (e.g. updates/016_extras.sql, then 017_role_permissions.sql, then 018_invoice_offers.sql)
      Files 036–043 go together with their website update. Run each one only when its website
      update (the patches/ALL-CHANGES.diff in that pack) is deployed too:
        036_investment + 037_business_health ... owner tools pack
        038_booking_page ........................ booking page pack (direct booking, 0% commission)
        039_my_business ......................... my business pack
        040_company ............................. company pack (NammaStay admins only)
        041_smart_pricing ....................... smart pricing pack
        042_staff ............................... staff pack
        043_branches ............................ branches pack (owners with more than one property)
      Each one has a rollback_0xx file in this folder that removes it again.
      Skip 004_seed.sql and 005_schedule.sql in that folder — they're one-time setup.
   3. 3_admin_access.sql               ← only if the "NammaStay admin login" (thenammastay.com/admin-login.html) refuses your email
   4. 5_security_checks.sql
   Only if you ran these OLD files earlier:
      024_guest_app.sql                  → run updates/undo_guest_app.sql
      018_invoice_directbook_offers.sql  → run updates/undo_direct_booking.sql
      008_formc_badges_expenses.sql      → run updates/undo_formc_badges_expenses.sql

NEVER run 1_NEW_PROJECT_SETUP_ALL.sql on a live project — it is only for an empty one.

After the database:
   - Authentication → URL Configuration → Site URL: https://thenammastay.com
                                         Redirect URLs: https://thenammastay.com/**
   - Project Settings → API Keys → copy Project URL + anon/public key into assets/js/config.js
   - Upgrade to the Pro plan before real business (daily backups, never pauses).
