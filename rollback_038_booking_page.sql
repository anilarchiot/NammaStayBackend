-- Rollback of 038_booking_page.sql — removes the public booking page (Book direct).
-- Bookings made through the page STAY as normal bookings (source "direct"), with their payments.
-- WARNING: deletes page settings, the request list (WEB-…) and guest reviews.
-- Photos in the "stay-photos" bucket are NOT deleted here (Supabase blocks direct deletes from storage
-- tables): empty the bucket in Supabase → Storage → stay-photos first if you want them gone.
-- If you scheduled bp_expire_all with pg_cron: select cron.unschedule('nammastay-booking-page-expire');
drop function if exists public.bp_public(text);
drop function if exists public.bp_availability(text, date, date);
drop function if exists public.bp_request(text, jsonb);
drop function if exists public.bp_request_status(uuid);
drop function if exists public.bp_claim_paid(uuid, text);
drop function if exists public.bp_cancel_request(uuid);
drop function if exists public.bp_review_get(uuid);
drop function if exists public.bp_review_submit(uuid, integer, text, text);
drop function if exists public.bp_settings_get(uuid);
drop function if exists public.bp_settings_save(uuid, jsonb);
drop function if exists public.bp_slug_free(uuid, text);
drop function if exists public.bp_requests(uuid, text);
drop function if exists public.bp_request_decide(uuid, text, integer, text);
drop function if exists public.bp_counts(uuid);
drop function if exists public.bp_reviews(uuid);
drop function if exists public.bp_review_moderate(uuid, boolean, text);
drop function if exists public.bp_expire_all();
drop function if exists public._bp_request_json(public.booking_requests);
drop function if exists public._bp_licences(uuid);
drop function if exists public._bp_page_by_slug(text);
drop function if exists public._bp_expire(uuid);
drop function if exists public._bp_min_stay(uuid, uuid, date);
drop function if exists public._bp_free(public.properties, jsonb, tstzrange);
drop function if exists public._bp_rooms(uuid);
drop function if exists public._bp_range(public.properties, date, date);
drop function if exists public._bp_client_key();
drop function if exists public._bp_open(uuid);
drop function if exists public._bp_today(uuid);
drop policy if exists "stay-photos: staff upload" on storage.objects;
drop policy if exists "stay-photos: staff delete" on storage.objects;
drop table if exists public.stay_reviews;
drop table if exists public.booking_requests;
drop table if exists public.booking_pages;
drop sequence if exists public.booking_request_seq;
-- The empty bucket can be deleted in Supabase → Storage (or: delete from storage.buckets where id = 'stay-photos'; on a test copy).
