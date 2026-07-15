-- 00007_ops_phase1_full.sql
-- Phase 1: Full Building Operations - Checklists, Inspections, Inventory, Labor, Incidents
-- Builds on top of existing ops assets & work_orders

-----------------------------
-- EXTEND ASSETS FOR HIERARCHY
-----------------------------
do $$ begin
  alter table ops.assets add column parent_asset_id uuid references ops.assets(id) on delete set null;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table ops.assets add column location_description text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table ops.assets add column qr_code_last_printed_at timestamptz;
exception when duplicate_column then null;
end $$;

create index if not exists idx_assets_parent on ops.assets(parent_asset_id);
create index if not exists idx_assets_site_category_status on ops.assets(site_id, category_id, status);

-- Asset maintenance history (explicit, separate from work_orders if needed for import)
create table ops.asset_maintenance_history (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  asset_id uuid not null references ops.assets(id) on delete cascade,
  work_order_id uuid references ops.work_orders(id) on delete set null,
  type text not null check (type in ('inspection','preventive','corrective','installation','decommission','audit')),
  title text not null,
  description text,
  performed_by uuid references platform.profiles(id) on delete set null,
  performed_at timestamptz not null default now(),
  cost numeric(12,2) default 0,
  labor_hours numeric default 0,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null
);

create index idx_maint_hist_asset on ops.asset_maintenance_history(asset_id, performed_at desc);
create index idx_maint_hist_site on ops.asset_maintenance_history(site_id, performed_at desc);

alter table ops.asset_maintenance_history enable row level security;
create policy "View history if can access site" on ops.asset_maintenance_history for select using (platform.can_access_site(site_id));
create policy "Members manage history" on ops.asset_maintenance_history for all using (platform.can_access_site(site_id));

-----------------------------
-- DIGITAL CHECKLISTS (Templates)
-----------------------------
do $$ begin
  create type ops.checklist_item_type as enum ('pass_fail','yes_no','numeric','text','photo','signature','multiple_choice');
exception when duplicate_object then null;
end $$;

