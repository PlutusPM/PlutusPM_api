-- 00014_analytics_full.sql
-- Phase 4: Full Portfolio & Analytics - KPIs, Dashboards, Benchmarking, Scheduled Reports, Data Export

-----------------------------
-- KPI DEFINITIONS (customizable per org)
-----------------------------
create table metrics.kpi_definitions (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name text not null, -- e.g., "Occupancy Rate", "SLA Breach Rate"
  key text not null, -- machine key: occupancy_rate, sla_breach_rate, etc
  description text,
  category text not null check (category in ('operational','maintenance','compliance','occupancy','vendor','financial','tenant','visitor','safety')),
  unit text not null default 'percent' check (unit in ('percent','count','hours','currency','ratio','days')),
  target_value numeric,
  higher_is_better boolean default true, -- if false, lower is better (e.g., SLA breaches)
  formula text, -- optional: description of calculation {"source": "daily_site_stats", "field": "occupancy_rate"}
  is_active boolean default true not null,
  created_at timestamptz default now() not null,
  unique(org_id, key)
);

create index idx_kpi_defs_org on metrics.kpi_definitions(org_id);
create index idx_kpi_defs_category on metrics.kpi_definitions(category);

alter table metrics.kpi_definitions enable row level security;
create policy "View KPI defs if org member" on metrics.kpi_definitions for select using (platform.is_org_member(org_id));
create policy "Admins manage KPI defs" on metrics.kpi_definitions for all using (platform.is_org_admin(org_id));

