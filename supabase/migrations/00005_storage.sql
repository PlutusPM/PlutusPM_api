-- 00005_storage.sql
-- Storage buckets + RLS for CRE SaaS

-- Create buckets
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values 
  ('avatars', 'avatars', true, 2097152, array['image/jpeg','image/png','image/webp','image/gif']),
  ('site-files', 'site-files', false, 104857600, null), -- 100MB private
  ('floorplans', 'floorplans', false, 52428800, array['application/pdf','image/jpeg','image/png','image/svg+xml']),
  ('coi-documents', 'coi-documents', false, 20971520, array['application/pdf','image/jpeg','image/png']),
  ('contract-documents', 'contract-documents', false, 52428800, array['application/pdf']),
  ('visitor-photos', 'visitor-photos', false, 5242880, array['image/jpeg','image/png']),
  ('work-order-attachments', 'work-order-attachments', false, 20971520, null)
on conflict (id) do nothing;

-- Storage RLS policies
-- Note: storage.foldername(name) returns path parts - we use org_id/site_id pattern
-- Path pattern: {org_id}/{site_id}/...
-- Example: 123e4567-e89b-12d3-a456-426614174000/site-id/...
-- For avatars: {user_id}/avatar.png

-- AVATARS (public read, user can manage own)
drop policy if exists "Avatar public read" on storage.objects;
create policy "Avatar public read"
on storage.objects for select
using (bucket_id = 'avatars');

drop policy if exists "Users can upload own avatar" on storage.objects;
create policy "Users can upload own avatar"
on storage.objects for insert
with check (
  bucket_id = 'avatars'
  and auth.uid()::text = (storage.foldername(name))[1]
);

drop policy if exists "Users can update own avatar" on storage.objects;
create policy "Users can update own avatar"
on storage.objects for update
using (
  bucket_id = 'avatars'
  and auth.uid()::text = (storage.foldername(name))[1]
);

drop policy if exists "Users can delete own avatar" on storage.objects;
create policy "Users can delete own avatar"
on storage.objects for delete
using (
  bucket_id = 'avatars'
  and auth.uid()::text = (storage.foldername(name))[1]
);

-- SITE-FILES (private, org members only)
-- Path: org_id/site_id/... - check org_id accessible and site accessible
drop policy if exists "Members can view site files" on storage.objects;
create policy "Members can view site files"
on storage.objects for select
using (
  bucket_id = 'site-files'
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

drop policy if exists "Members can upload site files" on storage.objects;
create policy "Members can upload site files"
on storage.objects for insert
with check (
  bucket_id = 'site-files'
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

drop policy if exists "Managers can update site files" on storage.objects;
create policy "Managers can update site files"
on storage.objects for update
using (
  bucket_id = 'site-files'
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

drop policy if exists "Managers can delete site files" on storage.objects;
create policy "Managers can delete site files"
on storage.objects for delete
using (
  bucket_id = 'site-files'
  and platform.is_site_manager(((storage.foldername(name))[2])::uuid)
);

-- FLOORPLANS (same as site-files)
drop policy if exists "Members can view floorplans" on storage.objects;
create policy "Members can view floorplans"
on storage.objects for select
using (
  bucket_id = 'floorplans'
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

drop policy if exists "Managers can manage floorplans" on storage.objects;
create policy "Managers can manage floorplans"
on storage.objects for all
using (
  bucket_id = 'floorplans'
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

-- COI & CONTRACTS (org members)
drop policy if exists "Members can manage coi docs" on storage.objects;
create policy "Members can manage coi docs"
on storage.objects for all
using (
  bucket_id in ('coi-documents','contract-documents')
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
);

-- WORK ORDER ATTACHMENTS
drop policy if exists "Members can manage WO attachments" on storage.objects;
create policy "Members can manage WO attachments"
on storage.objects for all
using (
  bucket_id = 'work-order-attachments'
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

-- VISITOR PHOTOS
drop policy if exists "Members can manage visitor photos" on storage.objects;
create policy "Members can manage visitor photos"
on storage.objects for all
using (
  bucket_id = 'visitor-photos'
  and platform.is_org_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

-- Enable RLS on storage.objects already enabled by Supabase