create table ops.checklists (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete cascade, -- null = org template library
  name text not null,
  description text,
  category text, -- e.g., 'hvac', 'fire_safety', 'elevator'
  version integer default 1 not null,
  is_active boolean default true not null,
  is_required boolean default false,
  estimated_minutes integer,
  metadata jsonb default '{}'::jsonb,
  created_by uuid references platform.profiles(id),
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_checklists_org on ops.checklists(org_id);
create index idx_checklists_site on ops.checklists(site_id);

create trigger set_checklists_updated_at before update on ops.checklists for each row execute function public.handle_updated_at();

alter table ops.checklists enable row level security;
create policy "View checklists if org member" on ops.checklists for select using (platform.is_org_member(org_id));
create policy "Managers manage checklists" on ops.checklists for all using (platform.is_org_member(org_id));

create table ops.checklist_items (
  id uuid primary key default uuid_generate_v4(),
  checklist_id uuid not null references ops.checklists(id) on delete cascade,
  parent_item_id uuid references ops.checklist_items(id) on delete cascade, -- for nesting/conditional
  sort_order integer not null default 0,
  label text not null,
  description text,
  item_type ops.checklist_item_type not null default 'pass_fail',
  is_required boolean default false not null,
  options jsonb default '[]'::jsonb, -- for multiple_choice: ["Good","Fair","Poor"]
  expected_value jsonb, -- for compliance: {"pass": ["Yes","Pass"], "fail": ["No"]}
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null
);

create index idx_checklist_items_checklist on ops.checklist_items(checklist_id, sort_order);

alter table ops.checklist_items enable row level security;
create policy "View checklist items if org member" on ops.checklist_items for select using (
  exists (select 1 from ops.checklists c where c.id = checklist_id and platform.is_org_member(c.org_id))
);
create policy "Managers manage checklist items" on ops.checklist_items for all using (
  exists (select 1 from ops.checklists c where c.id = checklist_id and platform.is_org_member(c.org_id))
);

-----------------------------
-- INSPECTIONS (Instance of Checklist performed)
-----------------------------
do $$ begin
  create type ops.inspection_status as enum ('draft','in_progress','completed','failed','cancelled','overdue');
exception when duplicate_object then null;
end $$;

create table ops.inspections (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  asset_id uuid references ops.assets(id) on delete set null,
  building_id uuid references portfolio.buildings(id) on delete set null,
  floor_id uuid references portfolio.floors(id) on delete set null,
  space_id uuid references portfolio.spaces(id) on delete set null,
  checklist_id uuid not null references ops.checklists(id) on delete set null,
  work_order_id uuid references ops.work_orders(id) on delete set null, -- if inspection linked to WO
  title text not null,
  status ops.inspection_status not null default 'draft',
  score numeric(5,2), -- 0-100 compliance score
  assigned_to uuid references platform.profiles(id) on delete set null,
  created_by uuid references platform.profiles(id),
  scheduled_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_inspections_site on ops.inspections(site_id, status, scheduled_at desc);
create index idx_inspections_asset on ops.inspections(asset_id);
create index idx_inspections_assigned on ops.inspections(assigned_to);

create trigger set_inspections_updated_at before update on ops.inspections for each row execute function public.handle_updated_at();

alter table ops.inspections enable row level security;
create policy "View inspections if can access site" on ops.inspections for select using (platform.can_access_site(site_id));
create policy "Members create inspections" on ops.inspections for insert with check (platform.can_access_site(site_id));
create policy "Members update inspections" on ops.inspections for update using (platform.can_access_site(site_id));
create policy "Managers delete inspections" on ops.inspections for delete using (platform.is_site_manager(site_id));

-- Inspection responses (one per checklist item)
create table ops.inspection_items (
  id uuid primary key default uuid_generate_v4(),
  inspection_id uuid not null references ops.inspections(id) on delete cascade,
  checklist_item_id uuid not null references ops.checklist_items(id) on delete cascade,
  status text check (status in ('pass','fail','na','flagged','pending')),
  response_text text,
  response_numeric numeric,
  response_options jsonb, -- selected options
  is_flagged boolean default false, -- requires attention
  notes text,
  photo_paths text[], -- array of storage paths
  scored integer default 0, -- points
  answered_by uuid references platform.profiles(id) on delete set null,
  answered_at timestamptz,
  created_at timestamptz default now() not null,
  unique(inspection_id, checklist_item_id)
);

create index idx_insp_items_insp on ops.inspection_items(inspection_id);
create index idx_insp_items_flagged on ops.inspection_items(is_flagged) where is_flagged = true;

alter table ops.inspection_items enable row level security;
create policy "View inspection items if can access site" on ops.inspection_items for select using (
  exists (select 1 from ops.inspections i where i.id = inspection_id and platform.can_access_site(i.site_id))
);
create policy "Members manage inspection items" on ops.inspection_items for all using (
  exists (select 1 from ops.inspections i where i.id = inspection_id and platform.can_access_site(i.site_id))
);

-----------------------------
-- WORK ORDER ENHANCEMENTS
-----------------------------
create table ops.work_order_comments (
  id uuid primary key default uuid_generate_v4(),
  work_order_id uuid not null references ops.work_orders(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  user_id uuid not null references platform.profiles(id) on delete cascade,
  comment text not null,
  is_internal boolean default false, -- internal note vs public
  created_at timestamptz default now() not null
);

create index idx_wo_comments_wo on ops.work_order_comments(work_order_id, created_at desc);

alter table ops.work_order_comments enable row level security;
create policy "View comments if can access site" on ops.work_order_comments for select using (platform.can_access_site(site_id));
create policy "Members create comments" on ops.work_order_comments for insert with check (platform.can_access_site(site_id));

create table ops.work_order_attachments (
  id uuid primary key default uuid_generate_v4(),
  work_order_id uuid not null references ops.work_orders(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  file_name text not null,
  file_size integer,
  mime_type text,
  storage_path text not null, -- org_id/site_id/work_orders/wo_id/filename
  uploaded_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null
);

alter table ops.work_order_attachments enable row level security;
create policy "View attachments if can access site" on ops.work_order_attachments for select using (platform.can_access_site(site_id));
create policy "Members manage attachments" on ops.work_order_attachments for all using (platform.can_access_site(site_id));

-----------------------------
-- INVENTORY & PARTS MANAGEMENT
-----------------------------
create table ops.inventory_categories (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name text not null,
  description text,
  unique(org_id, name)
);

create table ops.inventory_items (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  category_id uuid references ops.inventory_categories(id) on delete set null,
  name text not null,
  sku text,
  description text,
  unit text default 'each', -- each, box, meter, liter
  cost_per_unit numeric(10,2),
  supplier text,
  min_stock_level integer default 5,
  is_active boolean default true,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique(org_id, sku)
);

create trigger set_inventory_items_updated_at before update on ops.inventory_items for each row execute function public.handle_updated_at();

create table ops.inventory_stock (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  inventory_item_id uuid not null references ops.inventory_items(id) on delete cascade,
  quantity integer not null default 0 check (quantity >= 0),
  location text, -- e.g., "Storage Room A, Shelf 3"
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique(site_id, inventory_item_id)
);

create trigger set_inventory_stock_updated_at before update on ops.inventory_stock for each row execute function public.handle_updated_at();

create table ops.stock_transactions (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  inventory_item_id uuid not null references ops.inventory_items(id) on delete cascade,
  stock_id uuid references ops.inventory_stock(id) on delete set null,
  work_order_id uuid references ops.work_orders(id) on delete set null,
  type text not null check (type in ('in','out','adjustment','transfer','return')),
  quantity integer not null, -- positive for in, negative for out handled via type, but store signed? We'll store positive and infer by type, but allow negative for adjustment
  reason text,
  performed_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null
);

create index idx_stock_trans_site_item on ops.stock_transactions(site_id, inventory_item_id, created_at desc);

-- RLS for inventory
alter table ops.inventory_categories enable row level security;
alter table ops.inventory_items enable row level security;
alter table ops.inventory_stock enable row level security;
alter table ops.stock_transactions enable row level security;

create policy "View inventory cats if org member" on ops.inventory_categories for select using (platform.is_org_member(org_id));
create policy "Managers manage inventory cats" on ops.inventory_categories for all using (platform.is_org_member(org_id));

create policy "View inventory items if org member" on ops.inventory_items for select using (platform.is_org_member(org_id));
create policy "Managers manage inventory items" on ops.inventory_items for all using (platform.is_org_member(org_id));

create policy "View stock if can access site" on ops.inventory_stock for select using (platform.can_access_site(site_id));
create policy "Members manage stock" on ops.inventory_stock for all using (platform.can_access_site(site_id));

create policy "View stock trans if can access site" on ops.stock_transactions for select using (platform.can_access_site(site_id));
create policy "Members manage stock trans" on ops.stock_transactions for all using (platform.can_access_site(site_id));

-----------------------------
-- LABOR TRACKING
-----------------------------
create table ops.labor_logs (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  work_order_id uuid not null references ops.work_orders(id) on delete cascade,
  user_id uuid not null references platform.profiles(id) on delete cascade,
  hours numeric(5,2) not null check (hours > 0),
  rate numeric(10,2), -- hourly rate
  total_cost numeric(12,2) generated always as (hours * coalesce(rate,0)) stored,
  description text,
  logged_at timestamptz not null default now(),
  created_at timestamptz default now() not null
);

create index idx_labor_wo on ops.labor_logs(work_order_id);
create index idx_labor_user on ops.labor_logs(user_id, logged_at desc);
create index idx_labor_site on ops.labor_logs(site_id, logged_at desc);

alter table ops.labor_logs enable row level security;
create policy "View labor if can access site" on ops.labor_logs for select using (platform.can_access_site(site_id));
create policy "Members manage labor" on ops.labor_logs for all using (platform.can_access_site(site_id));

-- Trigger to update work_order labor_hours and cost from labor_logs
create or replace function ops.update_wo_labor_totals()
returns trigger
language plpgsql
as $$
begin
  update ops.work_orders
  set labor_hours = (select coalesce(sum(hours),0) from ops.labor_logs where work_order_id = coalesce(new.work_order_id, old.work_order_id)),
      cost = (select coalesce(sum(total_cost),0) from ops.labor_logs where work_order_id = coalesce(new.work_order_id, old.work_order_id)) + coalesce(cost,0), -- keep parts cost separate? For now sum labor
      updated_at = now()
  where id = coalesce(new.work_order_id, old.work_order_id);
  return new;
end;
$$;

create trigger trg_labor_update_wo
  after insert or update or delete on ops.labor_logs
  for each row execute function ops.update_wo_labor_totals();

-----------------------------
-- INCIDENT MANAGEMENT
-----------------------------
do $$ begin
  create type ops.incident_severity as enum ('low','medium','high','critical');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ops.incident_status as enum ('reported','investigating','resolved','closed','escalated');
exception when duplicate_object then null;
end $$;

create table ops.incidents (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  building_id uuid references portfolio.buildings(id) on delete set null,
  floor_id uuid references portfolio.floors(id) on delete set null,
  space_id uuid references portfolio.spaces(id) on delete set null,
  asset_id uuid references ops.assets(id) on delete set null,
  work_order_id uuid references ops.work_orders(id) on delete set null,
  title text not null,
  description text,
  severity ops.incident_severity not null default 'medium',
  status ops.incident_status not null default 'reported',
  category text, -- safety, environmental, security, operational
  reported_by uuid references platform.profiles(id) on delete set null,
  assigned_to uuid references platform.profiles(id) on delete set null,
  occurred_at timestamptz not null default now(),
  resolved_at timestamptz,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_incidents_site on ops.incidents(site_id, status, occurred_at desc);
create index idx_incidents_severity on ops.incidents(severity);

create trigger set_incidents_updated_at before update on ops.incidents for each row execute function public.handle_updated_at();

alter table ops.incidents enable row level security;
create policy "View incidents if can access site" on ops.incidents for select using (platform.can_access_site(site_id));
create policy "Members manage incidents" on ops.incidents for all using (platform.can_access_site(site_id));

-----------------------------
-- ENGINEERING REPORTS (views for daily/weekly)
-----------------------------
create or replace view ops.v_asset_health as
select
  a.id as asset_id,
  a.site_id,
  a.org_id,
  a.name,
  a.status,
  a.criticality,
  a.last_maintenance_at,
  a.next_maintenance_at,
  count(wo.id) filter (where wo.status in ('open','in_progress','overdue')) as open_work_orders,
  count(i.id) filter (where i.status = 'failed') as failed_inspections,
  max(mh.performed_at) as last_maintenance,
  case 
    when a.warranty_end < current_date then 'warranty_expired'
    when a.next_maintenance_at < now() then 'maintenance_overdue'
    when count(wo.id) filter (where wo.status = 'overdue') > 0 then 'has_overdue_wo'
    else 'healthy'
  end as health_status
from ops.assets a
left join ops.work_orders wo on wo.asset_id = a.id
left join ops.inspections i on i.asset_id = a.id
left join ops.asset_maintenance_history mh on mh.asset_id = a.id
group by a.id, a.site_id, a.org_id, a.name, a.status, a.criticality, a.last_maintenance_at, a.next_maintenance_at, a.warranty_end;

-- For simplicity, make view security invoker so RLS applies via underlying tables? 
-- In pg 15, security_invoker = true makes view use caller's RLS
-- We'll set it if PG version supports
do $$ begin
  execute 'alter view ops.v_asset_health set (security_invoker = true)';
exception when others then null;
end $$;

-----------------------------
-- FUNCTIONS FOR PHASE 1
-----------------------------

-- Create inspection from checklist
create or replace function ops.create_inspection_from_checklist(
  p_site_id uuid,
  p_checklist_id uuid,
  p_asset_id uuid default null,
  p_title text default null,
  p_assigned_to uuid default null,
  p_scheduled_at timestamptz default now()
)
returns ops.inspections
language plpgsql
security definer
set search_path = ops, platform, portfolio, public
as $$
declare
  new_insp ops.inspections;
  v_org_id uuid;
  v_title text;
  item ops.checklist_items%rowtype;
begin
  if not platform.can_access_site(p_site_id) then raise exception 'Access denied'; end if;
  select org_id into v_org_id from portfolio.sites where id = p_site_id;

  select coalesce(p_title, name || ' - ' || to_char(p_scheduled_at,'YYYY-MM-DD')) into v_title from ops.checklists where id = p_checklist_id;

  insert into ops.inspections (org_id, site_id, asset_id, checklist_id, title, status, assigned_to, scheduled_at, created_by)
  values (v_org_id, p_site_id, p_asset_id, p_checklist_id, v_title, 'draft', coalesce(p_assigned_to, auth.uid()), p_scheduled_at, auth.uid())
  returning * into new_insp;

  -- Auto-create inspection_items for each checklist item
  for item in select * from ops.checklist_items where checklist_id = p_checklist_id order by sort_order loop
    insert into ops.inspection_items (inspection_id, checklist_item_id, status)
    values (new_insp.id, item.id, 'pending');
  end loop;

  return new_insp;
end;
$$;

comment on function ops.create_inspection_from_checklist(uuid, uuid, uuid, text, uuid, timestamptz) is '@graphql({"type": "mutation", "name": "createInspectionFromChecklist"})';

-- Complete inspection - calculate score
create or replace function ops.complete_inspection(p_inspection_id uuid)
returns ops.inspections
language plpgsql
security definer
set search_path = ops, platform, public
as $$
declare
  insp ops.inspections;
  total integer;
  passed integer;
  score numeric;
  failed_items integer;
begin
  select * into insp from ops.inspections where id = p_inspection_id;
  if not found then raise exception 'Inspection not found'; end if;
  if not platform.can_access_site(insp.site_id) then raise exception 'Access denied'; end if;

  select count(*) into total from ops.inspection_items where inspection_id = p_inspection_id;
  select count(*) into passed from ops.inspection_items where inspection_id = p_inspection_id and status = 'pass';
  select count(*) into failed_items from ops.inspection_items where inspection_id = p_inspection_id and status = 'fail';

  if total > 0 then score := (passed::numeric / total::numeric) * 100;
  else score := 0; end if;

  update ops.inspections
  set status = case when failed_items > 0 then 'failed' else 'completed' end,
      score = score,
      completed_at = now(),
      updated_at = now()
  where id = p_inspection_id
  returning * into insp;

  -- If failed, auto-create WO if configured
  if failed_items > 0 then
    insert into ops.work_orders (org_id, site_id, asset_id, title, description, priority, type, created_by, status)
    values (
      insp.org_id, insp.site_id, insp.asset_id,
      'Corrective WO from failed inspection: ' || insp.title,
      'Inspection ' || insp.id || ' failed with ' || failed_items || ' items flagged. Score: ' || score || '%',
      'high', 'corrective', auth.uid(), 'open'
    );
  end if;

  -- Log to maintenance history if asset inspection
  if insp.asset_id is not null then
    insert into ops.asset_maintenance_history (org_id, site_id, asset_id, type, title, performed_by, performed_at)
    values (insp.org_id, insp.site_id, insp.asset_id, 'inspection', insp.title, auth.uid(), now());
  end if;

  return insp;
end;
$$;

comment on function ops.complete_inspection(uuid) is '@graphql({"type": "mutation", "name": "completeInspection"})';

-- Asset maintenance history function
create or replace function ops.get_asset_history(p_asset_id uuid, p_limit integer default 20)
returns setof ops.asset_maintenance_history
language sql
security definer
set search_path = ops, platform, public
as $$
  select * from ops.asset_maintenance_history
  where asset_id = p_asset_id
  and platform.can_access_site(site_id)
  order by performed_at desc
  limit p_limit;
$$;

comment on function ops.get_asset_history(uuid, integer) is '@graphql({"type": "query", "name": "getAssetHistory"})';

-- Low stock alert function (for cron)
create or replace function ops.check_low_stock()
returns table (site_id uuid, inventory_item_id uuid, current_qty integer, min_level integer)
language sql
security definer
set search_path = ops, public
as $$
  select s.site_id, s.inventory_item_id, s.quantity, i.min_stock_level
  from ops.inventory_stock s
  join ops.inventory_items i on i.id = s.inventory_item_id
  where s.quantity <= i.min_stock_level;
$$;

-- Grant permissions
grant all on all tables in schema ops to service_role;
grant select, insert, update, delete on all tables in schema ops to authenticated;
grant usage on all sequences in schema ops to authenticated, service_role;

-- Realtime for new tables
alter publication supabase_realtime add table ops.inspections;
alter publication supabase_realtime add table ops.inspection_items;
alter publication supabase_realtime add table ops.incidents;
alter publication supabase_realtime add table ops.work_order_comments;
alter publication supabase_realtime add table ops.inventory_stock;

-- Add cron for low stock check daily 8am
select cron.schedule(
  'check-low-stock',
  '0 8 * * *',
  $$
  insert into platform.notifications (org_id, site_id, type, title, body, payload)
  select org_id, site_id, 'system', 'Low stock: ' || (select name from ops.inventory_items where id = inventory_item_id), 'Quantity ' || current_qty || ' below min ' || min_level, jsonb_build_object('inventory_item_id', inventory_item_id, 'current_qty', current_qty)
  from ops.check_low_stock();
  $$
) where not exists (select 1 from cron.job where jobname='check-low-stock');

-- Add cron for daily asset health snapshot? Could be a materialized view refresh
