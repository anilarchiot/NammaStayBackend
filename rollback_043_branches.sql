-- Rollback of 043_branches.sql — removes the branch functions (All branches page, Add branch, team across branches).
-- Branches already created stay as normal properties, each with its own subscription, rooms, bookings and team.
drop function if exists public.branch_create(jsonb);
drop function if exists public.branches_overview();
drop function if exists public.branch_access_set(uuid, uuid, text);
drop function if exists public.branch_team();
drop function if exists public._br_prefix(text, uuid);
drop function if exists public._br_assert_owner();
drop function if exists public._br_mode(uuid);
select to_regprocedure('public.branch_create(jsonb)') is null as branches_removed;
