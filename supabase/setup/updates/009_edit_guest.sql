-- =====================================================================
-- NammaStay · 009_edit_guest.sql
-- Edit a guest's profile (owner / manager / front desk):
-- name, phone, email, date of birth, nationality, ID type & number,
-- ID photo and notes. Same cleaning rules as a new booking:
-- phone gets +91 if 10 digits, Aadhaar is stored masked (last 4 only).
-- Run AFTER 001–003.
-- =====================================================================

create or replace function public.update_guest(p_guest uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  g        public.guests%rowtype;
  v_phone  text;
  v_email  text;
  v_dob    date;
  v_type   public.id_doc_type;
  v_old_doc text;
  v_changed text[] := '{}';
begin
  select * into g from public.guests where id = p_guest for update;
  if not found then raise exception 'Guest not found.'; end if;
  perform public._assert_role(g.property_id, array['owner','manager','front_desk']::public.member_role[]);

  if p ? 'full_name' and coalesce(char_length(btrim(p->>'full_name')), 0) < 2 then
    raise exception 'Please enter the guest’s full name.';
  end if;
  v_phone := case when p ? 'phone' then public._clean_phone(p->>'phone') else g.phone end;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'Please check the phone number.'; end if;
  v_email := case when p ? 'email' then nullif(lower(btrim(p->>'email')), '') else g.email end;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please check the email address.'; end if;
  v_dob := case when p ? 'dob' then nullif(p->>'dob', '')::date else g.dob end;
  perform public._check_dob(v_dob);
  v_type := case when p ? 'id_type' then nullif(p->>'id_type', '')::public.id_doc_type else g.id_type end;
  v_old_doc := g.id_doc_path;

  if p ? 'id_doc_path' and nullif(p->>'id_doc_path', '') is not null
     and p->>'id_doc_path' not like g.property_id::text || '/%' then
    raise exception 'ID photo upload is invalid. Please try again.';
  end if;

  update public.guests set
    full_name   = case when p ? 'full_name' then left(btrim(p->>'full_name'), 120) else full_name end,
    phone       = v_phone,
    email       = v_email,
    dob         = v_dob,
    nationality = case when p ? 'nationality' then nullif(left(btrim(p->>'nationality'), 60), '') else nationality end,
    id_type     = v_type,
    id_number   = case when p ? 'id_number' then public._mask_id(v_type::text, p->>'id_number') else id_number end,
    id_doc_path = case when p ? 'id_doc_path' and nullif(p->>'id_doc_path', '') is not null then p->>'id_doc_path' else id_doc_path end,
    notes       = case when p ? 'notes' then nullif(left(btrim(p->>'notes'), 2000), '') else notes end
  where id = p_guest
  returning * into g;

  -- record which fields changed (not the values — they're personal data)
  select array_agg(k) into v_changed from jsonb_object_keys(p) k
   where k in ('full_name','phone','email','dob','nationality','id_type','id_number','id_doc_path','notes');
  insert into public.audit_log (property_id, entity, entity_id, action, details, actor)
  values (g.property_id, 'guest', g.id, 'edited', jsonb_build_object('fields', coalesce(to_jsonb(v_changed), '[]'::jsonb)), auth.uid());

  return jsonb_build_object('id', g.id,
    'old_id_doc_path', case when g.id_doc_path is distinct from v_old_doc then v_old_doc end);
end $$;

-- Staff may delete an old ID photo of their own property when replacing it
drop policy if exists "guest-ids: owner delete" on storage.objects;
drop policy if exists "guest-ids: staff delete" on storage.objects;
create policy "guest-ids: staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'guest-ids' and exists (
    select 1 from public.my_property_ids(array['owner','manager','front_desk']::public.member_role[]) pid
     where pid::text = (storage.foldername(name))[1]));

revoke execute on function public.update_guest(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.update_guest(uuid, jsonb) to authenticated;
