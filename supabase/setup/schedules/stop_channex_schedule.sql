-- =====================================================================
-- NammaStay · stop_channex_schedule.sql — Channex is replaced by OTA sync through Beds24 (046).
-- Stops the every-5-minutes Channex job (channex_schedule.sql). Nothing is deleted: the Channex tables,
-- any saved Channex links and the `channex` edge function stay as they are, just unused.
-- Before running: if a property is still linked to Channex, end that connection in each OTA extranet
-- (Booking.com: Account → Connectivity provider) so it can accept Beds24 instead.
-- Undo: run channex_schedule.sql again.
-- =====================================================================
select cron.unschedule('nammastay-channex') where exists (select 1 from cron.job where jobname = 'nammastay-channex');
