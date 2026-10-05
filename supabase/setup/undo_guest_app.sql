-- =====================================================================
-- NammaStay · undo_guest_app.sql
-- ONLY if you already ran 024_guest_app.sql. Removes the guest app from
-- the database (its functions, requests, feedback and settings column).
-- Bookings, online check-in and everything else stay as they are.
-- =====================================================================
drop function if exists public.guest_request_set(uuid, text, boolean);
drop function if exists public.guest_requests_open(uuid);
drop function if exists public.guest_payment_note(uuid, text);
drop function if exists public.guest_feedback_submit(uuid, int, text);
drop function if exists public.guest_request(uuid, jsonb);
drop function if exists public.guest_portal(uuid);
drop function if exists public._guest_booking(uuid);
drop table if exists public.guest_requests;
drop table if exists public.guest_feedback;
alter table public.properties drop column if exists guest_info;
