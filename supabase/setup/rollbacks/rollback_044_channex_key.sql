-- Undo 044: removes the saved Channex key and its functions. The CHANNEX_API_KEY secret (if any) keeps working.
drop function if exists public._cx_key();
drop function if exists public.cx_key_clear();
drop function if exists public.cx_key_save(text, boolean);
drop function if exists public.cx_key_status();
drop table if exists public.cx_settings;
