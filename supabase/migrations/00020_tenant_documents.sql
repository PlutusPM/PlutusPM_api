-- 00020_tenant_documents.sql
-- Stage 2 of PlutusPM_dashboard BUSINESS_RULES.md gap closure: tenant documents,
-- versioning (one current version per chain), and visibility-tiered access.
-- Zero tables existed for this before this migration.

-----------------------------
-- NOTIFICATIONS TYPE FIX (prerequisite)
-- platform.notifications.type's check constraint (00001_platform.sql) never included
-- 'document_expiring', 'contract_expiring', or 'contract_expired', even though existing
-- vendor.check_document_expirations()/check_contract_expirations() (00012) already insert
-- those literal values - a pre-existing latent bug (only surfaces once a matching row
-- exists). Fixing it here because this migration's own check_document_expirations()
-- needs 'document_expiring' to actually work.
-----------------------------
alter table platform.notifications drop constraint notifications_type_check;
alter table platform.notifications add constraint notifications_type_check check (type in (
  'sla_breach', 'coi_expiring', 'coi_expired', 'work_order_assigned',
  'service_request_created', 'visitor_arrived', 'lease_expiring',
  'compliance_issue', 'system', 'report_ready', 'reservation_reminder',
  'document_expiring', 'contract_expiring', 'contract_expired'
));

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type tenant.document_category_enum as enum (
    'lease', 'lease_amendment', 'renewal', 'coi', 'tenant_handbook_ack',
    'move_in_docs', 'move_out_docs', 'floor_plan', 'space_plan',
    'contact_list', 'emergency_plan', 'correspondence', 'other'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.document_status_enum as enum (
    'current', 'expiring_soon', 'expired', 'draft', 'superseded', 'archived'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.document_visibility_enum as enum (
    'admin_only', 'management', 'tenant_admin', 'tenant_portal'
  );
exception when duplicate_object then null;
end $$;

-----------------------------
-- TENANT.TENANT_DOCUMENTS (header row)
-----------------------------
create table tenant.tenant_documents (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  tenant_id uuid references tenant.tenants(id) on delete cascade,
  lease_id uuid references portfolio.leases(id) on delete set null,
  space_id uuid references portfolio.spaces(id) on delete set null,
  occupancy_id uuid references tenant.occupancies(id) on delete set null,
  name text not null,
  category tenant.document_category_enum not null default 'other',
  description text,
  visibility tenant.document_visibility_enum not null default 'management',
  status tenant.document_status_enum not null default 'draft',
  effective_date date,
  expiration_date date,
  current_version_id uuid, -- fk added after tenant_document_versions exists
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_tenant_documents_site on tenant.tenant_documents(site_id);
create index idx_tenant_documents_tenant on tenant.tenant_documents(tenant_id);
create index idx_tenant_documents_lease on tenant.tenant_documents(lease_id);
create index idx_tenant_documents_status on tenant.tenant_documents(status);
create index idx_tenant_documents_expiration on tenant.tenant_documents(expiration_date);

create trigger set_tenant_documents_updated_at
  before update on tenant.tenant_documents
  for each row execute function public.handle_updated_at();

-----------------------------
-- TENANT.TENANT_DOCUMENT_VERSIONS (per-revision file row)
-----------------------------
create table tenant.tenant_document_versions (
  id uuid primary key default uuid_generate_v4(),
  document_id uuid not null references tenant.tenant_documents(id) on delete cascade,
  version_number integer not null,
  previous_version_id uuid references tenant.tenant_document_versions(id) on delete set null,
  is_current boolean not null default true,
  storage_path text not null,
  file_name text not null,
  file_type text,
  file_size_bytes bigint,
  uploaded_by uuid references platform.profiles(id) on delete set null,
  uploaded_at timestamptz default now() not null,
  effective_date date,
  change_notes text,
  status tenant.document_status_enum not null default 'current',
  unique (document_id, version_number)
);

create index idx_document_versions_document on tenant.tenant_document_versions(document_id);

-- Enforce "only one document version should be current at a time for a given version chain"
create unique index idx_document_versions_one_current
  on tenant.tenant_document_versions (document_id)
  where is_current;

-- Deferrable: a BEFORE trigger (below) sets current_version_id to the incoming row's id before
-- that row is physically inserted, so the FK must not be checked until end of transaction.
alter table tenant.tenant_documents
  add constraint fk_tenant_documents_current_version
  foreign key (current_version_id) references tenant.tenant_document_versions(id) on delete set null
  deferrable initially deferred;

-- Flip prior current version off and sync the parent document row when a new version is inserted/updated.
-- Must run BEFORE the row is written: idx_document_versions_one_current (partial unique index) is
-- checked immediately on insert, so the old current version has to be flipped off first, not after.
create or replace function tenant.set_current_document_version()
returns trigger
language plpgsql
security definer
set search_path = tenant, public
as $$
begin
  if new.is_current then
    update tenant.tenant_document_versions
    set is_current = false
    where document_id = new.document_id and id != new.id and is_current;

    update tenant.tenant_documents
    set current_version_id = new.id,
        status = new.status,
        updated_at = now()
    where id = new.document_id;
  end if;
  return new;
end;
$$;

create trigger trg_document_versions_set_current
  before insert or update on tenant.tenant_document_versions
  for each row execute function tenant.set_current_document_version();

-----------------------------
-- RLS: TENANT-SCOPING HELPER (also reused by billing RLS in a later stage)
-----------------------------
create or replace function tenant.is_tenant_contact(p_tenant_id uuid)
returns boolean
language sql
security definer
set search_path = tenant, public
as $$
  select exists (
    select 1 from tenant.tenant_contacts tc
    where tc.tenant_id = p_tenant_id and tc.profile_id = auth.uid()
  );
$$;

-- Visibility-tier + tenant-isolation check: management/site-staff can see any document at
-- their site; a tenant-portal caller may only see tenant_admin/tenant_portal-visibility
-- documents that belong to THEIR OWN tenant (can_access_site alone isn't enough here since
-- tenant_admin/tenant_user membership roles also pass can_access_site).
create or replace function tenant.can_view_document(p_document_id uuid)
returns boolean
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
declare
  d tenant.tenant_documents%rowtype;
begin
  select * into d from tenant.tenant_documents where id = p_document_id;
  if not found then return false; end if;
  if not platform.can_access_site(d.site_id) then return false; end if;

  if platform.is_site_manager(d.site_id) or platform.is_org_admin(d.org_id) then
    return true;
  end if;

  return d.visibility in ('tenant_admin', 'tenant_portal')
    and d.tenant_id is not null
    and tenant.is_tenant_contact(d.tenant_id);
end;
$$;

comment on function tenant.can_view_document(uuid) is '@graphql({"type": "query", "name": "canViewDocument"})';

alter table tenant.tenant_documents enable row level security;

create policy "View tenant documents per visibility"
on tenant.tenant_documents for select
using (tenant.can_view_document(id));

create policy "Managers manage tenant documents"
on tenant.tenant_documents for all
using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id));

alter table tenant.tenant_document_versions enable row level security;

create policy "View document versions per visibility"
on tenant.tenant_document_versions for select
using (tenant.can_view_document(document_id));

create policy "Managers manage document versions"
on tenant.tenant_document_versions for all
using (exists (
  select 1 from tenant.tenant_documents d
  where d.id = tenant_document_versions.document_id
  and (platform.is_site_manager(d.site_id) or platform.is_org_admin(d.org_id))
));

select platform.attach_audit_trigger('tenant', 'tenant_documents');
select platform.attach_audit_trigger('tenant', 'tenant_document_versions');

-----------------------------
-- STORAGE: tenant-documents bucket
-- Path convention: {org_id}/{site_id}/{document_id}/{version_id}-{file_name}
-- (matches the existing {org_id}/{site_id}/... convention from 00005_storage.sql, with the
-- document_id path segment added so storage RLS can call can_view_document)
-----------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tenant-documents', 'tenant-documents', false, 20971520, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do nothing;

-- Ownership of storage.objects (supabase_storage_admin) is not reliably held by the
-- migration role in every environment/timing window (00017_graphql_introspection.sql hit the
-- same issue commenting on the storage schema) - wrap defensively like that migration does,
-- rather than let an ownership hiccup abort the whole file.
do $$ begin
  drop policy if exists "View tenant documents per visibility" on storage.objects;
  create policy "View tenant documents per visibility"
  on storage.objects for select
  using (
    bucket_id = 'tenant-documents'
    and tenant.can_view_document(((storage.foldername(name))[3])::uuid)
  );
exception when insufficient_privilege or others then
  raise notice 'Could not create tenant-documents select policy on storage.objects (not owner): %', SQLERRM;
end $$;

do $$ begin
  drop policy if exists "Managers manage tenant document files" on storage.objects;
  create policy "Managers manage tenant document files"
  on storage.objects for all
  using (
    bucket_id = 'tenant-documents'
    and platform.can_access_site(((storage.foldername(name))[2])::uuid)
    and platform.is_site_manager(((storage.foldername(name))[2])::uuid)
  );
exception when insufficient_privilege or others then
  raise notice 'Could not create tenant-documents manage policy on storage.objects (not owner): %', SQLERRM;
end $$;

-----------------------------
-- RPC: upload_tenant_document
-- Creates a new document (p_document_id null) or appends a version to an existing one.
-----------------------------
create or replace function tenant.upload_tenant_document(
  p_tenant_id uuid,
  p_category tenant.document_category_enum,
  p_visibility tenant.document_visibility_enum,
  p_file_url text,
  p_file_name text,
  p_expires_at timestamptz default null,
  p_document_id uuid default null,
  p_lease_id uuid default null,
  p_space_id uuid default null,
  p_occupancy_id uuid default null,
  p_change_notes text default null,
  p_document_name text default null
)
returns tenant.tenant_documents
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
declare
  v_org_id uuid;
  v_site_id uuid;
  v_document tenant.tenant_documents;
  v_next_version integer;
begin
  select org_id, site_id into v_org_id, v_site_id from tenant.tenants where id = p_tenant_id;
  if v_org_id is null then raise exception 'Unknown tenant %', p_tenant_id; end if;
  if not platform.can_access_site(v_site_id) then raise exception 'Access denied to site'; end if;

  if p_document_id is null then
    insert into tenant.tenant_documents (
      org_id, site_id, tenant_id, lease_id, space_id, occupancy_id,
      name, category, visibility, status, expiration_date
    )
    values (
      v_org_id, v_site_id, p_tenant_id, p_lease_id, p_space_id, p_occupancy_id,
      coalesce(p_document_name, p_file_name), p_category, p_visibility, 'draft',
      p_expires_at::date
    )
    returning * into v_document;
  else
    select * into v_document from tenant.tenant_documents where id = p_document_id;
    if not found then raise exception 'Unknown document %', p_document_id; end if;
    update tenant.tenant_documents set expiration_date = coalesce(p_expires_at::date, expiration_date)
    where id = p_document_id;
  end if;

  select coalesce(max(version_number), 0) + 1 into v_next_version
  from tenant.tenant_document_versions where document_id = v_document.id;

  insert into tenant.tenant_document_versions (
    document_id, version_number, previous_version_id, is_current,
    storage_path, file_name, uploaded_by, effective_date, change_notes, status
  )
  values (
    v_document.id, v_next_version,
    (select id from tenant.tenant_document_versions where document_id = v_document.id and is_current limit 1),
    true, p_file_url, p_file_name, auth.uid(), current_date, p_change_notes, 'current'
  );

  select * into v_document from tenant.tenant_documents where id = v_document.id;
  return v_document;
end;
$$;

comment on function tenant.upload_tenant_document(uuid, tenant.document_category_enum, tenant.document_visibility_enum, text, text, timestamptz, uuid, uuid, uuid, uuid, text, text) is '@graphql({"type": "mutation", "name": "uploadTenantDocument"})';

-----------------------------
-- CRON: expiration tracking (mirrors vendor.check_document_expirations from 00012)
-----------------------------
create or replace function tenant.check_document_expirations()
returns integer
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
begin
  insert into platform.notifications (org_id, site_id, type, title, body, payload)
  select org_id, site_id, 'document_expiring', 'Document expiring: ' || name,
         'Expires ' || expiration_date::text, jsonb_build_object('document_id', id, 'tenant_id', tenant_id)
  from tenant.tenant_documents
  where expiration_date between current_date and current_date + interval '30 days'
  and status not in ('expired', 'archived');

  update tenant.tenant_documents set status = 'expiring_soon', updated_at = now()
  where expiration_date between current_date and current_date + interval '30 days'
  and status = 'current';

  update tenant.tenant_documents set status = 'expired', updated_at = now()
  where expiration_date < current_date and status not in ('expired', 'archived');

  return 1;
end;
$$;

do $do$ begin
  if not exists (select 1 from cron.job where jobname = 'check-tenant-document-expirations') then
    perform cron.schedule('check-tenant-document-expirations', '0 7 * * *', $cron$ select tenant.check_document_expirations(); $cron$);
  end if;
exception when others then raise notice 'cron.schedule check-tenant-document-expirations failed: %', SQLERRM;
end $do$;

-----------------------------
-- REALTIME
-----------------------------
do $$ begin
  alter publication supabase_realtime add table tenant.tenant_documents;
exception when duplicate_object then null;
end $$;

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated, service_role;
grant usage on all sequences in schema tenant to anon, authenticated, service_role;
