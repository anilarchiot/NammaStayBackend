-- =====================================================================
-- NammaStay · 006_marketing.sql
-- Backend for the marketing homepage (index.html):
--   • "Get early access" form → leads table
--   • spam protection: hidden honeypot field, duplicate check, rate limit
--   • you (platform admin) manage leads in the app at /leads.html
--   • email alert per lead via the notify-lead Edge Function
--
-- Run AFTER 001–003. Then make yourself a platform admin (bottom of file).
-- =====================================================================

-- ---------- Who runs NammaStay (you) — separate from hostel staff roles ----------
create table public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

-- ---------- Leads ----------
create type public.lead_status as enum ('new','contacted','demo_booked','won','lost');

create table public.leads (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(btrim(name)) between 2 and 80),
  phone         text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  email         text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  property_name text check (char_length(property_name) <= 120),
  city          text check (char_length(city) <= 80),
  property_type text check (property_type is null or property_type in ('hostel','homestay','hotel','other')),
  beds          int  check (beds is null or beds between 1 and 5000),
  message       text check (char_length(message) <= 1000),
  source        text check (char_length(source) <= 300),     -- utm / referrer
  status        public.lead_status not null default 'new',
  notes         text check (char_length(notes) <= 2000),     -- your private follow-up notes
  contacted_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (phone is not null or email is not null)
);
create index leads_recent on public.leads (created_at desc, id desc);
create index leads_status on public.leads (status, created_at desc);
create index leads_email  on public.leads (lower(email));
create index leads_phone  on public.leads (phone);
create trigger leads_touch before update on public.leads for each row execute function public._touch_updated_at();

alter table public.platform_admins enable row level security;
alter table public.leads enable row level security;
create policy leads_admin_select on public.leads for select to authenticated using (public.is_platform_admin());
create policy admins_self_select on public.platform_admins for select to authenticated using (user_id = (select auth.uid()));

revoke all on public.leads, public.platform_admins from anon, authenticated;
grant select on public.leads, public.platform_admins to authenticated;   -- RLS limits it to admins

-- ---------- Public form submit (no login) ----------
create or replace function public.submit_lead(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_name  text := btrim(coalesce(p->>'name', ''));
  v_phone text := public._clean_phone(p->>'phone');
  v_email text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_type  text := nullif(p->>'property_type', '');
  v_beds  int;
begin
  -- Bots fill the hidden "website" field; humans never see it. Pretend success.
  if coalesce(p->>'website', '') <> '' then return jsonb_build_object('ok', true); end if;

  if char_length(v_name) < 2 then raise exception 'Please enter your name.'; end if;
  if v_phone is null and v_email is null then raise exception 'Please enter a phone number or email so we can reach you.'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please check the phone number.'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please check the email address.'; end if;
  if v_type is not null and v_type not in ('hostel','homestay','hotel','other') then v_type := 'other'; end if;
  begin v_beds := nullif(p->>'beds', '')::int; exception when others then v_beds := null; end;
  if v_beds is not null and (v_beds < 1 or v_beds > 5000) then v_beds := null; end if;

  -- Same person again within 10 minutes: accept quietly, don't duplicate
  if exists (select 1 from public.leads
              where created_at > now() - interval '10 minutes'
                and ((v_phone is not null and phone = v_phone) or (v_email is not null and lower(email) = v_email))) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  -- Flood guard for the whole form
  if (select count(*) from public.leads where created_at > now() - interval '1 minute') >= 20 then
    raise exception 'We''re getting a lot of requests right now. Please try again in a minute.';
  end if;

  insert into public.leads (name, phone, email, property_name, city, property_type, beds, message, source)
  values (left(v_name, 80), v_phone, v_email,
          left(nullif(btrim(p->>'property_name'), ''), 120), left(nullif(btrim(p->>'city'), ''), 80),
          v_type, v_beds, left(nullif(btrim(p->>'message'), ''), 1000), left(nullif(btrim(p->>'source'), ''), 300));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Admin: manage leads (used by /leads.html) ----------
create or replace function public.list_leads(
  p_status text default null, p_q text default null,
  p_cursor_at timestamptz default null, p_cursor_id uuid default null, p_limit int default 50)
returns setof public.leads
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := nullif(btrim(p_q), ''); v_d text;
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  v_d := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  return query
  select * from public.leads l
   where (p_status is null or l.status = p_status::public.lead_status)
     and (v_q is null or l.name ilike '%' || v_q || '%' or l.email ilike '%' || v_q || '%'
          or l.property_name ilike '%' || v_q || '%' or l.city ilike '%' || v_q || '%'
          or (length(v_d) >= 4 and l.phone like '%' || v_d || '%'))
     and (p_cursor_at is null or (l.created_at, l.id) < (p_cursor_at, p_cursor_id))
   order by l.created_at desc, l.id desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;

create or replace function public.lead_counts() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v
    from (select status, count(*) n from public.leads group by status) s;
  return v || jsonb_build_object('all', (select count(*) from public.leads),
                                 'last_7_days', (select count(*) from public.leads where created_at > now() - interval '7 days'));
end $$;

create or replace function public.update_lead(p_id uuid, p_status text default null, p_notes text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_platform_admin() then raise exception 'You don''t have permission to do this.' using errcode = '42501'; end if;
  update public.leads
     set status = coalesce(p_status::public.lead_status, status),
         notes  = coalesce(p_notes, notes),
         contacted_at = case when p_status is not null and p_status <> 'new' and contacted_at is null then now() else contacted_at end
   where id = p_id;
  if not found then raise exception 'Lead not found.'; end if;
end $$;

-- ---------- Execute permissions ----------
revoke execute on function public.is_platform_admin(), public.submit_lead(jsonb),
  public.list_leads(text, text, timestamptz, uuid, int), public.lead_counts(), public.update_lead(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.submit_lead(jsonb) to anon, authenticated;
grant execute on function public.is_platform_admin(), public.list_leads(text, text, timestamptz, uuid, int),
  public.lead_counts(), public.update_lead(uuid, text, text) to authenticated;

-- ---------- Make yourself the platform admin ----------
-- Replace the email with your own login (the same one used in 004_seed.sql), then run:
-- insert into public.platform_admins (user_id)
--   select id from auth.users where lower(email) = lower('owner@example.com')
-- on conflict do nothing;