-- Seed default KPIs (will be inserted in seed migration, but define function to create defaults)
create or replace function metrics.create_default_kpis(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = metrics, public
as $$
begin
  insert into metrics.kpi_definitions (org_id, name, key, description, category, unit, target_value, higher_is_better, formula)
  values
    (p_org_id, 'Occupancy Rate', 'occupancy_rate', 'Leased spaces / total leasable spaces', 'occupancy', 'percent', 95, true, '{"source":"daily_site_stats","field":"occupancy_rate"}'),
    (p_org_id, 'SLA Breach Rate', 'sla_breach_rate', '% of work orders missing SLA', 'maintenance', 'percent', 5, false, '{"source":"daily_site_stats","field":"sla_breaches / work_orders"}'),
    (p_org_id, 'Work Orders Open', 'work_orders_open', 'Open WOs at end of day', 'operational', 'count', 20, false, null),
    (p_org_id, 'Work Orders Closed Today', 'work_orders_closed', 'Closed today', 'operational', 'count', null, true, null),
    (p_org_id, 'Average Response Time', 'avg_response_time_hours', 'Avg hours from creation to first response', 'operational', 'hours', 4, false, null),
    (p_org_id, 'Preventive vs Corrective Ratio', 'pm_ratio', 'PM WOs / Total WOs', 'maintenance', 'ratio', 70, true, null),
    (p_org_id, 'Compliance Rate', 'compliance_rate', '% vendors compliant', 'compliance', 'percent', 100, true, '{"source":"daily_site_stats","field":"compliance_rate"}'),
    (p_org_id, 'Vendor Non-Compliant Count', 'non_compliant_vendors', 'Number of non-compliant vendors', 'compliance', 'count', 0, false, null),
    (p_org_id, 'Visitor Count', 'visitor_count', 'Visitors per day', 'visitor', 'count', null, true, null),
    (p_org_id, 'Service Request Response Time', 'service_request_avg_hours', 'Avg SR resolution hours', 'tenant', 'hours', 24, false, null),
    (p_org_id, 'Asset Health Score', 'asset_health_score', '% assets healthy', 'maintenance', 'percent', 95, true, null),
    (p_org_id, 'Labor Hours', 'labor_hours', 'Total labor hours logged', 'operational', 'hours', null, false, null),
    (p_org_id, 'Incidents Open', 'incidents_open', 'Open safety incidents', 'safety', 'count', 0, false, null)
  on conflict (org_id, key) do nothing;

  return 13;
end;
$$;

-----------------------------
-- ENHANCE DAILY SITE STATS (add columns for Phase 4)
-----------------------------
do $$ begin
  alter table metrics.daily_site_stats add column occupancy_rate numeric(5,2);
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column compliance_rate numeric(5,2);
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column avg_response_time_hours numeric;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column labor_hours numeric default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column pm_work_orders integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column corrective_work_orders integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column incidents_open integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column incidents_closed integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column inspections_completed integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column inspections_failed integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column total_assets integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column healthy_assets integer default 0;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table metrics.daily_site_stats add column reservation_count integer default 0;
exception when duplicate_column then null;
end $$;

-- Real occupancy etc: we compute in rollup function

-----------------------------
-- PORTFOLIO DAILY STATS (rollup from sites)
-----------------------------
create table metrics.portfolio_daily_stats (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  portfolio_id uuid not null references portfolio.portfolios(id) on delete cascade,
  date date not null,
  -- Aggregated from sites
  total_sites integer default 0,
  total_sq_ft bigint default 0,
  occupancy_rate numeric(5,2),
  work_orders_open integer default 0,
  work_orders_closed integer default 0,
  work_orders_overdue integer default 0,
  sla_breaches integer default 0,
  visitor_count integer default 0,
  service_requests_count integer default 0,
  compliance_rate numeric(5,2),
  occupancy_weighted numeric(5,2), -- weighted by sq_ft
  avg_response_time_hours numeric,
  labor_hours numeric default 0,
  incidents_open integer default 0,
  total_assets integer default 0,
  healthy_assets integer default 0,
  created_at timestamptz default now() not null,
  unique(portfolio_id, date)
);

create index idx_portfolio_daily_portfolio_date on metrics.portfolio_daily_stats(portfolio_id, date desc);
create index idx_portfolio_daily_org_date on metrics.portfolio_daily_stats(org_id, date desc);

alter table metrics.portfolio_daily_stats enable row level security;
create policy "View portfolio stats if org member" on metrics.portfolio_daily_stats for select using (platform.is_org_member(org_id));
create policy "System manages portfolio stats" on metrics.portfolio_daily_stats for all using (true);

-----------------------------
-- BUILDING BENCHMARKING VIEW
-----------------------------
-- Compare sites within same portfolio

create or replace view metrics.v_building_benchmark as
select
  s.org_id,
  s.portfolio_id,
  p.name as portfolio_name,
  s.id as site_id,
  s.name as site_name,
  s.city,
  s.type as site_type,
  s.sq_ft,
  d.date,
  d.occupancy_rate,
  d.work_orders_open,
  d.work_orders_closed,
  d.sla_breaches,
  d.compliance_rate,
  d.visitor_count,
  d.avg_response_time_hours,
  d.labor_hours,
  -- Benchmark vs portfolio avg - fixed d.portfolio_id does not exist, use s.portfolio_id
  avg(d.occupancy_rate) over (partition by s.portfolio_id, d.date) as portfolio_avg_occupancy,
  avg(d.compliance_rate) over (partition by s.portfolio_id, d.date) as portfolio_avg_compliance,
  avg(d.work_orders_open) over (partition by s.portfolio_id, d.date) as portfolio_avg_open_wos,
  rank() over (partition by s.portfolio_id, d.date order by d.occupancy_rate desc nulls last) as occupancy_rank,
  rank() over (partition by s.portfolio_id, d.date order by d.compliance_rate desc nulls last) as compliance_rank
from metrics.portfolio_daily_stats pd
join portfolio.portfolios p on p.id = pd.portfolio_id
join portfolio.sites s on s.portfolio_id = p.id
join metrics.daily_site_stats d on d.site_id = s.id and d.date = pd.date
where pd.date >= current_date - interval '30 days';

do $$ begin
  execute 'alter view metrics.v_building_benchmark set (security_invoker = true)';
exception when others then null;
end $$;

-- Asset health rollup per site
create or replace view metrics.v_asset_health_rollup as
select
  s.org_id,
  s.id as site_id,
  s.name as site_name,
  count(a.id) as total_assets,
  count(*) filter (where a.status = 'active') as active_assets,
  count(*) filter (where a.status = 'maintenance') as maintenance_assets,
  count(*) filter (where a.next_maintenance_at < now()) as overdue_maintenance,
  count(*) filter (where a.warranty_end < current_date) as warranty_expired,
  count(*) filter (where vh.health_status != 'healthy') as unhealthy_assets,
  avg(case when vh.health_status = 'healthy' then 1 else 0 end)::numeric *100 as health_score,
  count(wo.id) filter (where wo.status in ('open','in_progress','overdue')) as open_wos_for_assets
from portfolio.sites s
left join ops.assets a on a.site_id = s.id
left join ops.v_asset_health vh on vh.asset_id = a.id
left join ops.work_orders wo on wo.asset_id = a.id
group by s.org_id, s.id, s.name;

do $$ begin
  execute 'alter view metrics.v_asset_health_rollup set (security_invoker = true)';
exception when others then null;
end $$;

-- SLA Metrics view
create or replace view metrics.v_sla_metrics as
select
  wo.org_id,
  wo.site_id,
  s.name as site_name,
  date_trunc('day', wo.created_at)::date as date,
  count(*) as total_wos,
  count(*) filter (where wo.sla_due_at < wo.completed_at or (wo.completed_at is null and wo.sla_due_at < now())) as breached,
  count(*) filter (where wo.status = 'overdue') as overdue,
  avg(extract(epoch from (coalesce(wo.completed_at, now()) - wo.created_at))/3600) filter (where wo.completed_at is not null) as avg_hours_to_complete,
  avg(extract(epoch from (wo.sla_due_at - wo.created_at))/3600) as avg_sla_hours,
  count(*) filter (where wo.priority='urgent') as urgent_count,
  count(*) filter (where wo.priority='high') as high_count
from ops.work_orders wo
join portfolio.sites s on s.id = wo.site_id
group by wo.org_id, wo.site_id, s.name, date_trunc('day', wo.created_at)::date;

do $$ begin
  execute 'alter view metrics.v_sla_metrics set (security_invoker = true)';
exception when others then null;
end $$;

-----------------------------
-- REPORTS & SCHEDULED REPORTS
-----------------------------
do $$ begin
  create type metrics.report_type as enum ('daily_ops','weekly_exec','monthly_portfolio','compliance','occupancy','maintenance','financial','custom');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type metrics.report_format as enum ('json','csv','pdf');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type metrics.report_status as enum ('active','paused','archived');
exception when duplicate_object then null;
end $$;

create table metrics.reports (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  portfolio_id uuid references portfolio.portfolios(id) on delete set null,
  site_id uuid references portfolio.sites(id) on delete set null, -- null = all sites or portfolio-level
  name text not null,
  description text,
  type metrics.report_type not null default 'daily_ops',
  format metrics.report_format not null default 'csv',
  schedule_cron text not null default '0 7 * * 1', -- default weekly Monday 7am
  recipients text[] default array[]::text[], -- emails
  recipient_user_ids uuid[] default null, -- profile ids
  filters jsonb default '{}'::jsonb, -- {"include": ["work_orders","occupancy"], "date_range": "last_30_days"}
  status metrics.report_status not null default 'active',
  last_run_at timestamptz,
  next_run_at timestamptz,
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_reports_org on metrics.reports(org_id);
create index idx_reports_portfolio on metrics.reports(portfolio_id);
create index idx_reports_site on metrics.reports(site_id);
create index idx_reports_next_run on metrics.reports(next_run_at) where status='active';

create trigger set_reports_updated_at before update on metrics.reports for each row execute function public.handle_updated_at();

alter table metrics.reports enable row level security;
create policy "View reports if org member" on metrics.reports for select using (platform.is_org_member(org_id));
create policy "Managers manage reports" on metrics.reports for all using (platform.is_org_member(org_id));

create table metrics.report_runs (
  id uuid primary key default uuid_generate_v4(),
  report_id uuid not null references metrics.reports(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','running','completed','failed')),
  file_path text, -- storage path: org_id/reports/report_id/date/file.csv
  file_size integer,
  row_count integer,
  error_message text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz default now() not null
);

create index idx_report_runs_report on metrics.report_runs(report_id, created_at desc);

alter table metrics.report_runs enable row level security;
create policy "View report runs if org member" on metrics.report_runs for select using (platform.is_org_member(org_id));
create policy "System manages runs" on metrics.report_runs for all using (true);

-----------------------------
-- ENHANCED ROLLUP FUNCTIONS
-----------------------------

-- Enhanced daily site stats with occupancy, compliance, etc
create or replace function metrics.rollup_daily_stats_enhanced(p_date date default current_date - 1)
returns integer
language plpgsql
security definer
set search_path = metrics, portfolio, ops, tenant, visitor, vendor, public
as $$
declare
  rec record;
  inserted integer :=0;
  occ_rate numeric;
  comp_rate numeric;
  avg_resp numeric;
  labor numeric;
  pm_count integer;
  corr_count integer;
  incidents_o integer;
  incidents_c integer;
  insp_c integer;
  insp_f integer;
  total_a integer;
  healthy_a integer;
  res_c integer;
  wo_open integer;
  wo_closed integer;
  wo_overdue integer;
  sla_b integer;
  visit_c integer;
  sr_c integer;
begin
  for rec in select id, org_id from portfolio.sites where status = 'active' loop

    -- Occupancy: leased spaces / total leasable
    select
      case when count(*) filter (where type='leasable') =0 then null
      else (count(*) filter (where type='leasable' and status='occupied')::numeric / count(*) filter (where type='leasable')::numeric *100)
      end
    into occ_rate
    from portfolio.spaces where site_id = rec.id;

    -- Compliance: compliant vendors / total vendors for site
    select
      case when count(*) =0 then null
      else (count(*) filter (where status='compliant')::numeric / count(*)::numeric *100)
      end
    into comp_rate
    from vendor.compliance_status where site_id = rec.id;

    -- Avg response time: avg hours to first labor log or completion?
    select avg(extract(epoch from (coalesce(completed_at, now()) - created_at))/3600)::numeric
    into avg_resp
    from ops.work_orders where site_id = rec.id and created_at::date = p_date and status = 'completed';

    -- Labor hours
    select coalesce(sum(hours),0)::numeric into labor from ops.labor_logs where site_id = rec.id and logged_at::date = p_date;

    -- PM vs corrective
    select count(*) filter (where type='preventive'), count(*) filter (where type='corrective')
    into pm_count, corr_count
    from ops.work_orders where site_id = rec.id and created_at::date = p_date;

    -- Incidents
    select count(*) filter (where status in ('reported','investigating')), count(*) filter (where status in ('resolved','closed'))
    into incidents_o, incidents_c
    from ops.incidents where site_id = rec.id and occurred_at::date = p_date;

    -- Inspections
    select count(*) filter (where status='completed'), count(*) filter (where status='failed')
    into insp_c, insp_f
    from ops.inspections where site_id = rec.id and completed_at::date = p_date;

    -- Assets
    select count(*), count(*) filter (where status='active')
    into total_a, healthy_a
    from ops.assets where site_id = rec.id;

    -- Reservations
    select count(*) into res_c from tenant.reservations where site_id = rec.id and start_time::date = p_date;

    -- Work orders stats - separate queries for clarity
    select count(*) filter (where status in ('open','in_progress','on_hold') and created_at::date <= p_date and (completed_at is null or completed_at::date > p_date)),
           count(*) filter (where status='completed' and completed_at::date = p_date),
           count(*) filter (where status='overdue'),
           count(*) filter (where metadata->>'sla_breached'='true' and updated_at::date = p_date)
    into wo_open, wo_closed, wo_overdue, sla_b
    from ops.work_orders where site_id = rec.id;

    select count(*) into visit_c from visitor.visits where site_id = rec.id and scheduled_at::date = p_date;
    select count(*) into sr_c from tenant.service_requests where site_id = rec.id and created_at::date = p_date;

    insert into metrics.daily_site_stats (
      org_id, site_id, date,
      work_orders_open, work_orders_closed, work_orders_overdue, sla_breaches,
      visitor_count, service_requests_count,
      occupancy_rate, compliance_rate, avg_response_time_hours, labor_hours,
      pm_work_orders, corrective_work_orders, incidents_open, incidents_closed,
      inspections_completed, inspections_failed, total_assets, healthy_assets, reservation_count
    )
    values (
      rec.org_id, rec.id, p_date,
      wo_open, wo_closed, wo_overdue, sla_b,
      visit_c, sr_c,
      occ_rate, comp_rate, avg_resp, labor,
      pm_count, corr_count, incidents_o, incidents_c,
      insp_c, insp_f, total_a, healthy_a, res_c
    )
    on conflict (site_id, date) do update set
      work_orders_open = excluded.work_orders_open,
      work_orders_closed = excluded.work_orders_closed,
      work_orders_overdue = excluded.work_orders_overdue,
      sla_breaches = excluded.sla_breaches,
      visitor_count = excluded.visitor_count,
      service_requests_count = excluded.service_requests_count,
      occupancy_rate = excluded.occupancy_rate,
      compliance_rate = excluded.compliance_rate,
      avg_response_time_hours = excluded.avg_response_time_hours,
      labor_hours = excluded.labor_hours,
      pm_work_orders = excluded.pm_work_orders,
      corrective_work_orders = excluded.corrective_work_orders,
      incidents_open = excluded.incidents_open,
      incidents_closed = excluded.incidents_closed,
      inspections_completed = excluded.inspections_completed,
      inspections_failed = excluded.inspections_failed,
      total_assets = excluded.total_assets,
      healthy_assets = excluded.healthy_assets,
      reservation_count = excluded.reservation_count,
      created_at = now();

    inserted := inserted + 1;
  end loop;

  -- Also rollup portfolio stats
  perform metrics.rollup_portfolio_daily_stats(p_date);

  return inserted;
end;
$$;

-- Portfolio rollup
create or replace function metrics.rollup_portfolio_daily_stats(p_date date default current_date - 1)
returns integer
language plpgsql
security definer
set search_path = metrics, portfolio, public
as $$
declare
  rec record;
  inserted integer :=0;
begin
  for rec in select id, org_id from portfolio.portfolios loop
    insert into metrics.portfolio_daily_stats (
      org_id, portfolio_id, date, total_sites, total_sq_ft,
      occupancy_rate, work_orders_open, work_orders_closed, work_orders_overdue, sla_breaches,
      visitor_count, service_requests_count, compliance_rate, avg_response_time_hours, labor_hours, incidents_open, total_assets, healthy_assets
    )
    select
      rec.org_id,
      rec.id,
      p_date,
      count(distinct s.id),
      sum(s.sq_ft)::bigint,
      avg(d.occupancy_rate),
      sum(d.work_orders_open),
      sum(d.work_orders_closed),
      sum(d.work_orders_overdue),
      sum(d.sla_breaches),
      sum(d.visitor_count),
      sum(d.service_requests_count),
      avg(d.compliance_rate),
      avg(d.avg_response_time_hours),
      sum(d.labor_hours),
      sum(d.incidents_open),
      sum(d.total_assets),
      sum(d.healthy_assets)
    from portfolio.sites s
    join metrics.daily_site_stats d on d.site_id = s.id and d.date = p_date
    where s.portfolio_id = rec.id
    group by rec.org_id, rec.id
    on conflict (portfolio_id, date) do update set
      total_sites = excluded.total_sites,
      total_sq_ft = excluded.total_sq_ft,
      occupancy_rate = excluded.occupancy_rate,
      work_orders_open = excluded.work_orders_open,
      work_orders_closed = excluded.work_orders_closed,
      work_orders_overdue = excluded.work_orders_overdue,
      sla_breaches = excluded.sla_breaches,
      visitor_count = excluded.visitor_count,
      service_requests_count = excluded.service_requests_count,
      compliance_rate = excluded.compliance_rate,
      avg_response_time_hours = excluded.avg_response_time_hours,
      labor_hours = excluded.labor_hours,
      incidents_open = excluded.incidents_open,
      total_assets = excluded.total_assets,
      healthy_assets = excluded.healthy_assets,
      created_at = now();

    inserted := inserted + 1;
  end loop;

  return inserted;
end;
$$;

-- Replace old rollup function to call enhanced
create or replace function metrics.rollup_daily_stats(p_date date default current_date - 1)
returns integer
language sql
security definer
set search_path = metrics, public
as $$
  select metrics.rollup_daily_stats_enhanced(p_date);
$$;

-- KPI snapshot function (returns current KPIs for site)
create or replace function metrics.get_site_kpis(p_site_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = metrics, platform, public
as $$
declare
  result jsonb;
  site_org uuid;
begin
  if not platform.can_access_site(p_site_id) then raise exception 'Access denied'; end if;

  select org_id into site_org from portfolio.sites where id = p_site_id;

  select jsonb_build_object(
    'site_id', p_site_id,
    'date', (select date from metrics.daily_site_stats where site_id = p_site_id order by date desc limit 1),
    'occupancy_rate', (select occupancy_rate from metrics.daily_site_stats where site_id = p_site_id order by date desc limit 1),
    'compliance_rate', (select compliance_rate from metrics.daily_site_stats where site_id = p_site_id order by date desc limit 1),
    'work_orders_open', (select work_orders_open from metrics.daily_site_stats where site_id = p_site_id order by date desc limit 1),
    'sla_breach_rate', (
      select case when (work_orders_open + work_orders_closed) =0 then 0 else (sla_breaches::numeric / (work_orders_open + work_orders_closed)::numeric *100) end
      from metrics.daily_site_stats where site_id = p_site_id order by date desc limit 1
    ),
    'visitor_today', (select visitor_count from metrics.daily_site_stats where site_id = p_site_id and date = current_date),
    'labor_hours_7d', (select sum(labor_hours) from metrics.daily_site_stats where site_id = p_site_id and date >= current_date - interval '7 days'),
    'asset_health_score', (
      select case when total_assets=0 then null else (healthy_assets::numeric / total_assets::numeric *100) end
      from metrics.daily_site_stats where site_id = p_site_id order by date desc limit 1
    ),
    'avg_response_time', (select avg_response_time_hours from metrics.daily_site_stats where site_id = p_site_id order by date desc limit 1)
  ) into result;

  return result;
end;
$$;

comment on function metrics.get_site_kpis(uuid) is '@graphql({"type": "query", "name": "getSiteKPIs"})';

-- Portfolio KPIs
create or replace function metrics.get_portfolio_kpis(p_portfolio_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = metrics, platform, public
as $$
declare
  result jsonb;
begin
  if not platform.is_org_member((select org_id from portfolio.portfolios where id = p_portfolio_id)) then
    raise exception 'Access denied';
  end if;

  select jsonb_build_object(
    'portfolio_id', p_portfolio_id,
    'date', (select date from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id order by date desc limit 1),
    'total_sites', (select total_sites from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id order by date desc limit 1),
    'total_sq_ft', (select total_sq_ft from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id order by date desc limit 1),
    'occupancy_rate', (select occupancy_rate from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id order by date desc limit 1),
    'compliance_rate', (select compliance_rate from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id order by date desc limit 1),
    'work_orders_open', (select work_orders_open from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id order by date desc limit 1),
    'sla_breaches_7d', (select sum(sla_breaches) from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id and date >= current_date - interval '7 days'),
    'labor_hours_7d', (select sum(labor_hours) from metrics.portfolio_daily_stats where portfolio_id = p_portfolio_id and date >= current_date - interval '7 days')
  ) into result;

  return result;
end;
$$;

comment on function metrics.get_portfolio_kpis(uuid) is '@graphql({"type": "query", "name": "getPortfolioKPIs"})';

-- Grants
grant all on all tables in schema metrics to service_role;
grant select, insert, update, delete on all tables in schema metrics to authenticated;
grant usage on all sequences in schema metrics to authenticated, service_role;

-- Realtime for reports
do $$ begin
  alter publication supabase_realtime add table metrics.reports;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table metrics.report_runs;
exception when duplicate_object then null;
end $$;
