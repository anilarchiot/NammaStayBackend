-- =====================================================================
-- NammaStay · admin access
-- Gives YOUR login the NammaStay admin menu (Admin panel, Leads,
-- Subscribers) and makes you owner of your hostel.
-- 1. Replace your@email.com (3 places) with the email you sign in with.
-- 2. Paste in Supabase → SQL Editor → Run.
-- =====================================================================

-- platform admin
insert into public.platform_admins (user_id)
select id from auth.users where lower(email) = lower('your@email.com')
on conflict do nothing;

-- owner of Social Backpackers Hostel (skip if already owner)
insert into public.property_members (property_id, user_id, role, display_name, email)
select p.id, u.id, 'owner', 'Owner', u.email
from public.properties p, auth.users u
where p.name = 'Social Backpackers Hostel' and lower(u.email) = lower('your@email.com')
on conflict (property_id, user_id) do update set role = 'owner';

-- check: should list "platform admin" and "owner · Social Backpackers Hostel"
select u.email, 'platform admin' as access
from public.platform_admins a join auth.users u on u.id = a.user_id
union all
select m.email, m.role::text || ' · ' || p.name
from public.property_members m join public.properties p on p.id = m.property_id
where lower(m.email) = lower('your@email.com');

-- Admins sign in at https://thenammastay.com/admin-login.html (link "NammaStay admin login" on the sign-in page) with password + 6-digit code (set up on first sign-in).
-- Lost phone? Remove their authenticator; they set it up again at the next sign-in:
-- delete from auth.mfa_factors where user_id = (select id from auth.users where lower(email) = lower('your@email.com'));
