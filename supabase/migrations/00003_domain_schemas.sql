-- 00003_domain_schemas.sql
-- Scaffold remaining domain schemas: ops, tenant, visitor, vendor, metrics
-- With core tables only for Phase 0, full tables in later phases

-----------------------------
-- OPS SCHEMA (Building Operations)
-----------------------------
do $$ begin
  create type ops.asset_status as enum ('active','inactive','maintenance','retired','ordered');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ops.criticality as enum ('low','medium','high','critical');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ops.work_order_type as enum ('preventive','corrective','inspection','service_request','incident');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ops.work_order_status as enum ('open','in_progress','on_hold','completed','cancelled','overdue');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ops.priority_level as enum ('low','medium','high','urgent');
exception when duplicate_object then null; end $$;

-- Asset categories
create table ops.asset_categories (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name text not null,
  icon text,
  color text default '#6b7280',
  created_at timestamptz default now() not null,
  unique(org_id, name)
);

-- Assets - the physical equipment
create table ops.assets (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  building_id uuid references portfolio.buildings(id) on delete set null,
  floor_id uuid references portfolio.floors(id) on delete set null,
  space_id uuid references portfolio.spaces(id) on delete set null,
  category_id uuid references ops.asset_categories(id) on delete set null,
  name text not null,
  description text,
  qr_code text unique default ('QR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  status ops.asset_status not null default 'active',
  criticality ops.criticality default 'medium',
  manufacturer text,
  model text,
  serial_number text,
  install_date date,
  warranty_end date,
  last_maintenance_at timestamptz,
  next_maintenance_at timestamptz,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  created_by uuid references platform.profiles(id)
);

create index idx_assets_site on ops.assets(site_id);
create index idx_assets_qr on ops.assets(qr_code);
create index idx_assets_category on ops.assets(category_id);
create index idx_assets_status on ops.assets(status);
create index idx_assets_name_trgm on ops.assets using gin (name gin_trgm_ops);

create trigger set_assets_updated_at before update on ops.assets for each row execute function public.handle_updated_at();

alter table ops.assets enable row level security;
create policy "View assets if can access site" on ops.assets for select using (platform.can_access_site(site_id));
create policy "Managers can manage assets" on ops.assets for all using (platform.can_access_site(site_id));

-- Work order templates (for PM)
create table ops.work_order_templates (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete cascade, -- null = org-wide template
  name text not null,
  description text,
  asset_category_id uuid references ops.asset_categories(id),
  type ops.work_order_type not null default 'preventive',
  priority ops.priority_level default 'medium',
  estimated_hours numeric,
  checklist jsonb default '[]'::jsonb,
  recurrence_rule text, -- e.g., "FREQ=MONTHLY;INTERVAL=1" or simple "monthly", "quarterly"
  next_due_at timestamptz,
  is_active boolean default true not null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

alter table ops.work_order_templates enable row level security;
create policy "View templates if org member" on ops.work_order_templates for select using (platform.is_org_member(org_id));
create policy "Managers manage templates" on ops.work_order_templates for all using (platform.is_org_member(org_id));

-- Work orders
create table ops.work_orders (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  building_id uuid references portfolio.buildings(id) on delete set null,
  floor_id uuid references portfolio.floors(id) on delete set null,
  space_id uuid references portfolio.spaces(id) on delete set null,
  asset_id uuid references ops.assets(id) on delete set null,
  template_id uuid references ops.work_order_templates(id) on delete set null,
  type ops.work_order_type not null default 'corrective',
  title text not null,
  description text,
  priority ops.priority_level not null default 'medium',
  status ops.work_order_status not null default 'open',
  assigned_to uuid references platform.profiles(id) on delete set null,
  created_by uuid references platform.profiles(id),
  due_date timestamptz,
  sla_due_at timestamptz,
  completed_at timestamptz,
  labor_hours numeric default 0,
  cost numeric(12,2) default 0,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_wos_site on ops.work_orders(site_id);
create index idx_wos_asset on ops.work_orders(asset_id);
create index idx_wos_status on ops.work_orders(status);
create index idx_wos_assigned on ops.work_orders(assigned_to);
create index idx_wos_site_status on ops.work_orders(site_id, status);
create index idx_wos_sla on ops.work_orders(sla_due_at) where status not in ('completed','cancelled');
create index idx_wos_created on ops.work_orders(created_at desc);

create trigger set_wos_updated_at before update on ops.work_orders for each row execute function public.handle_updated_at();

alter table ops.work_orders enable row level security;
create policy "View WOs if can access site" on ops.work_orders for select using (platform.can_access_site(site_id));
create policy "Members can create WOs" on ops.work_orders for insert with check (platform.can_access_site(site_id));
create policy "Members can update WOs" on ops.work_orders for update using (platform.can_access_site(site_id));
create policy "Managers can delete WOs" on ops.work_orders for delete using (platform.is_site_manager(site_id));

-----------------------------
-- TENANT SCHEMA (Tenant Experience)
-----------------------------
do $$ begin
  create type tenant.request_status as enum ('open','in_progress','completed','cancelled','on_hold');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tenant.reservation_status as enum ('pending','confirmed','cancelled','completed','no_show');
exception when duplicate_object then null; end $$;

create table tenant.tenants (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  company_name text not null,
  legal_name text,
  contact_email text,
  contact_phone text,
  status text default 'active' check (status in ('active','inactive','prospect')),
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_tenants_site on tenant.tenants(site_id);
alter table tenant.tenants enable row level security;
create policy "View tenants if can access site" on tenant.tenants for select using (platform.can_access_site(site_id));
create policy "Managers manage tenants" on tenant.tenants for all using (platform.can_access_site(site_id));

-- Link leases -> tenants FK now
do $$ begin
  alter table portfolio.leases add constraint fk_leases_tenant foreign key (tenant_id) references tenant.tenants(id) on delete set null;
exception when duplicate_object then null; end $$;
-- link spaces to tenant? could but skip for now

create table tenant.service_requests (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  space_id uuid references portfolio.spaces(id) on delete set null,
  tenant_id uuid references tenant.tenants(id) on delete set null,
  tenant_contact_id uuid references platform.profiles(id) on delete set null,
  title text not null,
  description text,
  category text,
  priority ops.priority_level default 'medium',
  status tenant.request_status not null default 'open',
  work_order_id uuid references ops.work_orders(id) on delete set null,
  created_by uuid references platform.profiles(id),
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_sr_site on tenant.service_requests(site_id);
create index idx_sr_status on tenant.service_requests(status);

create trigger set_sr_updated_at before update on tenant.service_requests for each row execute function public.handle_updated_at();

alter table tenant.service_requests enable row level security;
create policy "View SR if can access site" on tenant.service_requests for select using (platform.can_access_site(site_id));
create policy "Members manage SR" on tenant.service_requests for all using (platform.can_access_site(site_id));

create table tenant.reservations (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  space_id uuid not null references portfolio.spaces(id) on delete cascade,
  reserved_by uuid not null references platform.profiles(id) on delete cascade,
  title text,
  start_time timestamptz not null,
  end_time timestamptz not null,
  status tenant.reservation_status not null default 'pending',
  attendees integer,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  check (end_time > start_time)
);

create index idx_res_site_time on tenant.reservations(site_id, start_time);
alter table tenant.reservations enable row level security;
create policy "View reservations if can access site" on tenant.reservations for select using (platform.can_access_site(site_id));
create policy "Members manage reservations" on tenant.reservations for all using (platform.can_access_site(site_id));

-----------------------------
-- VISITOR SCHEMA
-----------------------------
do $$ begin
  create type visitor.visit_status as enum ('preregistered','checked_in','checked_out','cancelled','denied','no_show');
exception when duplicate_object then null; end $$;

create table visitor.visitors (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  email text,
  full_name text not null,
  company text,
  phone text,
  id_type text,
  id_last4 text, -- privacy: only store last 4
  photo_path text,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  unique(org_id, email)
);

alter table visitor.visitors enable row level security;
create policy "View visitors if org member" on visitor.visitors for select using (platform.is_org_member(org_id));
create policy "Members manage visitors" on visitor.visitors for all using (platform.is_org_member(org_id));

create table visitor.visits (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  visitor_id uuid not null references visitor.visitors(id) on delete cascade,
  host_user_id uuid references platform.profiles(id) on delete set null,
  host_space_id uuid references portfolio.spaces(id) on delete set null,
  purpose text,
  status visitor.visit_status not null default 'preregistered',
  scheduled_at timestamptz not null,
  checked_in_at timestamptz,
  checked_out_at timestamptz,
  qr_code text unique default ('V-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_visits_site_sched on visitor.visits(site_id, scheduled_at);
create index idx_visits_status on visitor.visits(status);

create trigger set_visits_updated_at before update on visitor.visits for each row execute function public.handle_updated_at();

alter table visitor.visits enable row level security;
create policy "View visits if can access site" on visitor.visits for select using (platform.can_access_site(site_id));
create policy "Members manage visits" on visitor.visits for all using (platform.can_access_site(site_id));

create table visitor.access_logs (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  visit_id uuid references visitor.visits(id) on delete set null,
  device_id text,
  access_point text,
  event text not null check (event in ('granted','denied','tailgate','forced')),
  timestamp timestamptz default now() not null,
  metadata jsonb default '{}'::jsonb
);

create index idx_access_site_time on visitor.access_logs(site_id, timestamp desc);
alter table visitor.access_logs enable row level security;
create policy "View access logs if can access site" on visitor.access_logs for select using (platform.can_access_site(site_id));
create policy "Members insert access logs" on visitor.access_logs for insert with check (platform.can_access_site(site_id));

-----------------------------
-- VENDOR SCHEMA (Compliance & Vendor Mgmt)
-----------------------------
do $$ begin
  create type vendor.vendor_type as enum ('cleaning','hvac','electrical','plumbing','security','landscaping','elevator','fire_safety','general','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type vendor.contract_status as enum ('draft','active','expired','terminated','pending_renewal');
exception when duplicate_object then null; end $$;

do $$ begin
  create type vendor.coi_status as enum ('valid','expiring','expired','missing','pending_review');
exception when duplicate_object then null; end $$;

do $$ begin
  create type vendor.compliance_status_type as enum ('compliant','non_compliant','pending','partial');
exception when duplicate_object then null; end $$;

create table vendor.vendors (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name text not null,
  type vendor.vendor_type not null default 'other',
  status text default 'active' check (status in ('active','inactive','pending','blocked')),
  website text,
  contact_email text,
  contact_phone text,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_vendors_org on vendor.vendors(org_id);
alter table vendor.vendors enable row level security;
create policy "View vendors if org member" on vendor.vendors for select using (platform.is_org_member(org_id));
create policy "Managers manage vendors" on vendor.vendors for all using (platform.is_org_member(org_id));

create table vendor.contracts (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete set null, -- null = org-wide
  title text not null,
  description text,
  status vendor.contract_status not null default 'active',
  start_date date,
  end_date date,
  value numeric(12,2),
  storage_path text, -- e.g., contracts pdf in storage
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_contracts_vendor on vendor.contracts(vendor_id);
create index idx_contracts_site on vendor.contracts(site_id);

create trigger set_contracts_updated_at before update on vendor.contracts for each row execute function public.handle_updated_at();

alter table vendor.contracts enable row level security;
create policy "View contracts if org member" on vendor.contracts for select using (platform.is_org_member(org_id));
create policy "Managers manage contracts" on vendor.contracts for all using (platform.is_org_member(org_id));

create table vendor.cois (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  contract_id uuid references vendor.contracts(id) on delete set null,
  site_id uuid references portfolio.sites(id) on delete set null,
  type text not null, -- e.g., 'general_liability', 'workers_comp', 'auto'
  issue_date date,
  expiry_date date not null,
  status vendor.coi_status not null default 'valid',
  coverage_amount numeric(12,2),
  storage_path text,
  verified_at timestamptz,
  verified_by uuid references platform.profiles(id),
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_cois_vendor on vendor.cois(vendor_id);
create index idx_cois_expiry on vendor.cois(expiry_date);
create index idx_cois_status on vendor.cois(status);

create trigger set_cois_updated_at before update on vendor.cois for each row execute function public.handle_updated_at();

alter table vendor.cois enable row level security;
create policy "View cois if org member" on vendor.cois for select using (platform.is_org_member(org_id));
create policy "Managers manage cois" on vendor.cois for all using (platform.is_org_member(org_id));

create table vendor.compliance_status (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete set null,
  status vendor.compliance_status_type not null default 'pending',
  issues jsonb default '[]'::jsonb, -- [{type, message, coi_id}]
  last_checked timestamptz default now() not null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique(vendor_id, site_id)
);

alter table vendor.compliance_status enable row level security;
create policy "View compliance if org member" on vendor.compliance_status for select using (platform.is_org_member(org_id));
create policy "System can manage compliance" on vendor.compliance_status for all using (true);

-----------------------------
-- METRICS SCHEMA (Portfolio & Analytics)
-----------------------------
create table metrics.daily_site_stats (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  date date not null,
  work_orders_open integer default 0,
  work_orders_closed integer default 0,
  work_orders_overdue integer default 0,
  sla_breaches integer default 0,
  visitor_count integer default 0,
  service_requests_count integer default 0,
  occupancy_rate numeric(5,2), -- 0-100
  compliance_rate numeric(5,2),
  avg_response_time_hours numeric,
  created_at timestamptz default now() not null,
  unique(site_id, date)
);

create index idx_daily_stats_site_date on metrics.daily_site_stats(site_id, date desc);

alter table metrics.daily_site_stats enable row level security;
create policy "View stats if can access site" on metrics.daily_site_stats for select using (platform.can_access_site(site_id));
create policy "System can manage stats" on metrics.daily_site_stats for all using (true);

-- Grants
grant all on all tables in schema ops to service_role;
grant all on all tables in schema tenant to service_role;
grant all on all tables in schema visitor to service_role;
grant all on all tables in schema vendor to service_role;
grant all on all tables in schema metrics to service_role;

grant usage, select, insert, update, delete on all tables in schema ops to authenticated;
grant usage, select, insert, update, delete on all tables in schema tenant to authenticated;
grant usage, select, insert, update, delete on all tables in schema visitor to authenticated;
grant usage, select, insert, update, delete on all tables in schema vendor to authenticated;
grant usage, select on all tables in schema metrics to authenticated;

grant usage on all sequences in schema ops to authenticated, service_role;
grant usage on all sequences in schema tenant to authenticated, service_role;
grant usage on all sequences in schema visitor to authenticated, service_role;
grant usage on all sequences in schema vendor to authenticated, service_role;
grant usage on all sequences in schema metrics to authenticated, service_role;

-- Realtime for critical tables
alter publication supabase_realtime add table ops.work_orders;
alter publication supabase_realtime add table ops.assets;
alter publication supabase_realtime add table tenant.service_requests;
alter publication supabase_realtime add table visitor.visits;
alter publication supabase_realtime add table vendor.compliance_status;
