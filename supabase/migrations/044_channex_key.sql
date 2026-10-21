-- NammaStay · 044 · Channex API key saved from the admin screen (no Supabase secrets needed)
-- Additive only: one new table + 4 new functions. Nothing existing is changed.
-- The key is never readable from the website: only the server function (service role) can read it.
-- Run once in Supabase → SQL Editor. Undo: rollback_044_channex_key.sql

create table if not exists public.cx_settings (
  id          boolean primary key default true check (id),        -- exactly one row
  api_key     text,
  base_url    text not null default 'https://staging.channex.io'
              check (base_url in ('https://staging.channex.io', 'https://app.channex.io')),
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
alter table public.cx_settings enable row level security;              -- no policies → no direct access for anyone
revoke all on public.cx_settings from public, anon, authenticated;

-- Admin screen: is a key saved? (never returns the key itself, only the last 4 characters)
create or replace function public.cx_key_status() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.cx_settings;
begin
  perform public._assert_platform_admin();
  select * into r from public.cx_settings where id;
  return jsonb_build_object(
    'set', coalesce(length(r.api_key), 0) > 0,
    'last4', case when length(r.api_key) >= 4 then right(r.api_key, 4) end,
    'base_url', coalesce(r.base_url, 'https://staging.channex.io'),
    'live', coalesce(r.base_url, '') = 'https://app.channex.io',
    'updated_at', r.updated_at);
end $$;

-- Admin screen: save the key and/or switch Test ↔ Live. p_key null = keep the saved key.
create or replace function public.cx_key_save(p_key text, p_live boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text := nullif(btrim(coalesce(p_key, '')), '');
        v_url text := case when p_live then 'https://app.channex.io' else 'https://staging.channex.io' end;
begin
  perform public._assert_platform_admin();
  if v_key is not null and (length(v_key) < 20 or length(v_key) > 300 or v_key ~ '\s') then
    raise exception 'That doesn''t look like a Channex API key. Copy it again from Channex → API keys.' using errcode = '22023';
  end if;
  insert into public.cx_settings (id, api_key, base_url, updated_at, updated_by)
  values (true, v_key, v_url, now(), auth.uid())
  on conflict (id) do update set api_key = coalesce(v_key, public.cx_settings.api_key),
    base_url = v_url, updated_at = now(), updated_by = auth.uid();
  return public.cx_key_status();
end $$;

-- Admin screen: remove the saved key (the server falls back to the CHANNEX_API_KEY secret, if any)
create or replace function public.cx_key_clear() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public._assert_platform_admin();
  update public.cx_settings set api_key = null, updated_at = now(), updated_by = auth.uid() where id;
  return public.cx_key_status();
end $$;

-- Server function only (service role): the saved key + address
create or replace function public._cx_key() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('api_key', api_key, 'base_url', base_url) from public.cx_settings where id
$$;

revoke all on function public.cx_key_status(), public.cx_key_save(text, boolean), public.cx_key_clear(), public._cx_key()
  from public, anon, authenticated;
grant execute on function public.cx_key_status(), public.cx_key_save(text, boolean), public.cx_key_clear() to authenticated;
grant execute on function public._cx_key() to service_role;
