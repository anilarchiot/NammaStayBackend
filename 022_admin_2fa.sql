-- =====================================================================
-- NammaStay · 022_admin_2fa.sql
-- The admin website (thenammastay.com/admin-login.html) uses 2-step login: password
-- + a 6-digit code from an authenticator app (Google Authenticator,
-- Microsoft Authenticator, Authy…). Supabase calls this MFA / TOTP.
-- Once an admin has set up their authenticator, every admin action
-- (Overview, Subscribers, Leads, approving payments, prices…) is refused
-- unless that sign-in was confirmed with the code (session level "aal2").
-- Before setup, the admin website forces setup on first sign-in.
-- Run AFTER 021_expenses_paylinks.sql.
-- =====================================================================

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
     and (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
          or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'))
$$;

-- For the admin sign-in page: is this login an admin, has it set up the authenticator, was the code entered?
create or replace function public.admin_mfa_info() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'admin', exists (select 1 from public.platform_admins where user_id = auth.uid()),
    'has_factor', exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'),
    'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'))
$$;
revoke execute on function public.admin_mfa_info() from public, anon;
grant execute on function public.admin_mfa_info() to authenticated;

-- Lost your phone? Run this (with the admin's email) to remove their authenticator,
-- then they set it up again at the next sign-in:
--   delete from auth.mfa_factors where user_id = (select id from auth.users where lower(email) = lower('admin@thenammastay.com'));
