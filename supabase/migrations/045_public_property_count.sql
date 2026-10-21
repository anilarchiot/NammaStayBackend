-- Public aggregate used by the login and signup pages. Exposes no property data.
create or replace function public.public_property_count() returns bigint
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*) from public.properties
$$;

revoke all on function public.public_property_count() from public, anon, authenticated;
grant execute on function public.public_property_count() to anon, authenticated, service_role;
