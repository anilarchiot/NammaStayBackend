-- Rollback of 036_investment.sql — removes My investment (investments, payback, legal documents).
-- WARNING: deletes the owners' investment entries and document records. Files in the "owner-docs"
-- bucket are NOT deleted here (Supabase blocks direct deletes from storage tables): empty the bucket in
-- Supabase → Storage → owner-docs first if you want them gone, then run this.
drop function if exists public.legal_checklist_get(uuid);
drop function if exists public.legal_checklist_save(uuid, jsonb);
drop function if exists public.invest_summary(uuid);
drop function if exists public.invest_settings_save(uuid, date);
drop function if exists public.investment_save(uuid, jsonb);
drop function if exists public.investment_delete(uuid);
drop function if exists public.legal_docs_list(uuid);
drop function if exists public.legal_doc_save(uuid, jsonb);
drop function if exists public.legal_doc_delete(uuid);
drop function if exists public.legal_docs_alerts(uuid);
drop function if exists public.legal_docs_remind_all();
drop function if exists public._legal_docs_notify(uuid);
drop function if exists public._inv_months(uuid, date);
drop function if exists public._inv_opened_on(uuid);
drop function if exists public._inv_today(uuid);
drop function if exists public._inv_owner(uuid);
drop policy if exists "owner-docs: owner read" on storage.objects;
drop policy if exists "owner-docs: owner upload" on storage.objects;
drop policy if exists "owner-docs: owner delete" on storage.objects;
drop table if exists public.legal_checklist;
drop table if exists public.legal_documents;
drop table if exists public.investments;
drop table if exists public.investment_settings;
-- The empty bucket can be deleted in Supabase → Storage (or: delete from storage.buckets where id = 'owner-docs'; on a test copy).
