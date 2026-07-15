-- 00002_portfolio_core.sql
-- Core: Portfolios → Sites → Buildings → Floors → Spaces → Leases
-- This is the CENTER of everything - all other domains FK to site_id

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type portfolio.site_type as enum (
    'office', 'retail', 'industrial', 'lab', 'hospitality', 
    'multifamily', 'mixed_use', 'medical', 'education', 'datacenter', 'other'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type portfolio.site_status as enum (
    'active', 'onboarding', 'inactive', 'disposed', 'draft'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type portfolio.space_type as enum (
    'leasable', 'common', 'amenity', 'parking', 'storage', 'external', 'mechanical', 'other'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type portfolio.space_status as enum (
    'vacant', 'occupied', 'reserved', 'maintenance', 'out_of_service'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type portfolio.lease_status as enum (
    'draft', 'active', 'expired', 'terminated', 'pending'
  );
exception when duplicate_object then null;
end $$;

-----------------------------
-- PORTFOLIOS
-----------------------------
create table portfolio.portfolios (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name text not null,
  description text,
  color text default '#3b82f6',
  manager_id uuid references platform.profiles(id) on delete set null,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_portfolios_org on portfolio.portfolios(org_id);
create index idx_portfolios_name_trgm on portfolio.portfolios using gin (name gin_trgm_ops);

create trigger set_portfolios_updated_at
  before update on portfolio.portfolios
  for each row execute function public.handle_updated_at();

alter table portfolio.portfolios enable row level security;

create policy "Members can view org portfolios"
on portfolio.portfolios for select
using (platform.is_org_member(org_id));

create policy "Admins can manage portfolios"
on portfolio.portfolios for all
using (platform.is_org_admin(org_id));

-----------------------------
-- SITES (THE CENTER)
-----------------------------
create table portfolio.sites (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  portfolio_id uuid references portfolio.portfolios(id) on delete set null,
  name text not null,
  slug text not null,
  type portfolio.site_type not null default 'office',
  status portfolio.site_status not null default 'active',
  -- Address
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  zip_code text,
  country text default 'US',
  timezone text default 'America/New_York',
  -- Geo
  location geography(point, 4326), -- PostGIS
  latitude double precision,
  longitude double precision,
  -- Physical
  sq_ft integer,
  year_built integer,
  floors_count integer default 1,
  -- Management
  manager_id uuid references platform.profiles(id) on delete set null,
  external_id text, -- id in external system like Yardi/MRI
  -- Flexible
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  created_by uuid references platform.profiles(id),
  unique(org_id, slug)
);

-- Indexes
create index idx_sites_org on portfolio.sites(org_id);
create index idx_sites_portfolio on portfolio.sites(portfolio_id);
create index idx_sites_type on portfolio.sites(type);
create index idx_sites_status on portfolio.sites(status);
create index idx_sites_slug on portfolio.sites(org_id, slug);
create index idx_sites_name_trgm on portfolio.sites using gin (name gin_trgm_ops);
create index idx_sites_location_gist on portfolio.sites using gist (location);
create index idx_sites_metadata_gin on portfolio.sites using gin (metadata jsonb_path_ops);
create index idx_sites_org_status on portfolio.sites(org_id, status);

create trigger set_sites_updated_at
  before update on portfolio.sites
  for each row execute function public.handle_updated_at();

-- Function to sync lat/lng -> geography
create or replace function portfolio.sync_site_geo()
returns trigger
language plpgsql
as $$
begin
  if new.latitude is not null and new.longitude is not null then
    new.location := st_setsrid(st_makepoint(new.longitude, new.latitude), 4326)::geography;
  end if;
  return new;
end;
$$;

create trigger sync_site_geo_trigger
  before insert or update of latitude, longitude on portfolio.sites
  for each row execute function portfolio.sync_site_geo();

alter table portfolio.sites enable row level security;

-- RLS: can_access_site is core
create policy "Users can view accessible sites"
on portfolio.sites for select
using (platform.can_access_site(id));

create policy "Managers can insert sites"
on portfolio.sites for insert
with check (platform.is_org_member(org_id));

create policy "Site managers can update sites"
on portfolio.sites for update
using (platform.is_site_manager(id) or platform.is_org_admin(org_id));

create policy "Admins can delete sites"
on portfolio.sites for delete
using (platform.is_org_admin(org_id));

-- Add FK for audit_logs site_id now that sites exists
do $$ begin
  alter table platform.audit_logs add constraint fk_audit_site foreign key (site_id) references portfolio.sites(id) on delete set null;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table platform.notifications add constraint fk_notif_site foreign key (site_id) references portfolio.sites(id) on delete cascade;
exception when duplicate_object then null;
end $$;

-----------------------------
-- BUILDINGS (optional, 1 site can have N buildings - campus)
-----------------------------
create table portfolio.buildings (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  name text not null,
  description text,
  floors_count integer default 1,
  sq_ft integer,
  year_built integer,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_buildings_site on portfolio.buildings(site_id);
create index idx_buildings_org on portfolio.buildings(org_id);

create trigger set_buildings_updated_at
  before update on portfolio.buildings
  for each row execute function public.handle_updated_at();

alter table portfolio.buildings enable row level security;

create policy "View buildings if can access site"
on portfolio.buildings for select
using (platform.can_access_site(site_id));

create policy "Managers can manage buildings"
on portfolio.buildings for all
using (platform.can_access_site(site_id) and platform.is_site_manager(site_id));

-----------------------------
-- FLOORS / LEVELS
-----------------------------
create table portfolio.floors (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  building_id uuid not null references portfolio.buildings(id) on delete cascade,
  level_number integer not null, -- -2 basement, 0 ground, 1,2...
  name text not null, -- "Ground Floor", "PH"
  display_name text,
  sq_ft integer,
  floorplan_path text, -- storage path
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique(building_id, level_number)
);

create index idx_floors_building on portfolio.floors(building_id);
create index idx_floors_site on portfolio.floors(site_id);

create trigger set_floors_updated_at
  before update on portfolio.floors
  for each row execute function public.handle_updated_at();

alter table portfolio.floors enable row level security;

create policy "View floors if can access site"
on portfolio.floors for select
using (platform.can_access_site(site_id));

create policy "Managers can manage floors"
on portfolio.floors for all
using (platform.can_access_site(site_id) and platform.is_site_manager(site_id));

-----------------------------
-- SPACES / UNITS (leasable + common)
-----------------------------
create table portfolio.spaces (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  building_id uuid references portfolio.buildings(id) on delete set null,
  floor_id uuid references portfolio.floors(id) on delete set null,
  name text not null,
  code text, -- e.g., "STE 100", "P-01"
  type portfolio.space_type not null default 'leasable',
  status portfolio.space_status not null default 'vacant',
  area_sq_ft integer,
  capacity integer, -- people capacity for amenity
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_spaces_site on portfolio.spaces(site_id);
create index idx_spaces_building on portfolio.spaces(building_id);
create index idx_spaces_floor on portfolio.spaces(floor_id);
create index idx_spaces_type_status on portfolio.spaces(type, status);
create index idx_spaces_site_type on portfolio.spaces(site_id, type);
create index idx_spaces_name_trgm on portfolio.spaces using gin (name gin_trgm_ops);

create trigger set_spaces_updated_at
  before update on portfolio.spaces
  for each row execute function public.handle_updated_at();

alter table portfolio.spaces enable row level security;

create policy "View spaces if can access site"
on portfolio.spaces for select
using (platform.can_access_site(site_id));

create policy "Managers can manage spaces"
on portfolio.spaces for all
using (platform.can_access_site(site_id));

-----------------------------
-- LEASES (optional for occupancy)
-----------------------------
create table portfolio.leases (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  space_id uuid references portfolio.spaces(id) on delete set null,
  external_tenant_name text, -- if tenant not yet in tenant.tenants table
  tenant_id uuid, -- FK added later after tenant schema created
  start_date date not null,
  end_date date not null,
  status portfolio.lease_status not null default 'active',
  monthly_rent numeric(12,2),
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  check (end_date > start_date)
);

create index idx_leases_site on portfolio.leases(site_id);
create index idx_leases_space on portfolio.leases(space_id);
create index idx_leases_status_end on portfolio.leases(status, end_date);

create trigger set_leases_updated_at
  before update on portfolio.leases
  for each row execute function public.handle_updated_at();

alter table portfolio.leases enable row level security;

create policy "View leases if can access site"
on portfolio.leases for select
using (platform.can_access_site(site_id));

create policy "Managers can manage leases"
on portfolio.leases for all
using (platform.can_access_site(site_id));

-----------------------------
-- HELPER FUNCTIONS FOR GRAPHQL
-----------------------------

-- Search sites by name/address with trigram + PostGIS nearby
create or replace function portfolio.search_sites(search_query text, p_org_id uuid default null, limit_count integer default 20)
returns setof portfolio.sites
language plpgsql
security definer
set search_path = portfolio, platform, public
as $$
begin
  return query
  select * from portfolio.sites s
  where (p_org_id is null or s.org_id = p_org_id)
  and (
    s.name ilike '%'||search_query||'%'
    or s.address_line1 ilike '%'||search_query||'%'
    or s.city ilike '%'||search_query||'%'
    or s.slug ilike '%'||search_query||'%'
  )
  and platform.can_access_site(s.id)
  order by similarity(s.name, search_query) desc
  limit limit_count;
end;
$$;

comment on function portfolio.search_sites(text, uuid, integer) is '@graphql({"type": "query", "name": "searchSites"})';

-- Get nearby sites (PostGIS)
create or replace function portfolio.nearby_sites(p_lat double precision, p_lng double precision, radius_meters integer default 5000, limit_count integer default 20)
returns table (
  id uuid,
  name text,
  address_line1 text,
  city text,
  distance_meters double precision
)
language sql
security definer
set search_path = portfolio, platform, public
as $$
  select 
    s.id,
    s.name,
    s.address_line1,
    s.city,
    st_distance(s.location, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography) as distance_meters
  from portfolio.sites s
  where s.location is not null
  and st_dwithin(s.location, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, radius_meters)
  and platform.can_access_site(s.id)
  order by distance_meters
  limit limit_count;
$$;

comment on function portfolio.nearby_sites(double precision, double precision, integer, integer) is '@graphql({"type": "query", "name": "nearbySites"})';

-- Create site with building/floor bootstrapping
create or replace function portfolio.create_site_full(
  p_org_id uuid,
  p_portfolio_id uuid,
  p_name text,
  p_slug text,
  p_address_line1 text,
  p_city text,
  p_state text,
  p_type portfolio.site_type default 'office',
  p_sq_ft integer default null,
  p_floors_count integer default 1
)
returns portfolio.sites
language plpgsql
security definer
set search_path = portfolio, platform, public
as $$
declare
  new_site portfolio.sites;
  new_building portfolio.buildings%rowtype;
begin
  if not platform.is_org_member(p_org_id) then
    raise exception 'Not a member of organization';
  end if;

  insert into portfolio.sites (org_id, portfolio_id, name, slug, address_line1, city, state, type, sq_ft, floors_count, created_by)
  values (p_org_id, p_portfolio_id, p_name, p_slug, p_address_line1, p_city, p_state, p_type, p_sq_ft, p_floors_count, auth.uid())
  returning * into new_site;

  -- Auto-create default building
  insert into portfolio.buildings (org_id, site_id, name, floors_count, sq_ft)
  values (p_org_id, new_site.id, p_name || ' Main Building', p_floors_count, p_sq_ft)
  returning * into new_building;

  -- Auto-create floors
  for i in 1..p_floors_count loop
    insert into portfolio.floors (org_id, site_id, building_id, level_number, name)
    values (p_org_id, new_site.id, new_building.id, i, 'Floor ' || i);
  end loop;

  return new_site;
end;
$$;

comment on function portfolio.create_site_full(uuid, uuid, text, text, text, text, text, portfolio.site_type, integer, integer) is '@graphql({"type": "mutation", "name": "createSiteFull"})';

-- Grants
grant all on all tables in schema portfolio to service_role;
grant all on all sequences in schema portfolio to service_role;
grant select, insert, update, delete on all tables in schema portfolio to authenticated;
grant usage on all sequences in schema portfolio to authenticated;

-- Realtime
alter publication supabase_realtime add table portfolio.sites;
alter publication supabase_realtime add table portfolio.buildings;
alter publication supabase_realtime add table portfolio.spaces;
alter publication supabase_realtime add table portfolio.leases;

-- Upgrade is_site_manager to secure version that validates org via sites table (now that sites exists)
-- This replaces the simplified version from 00001_platform.sql
create or replace function platform.is_site_manager(p_site_id uuid)
returns boolean
language sql
security definer
set search_path = platform, portfolio, public
as $$
  select exists (
    select 1 from platform.memberships m
    join portfolio.sites s on s.org_id = m.org_id
    where m.user_id = auth.uid()
    and s.id = p_site_id
    and m.role in ('owner','admin','portfolio_manager','site_manager')
    and (m.site_ids is null or s.id = any(m.site_ids))
  ) or platform.is_super_admin();
$$;
