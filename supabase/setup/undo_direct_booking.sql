-- =====================================================================
-- NammaStay · undo_direct_booking.sql
-- ONLY if you already ran the earlier 018_invoice_directbook_offers.sql.
-- Removes the public direct-booking page from the database (functions +
-- settings columns). Invoices and regular-guest offers are kept, and
-- bookings already made through the page stay as normal bookings.
-- =====================================================================
drop function if exists public.public_payment_note(uuid, text);
drop function if exists public.public_book(text, jsonb);
drop function if exists public.public_availability(text, date, date);
drop function if exists public.public_property(text);
drop function if exists public._public_window(public.properties, date, date);
drop function if exists public._public_prop(text);
alter table public.properties
  drop column if exists direct_booking, drop column if exists slug,
  drop column if exists booking_terms, drop column if exists direct_pay;
