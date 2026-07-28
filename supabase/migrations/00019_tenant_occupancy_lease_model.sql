-- 00019_tenant_occupancy_lease_model.sql
-- Stage 1 of PlutusPM_dashboard BUSINESS_RULES.md gap closure:
-- - tenant.tenants: tenant_type, external_tenant_id (import dedup), website, company_phone
-- - portfolio.leases: security_deposit, lease_type, renewal_of_lease_id
-- - portfolio.lease_spaces: multi-space-per-lease junction (new)
-- - tenant.occupancies: physical possession, distinct from lease's legal-contract status (new)
-- - tenant.tenant_contacts: contact_type, is_emergency, receives_announcements, receives_billing_notices, portal_status
-- - tenant.leases: security_invoker view so Accept-Profile: tenant resolves against portfolio.leases

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type tenant.tenant_type_enum as enum ('residential', 'commercial', 'mixed_use');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type portfolio.lease_type_enum as enum ('fixed', 'month_to_month', 'renewal');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.occupancy_status_enum as enum ('future', 'active', 'vacating', 'ended', 'inactive');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.contact_type_enum as enum (
    'primary', 'resident', 'office_manager', 'executive', 'reception',
    'facilities', 'billing', 'emergency', 'other'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.portal_status_enum as enum ('not_invited', 'invitation_pending', 'active', 'suspended');
exception when duplicate_object then null;
end $$;

-----------------------------
-- TENANT.TENANTS ADDITIONS
-----------------------------
do $$ begin
  alter table tenant.tenants add column tenant_type tenant.tenant_type_enum not null default 'commercial';
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenants add column external_tenant_id text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenants add column website text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenants add column company_phone text;
exception when duplicate_column then null;
end $$;

-- Import dedup: reject duplicate external_tenant_id within an org
create unique index if not exists idx_tenants_org_external_id
  on tenant.tenants (org_id, external_tenant_id)
  where external_tenant_id is not null;

-----------------------------
-- PORTFOLIO.LEASES ADDITIONS
-----------------------------
do $$ begin
  alter table portfolio.leases add column security_deposit numeric(12,2);
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table portfolio.leases add column lease_type portfolio.lease_type_enum not null default 'fixed';
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table portfolio.leases add column renewal_of_lease_id uuid references portfolio.leases(id) on delete set null;
exception when duplicate_column then null;
end $$;

-----------------------------
-- PORTFOLIO.LEASE_SPACES (multi-space-per-lease junction)
-----------------------------
create table portfolio.lease_spaces (
  id uuid primary key default uuid_generate_v4(),
  lease_id uuid not null references portfolio.leases(id) on delete cascade,
  space_id uuid not null references portfolio.spaces(id) on delete cascade,
  effective_start_date date not null,
  effective_end_date date,
  square_feet integer,
  created_at timestamptz default now() not null,
  check (effective_end_date is null or effective_end_date > effective_start_date)
);

create index idx_lease_spaces_lease on portfolio.lease_spaces(lease_id);
create index idx_lease_spaces_space on portfolio.lease_spaces(space_id);

alter table portfolio.lease_spaces enable row level security;

create policy "View lease_spaces if can access site"
on portfolio.lease_spaces for select
using (exists (
  select 1 from portfolio.leases l
  where l.id = lease_spaces.lease_id and platform.can_access_site(l.site_id)
));

create policy "Managers manage lease_spaces"
on portfolio.lease_spaces for all
using (exists (
  select 1 from portfolio.leases l
  where l.id = lease_spaces.lease_id and platform.can_access_site(l.site_id)
));

select platform.attach_audit_trigger('portfolio', 'lease_spaces');

-- Backfill from existing single-space leases (leases.space_id stays, now deprecated in favor of this table)
insert into portfolio.lease_spaces (lease_id, space_id, effective_start_date, effective_end_date)
select id, space_id, start_date, end_date
from portfolio.leases
where space_id is not null;

-----------------------------
-- TENANT.OCCUPANCIES (physical possession, distinct from lease legal-contract status)
-----------------------------
create table tenant.occupancies (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  tenant_id uuid not null references tenant.tenants(id) on delete cascade,
  space_id uuid not null references portfolio.spaces(id) on delete cascade,
  lease_id uuid references portfolio.leases(id) on delete set null,
  start_date date not null,
  end_date date,
  move_in_date date,
  move_out_date date,
  occupied_square_feet integer,
  status tenant.occupancy_status_enum not null default 'future',
  is_primary boolean default true,
  shared_occupancy boolean default false,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  check (end_date is null or end_date > start_date)
);

create index idx_occupancies_site on tenant.occupancies(site_id);
create index idx_occupancies_tenant on tenant.occupancies(tenant_id);
create index idx_occupancies_space on tenant.occupancies(space_id);
create index idx_occupancies_status on tenant.occupancies(status);

create trigger set_occupancies_updated_at
  before update on tenant.occupancies
  for each row execute function public.handle_updated_at();

alter table tenant.occupancies enable row level security;

create policy "View occupancies if can access site"
on tenant.occupancies for select
using (platform.can_access_site(site_id));

create policy "Managers manage occupancies"
on tenant.occupancies for all
using (platform.can_access_site(site_id));

select platform.attach_audit_trigger('tenant', 'occupancies');

-- Conflict check, shared by the pre-flight (bulk import can call this per row to collect
-- all errors instead of aborting on the first exception) and the enforcement trigger below.
create or replace function tenant.check_occupancy_conflict(
  p_space_id uuid,
  p_start date,
  p_end date default null,
  p_exclude_occupancy_id uuid default null
)
returns boolean -- true if conflict exists
language sql
security definer
set search_path = tenant, public
as $$
  select exists (
    select 1 from tenant.occupancies o
    where o.space_id = p_space_id
    and o.shared_occupancy = false
    and (p_exclude_occupancy_id is null or o.id != p_exclude_occupancy_id)
    and daterange(o.start_date, coalesce(o.end_date, 'infinity'::date), '[)')
        && daterange(p_start, coalesce(p_end, 'infinity'::date), '[)')
  );
$$;

comment on function tenant.check_occupancy_conflict(uuid, date, date, uuid) is '@graphql({"type": "query", "name": "checkOccupancyConflict"})';

-- DB-level enforcement (not just app-level): reject overlapping exclusive occupancy of the same
-- space on write. A trigger is used instead of a GiST exclusion constraint (which would need the
-- btree_gist extension) so this doesn't depend on an extension install; the guarantee is the same.
create or replace function tenant.prevent_occupancy_overlap()
returns trigger
language plpgsql
security definer
set search_path = tenant, public
as $$
begin
  if new.shared_occupancy = false and tenant.check_occupancy_conflict(new.space_id, new.start_date, new.end_date, new.id) then
    raise exception 'Occupancy conflict: space % already has an overlapping non-shared occupancy', new.space_id
      using errcode = '23P01';
  end if;
  return new;
end;
$$;

create trigger trg_occupancies_no_overlap
  before insert or update on tenant.occupancies
  for each row execute function tenant.prevent_occupancy_overlap();

-----------------------------
-- TENANT.TENANT_CONTACTS ADDITIONS
-----------------------------
-- New contact_type column added alongside the existing `role` column (role stays, not replaced,
-- to avoid breaking existing readers); the two overlap in purpose but map differently
-- (existing role: primary/admin/member/billing/facility) and reconciling them is a follow-up.
do $$ begin
  alter table tenant.tenant_contacts add column contact_type tenant.contact_type_enum not null default 'other';
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenant_contacts add column is_emergency boolean not null default false;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenant_contacts add column receives_announcements boolean not null default true;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenant_contacts add column receives_billing_notices boolean not null default false;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenant_contacts add column portal_status tenant.portal_status_enum not null default 'not_invited';
exception when duplicate_column then null;
end $$;

-----------------------------
-- TENANT.LEASES VIEW
-- API_SPEC.md specifies /leases under Accept-Profile: tenant, but leases/lease_spaces
-- physically live in portfolio (correct FK home alongside sites/spaces/buildings).
-- Forward via a view rather than relocating the table.
-----------------------------
create or replace view tenant.leases as
select * from portfolio.leases;

do $$ begin
  execute 'alter view tenant.leases set (security_invoker = true)';
exception when others then null;
end $$;

-----------------------------
-- GRANTS (mirrors 00016/00017 pattern so new objects are visible to REST/GraphQL)
-----------------------------
grant usage on schema portfolio to anon, authenticated, service_role;
grant usage on schema tenant to anon, authenticated, service_role;

grant select on all tables in schema portfolio to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema portfolio to authenticated, service_role;

grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated, service_role;

grant usage on all sequences in schema portfolio to anon, authenticated, service_role;
grant usage on all sequences in schema tenant to anon, authenticated, service_role;
