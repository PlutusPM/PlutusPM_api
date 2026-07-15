-- 00004_graphql_scheduler.sql
-- GraphQL setup + Scheduler (pg_cron) jobs

-----------------------------
-- GRAPHQL CONFIG
-----------------------------
-- Grant schema usage for graphql
-- Comment annotations to expose via GraphQL
-- pg_graphql uses comments like '@graphql({"type": "query"})'

-- Ensure graphql schema rebuilds (if function exists - in newer pg_graphql it auto-rebuilds)
do $$
begin
  perform graphql.rebuild_schema();
exception when undefined_function or others then
  raise notice 'graphql.rebuild_schema() not available - skipping (auto-rebuilds on DDL in newer pg_graphql)';
end;
$$;

-----------------------------
-- CUSTOM GRAPHQL FUNCTIONS (Examples for frontend)
-----------------------------

-- Create work order mutation
create or replace function ops.create_work_order(
  p_site_id uuid,
  p_title text,
  p_description text default null,
  p_asset_id uuid default null,
  p_space_id uuid default null,
  p_priority ops.priority_level default 'medium',
  p_type ops.work_order_type default 'corrective',
  p_due_date timestamptz default null
)
returns ops.work_orders
language plpgsql
security definer
set search_path = ops, platform, portfolio, public
as $$
declare
  new_wo ops.work_orders;
  v_org_id uuid;
  v_sla_hours integer;
begin
  if not platform.can_access_site(p_site_id) then
    raise exception 'Access denied to site %', p_site_id;
  end if;

  select org_id into v_org_id from portfolio.sites where id = p_site_id;
  if v_org_id is null then raise exception 'Site not found'; end if;

  -- SLA calculation: urgent 4h, high 24h, medium 72h, low 168h
  v_sla_hours := case p_priority
    when 'urgent' then 4
    when 'high' then 24
    when 'medium' then 72
    when 'low' then 168
    else 72
  end;

  insert into ops.work_orders (org_id, site_id, asset_id, space_id, title, description, priority, type, due_date, sla_due_at, created_by, status)
  values (
    v_org_id, p_site_id, p_asset_id, p_space_id, p_title, p_description, p_priority, p_type,
    coalesce(p_due_date, now() + (v_sla_hours || ' hours')::interval),
    now() + (v_sla_hours || ' hours')::interval,
    auth.uid(),
    'open'
  ) returning * into new_wo;

  insert into platform.audit_logs (org_id, site_id, user_id, action, entity, entity_id)
  values (v_org_id, p_site_id, auth.uid(), 'create', 'work_order', new_wo.id);

  return new_wo;
end;
$$;

comment on function ops.create_work_order(uuid, text, text, uuid, uuid, ops.priority_level, ops.work_order_type, timestamptz) is '@graphql({"type": "mutation", "name": "createWorkOrder"})';

-- Complete work order
create or replace function ops.complete_work_order(p_work_order_id uuid, p_notes text default null)
returns ops.work_orders
language plpgsql
security definer
set search_path = ops, platform, public
as $$
declare
  wo ops.work_orders;
begin
  select * into wo from ops.work_orders where id = p_work_order_id;
  if not found then raise exception 'Work order not found'; end if;
  if not platform.can_access_site(wo.site_id) then raise exception 'Access denied'; end if;

  update ops.work_orders
  set status = 'completed', completed_at = now(), description = coalesce(description,'') || coalesce(' Note: ' || p_notes, ''), updated_at = now()
  where id = p_work_order_id
  returning * into wo;

  insert into platform.notifications (org_id, site_id, type, title, body, payload)
  values (wo.org_id, wo.site_id, 'work_order_assigned', 'Work order completed', wo.title, jsonb_build_object('work_order_id', wo.id));

  return wo;
end;
$$;

comment on function ops.complete_work_order(uuid, text) is '@graphql({"type": "mutation", "name": "completeWorkOrder"})';

-- Register visitor mutation
create or replace function visitor.register_visitor(
  p_site_id uuid,
  p_name text,
  p_email text,
  p_company text default null,
  p_purpose text default 'Meeting',
  p_host_user_id uuid default null,
  p_scheduled_at timestamptz default now()
)
returns visitor.visits
language plpgsql
security definer
set search_path = visitor, platform, portfolio, public
as $$
declare
  v_org_id uuid;
  v_visitor visitor.visitors;
  new_visit visitor.visits;
begin
  if not platform.can_access_site(p_site_id) then raise exception 'Access denied to site'; end if;
  select org_id into v_org_id from portfolio.sites where id = p_site_id;

  -- Upsert visitor
  insert into visitor.visitors (org_id, email, full_name, company)
  values (v_org_id, p_email, p_name, p_company)
  on conflict (org_id, email) do update set full_name = excluded.full_name, company = excluded.company
  returning * into v_visitor;

  -- If visitor without email uniqueness, create new
  if p_email is null or p_email = '' then
    insert into visitor.visitors (org_id, full_name, company) values (v_org_id, p_name, p_company) returning * into v_visitor;
  end if;

  insert into visitor.visits (org_id, site_id, visitor_id, host_user_id, purpose, scheduled_at, status)
  values (v_org_id, p_site_id, v_visitor.id, p_host_user_id, p_purpose, p_scheduled_at, 'preregistered')
  returning * into new_visit;

  return new_visit;
end;
$$;

comment on function visitor.register_visitor(uuid, text, text, text, text, uuid, timestamptz) is '@graphql({"type": "mutation", "name": "registerVisitor"})';

-- Create service request -> auto WO option
create or replace function tenant.create_service_request(
  p_site_id uuid,
  p_space_id uuid,
  p_title text,
  p_description text default null,
  p_priority ops.priority_level default 'medium'
)
returns tenant.service_requests
language plpgsql
security definer
set search_path = tenant, platform, portfolio, ops, public
as $$
declare
  v_org_id uuid;
  new_sr tenant.service_requests;
  new_wo ops.work_orders;
begin
  if not platform.can_access_site(p_site_id) then raise exception 'Access denied'; end if;
  select org_id into v_org_id from portfolio.sites where id = p_site_id;

  insert into tenant.service_requests (org_id, site_id, space_id, title, description, priority, created_by, status)
  values (v_org_id, p_site_id, p_space_id, p_title, p_description, p_priority, auth.uid(), 'open')
  returning * into new_sr;

  -- Auto-create work order for service request
  insert into ops.work_orders (org_id, site_id, space_id, title, description, priority, type, created_by, status)
  values (v_org_id, p_site_id, p_space_id, 'SR: ' || p_title, p_description, p_priority, 'service_request', auth.uid(), 'open')
  returning * into new_wo;

  update tenant.service_requests set work_order_id = new_wo.id where id = new_sr.id returning * into new_sr;

  return new_sr;
end;
$$;

comment on function tenant.create_service_request(uuid, uuid, text, text, ops.priority_level) is '@graphql({"type": "mutation", "name": "createServiceRequest"})';

-----------------------------
-- SCHEDULER FUNCTIONS (called by pg_cron)
-----------------------------

-- SLA breach detection
create or replace function ops.check_sla_breaches()
returns integer
language plpgsql
security definer
set search_path = ops, platform, public
as $$
declare
  breached_count integer;
begin
  with breached as (
    update ops.work_orders
    set status = 'overdue', metadata = coalesce(metadata,'{}'::jsonb) || '{"sla_breached": true, "sla_breached_at": "'|| now()::text || '"}'::jsonb
    where status not in ('completed','cancelled','overdue')
    and sla_due_at < now()
    and (metadata->>'sla_breached' is null or metadata->>'sla_breached' = 'false')
    returning org_id, site_id, id, title, assigned_to
  ),
  inserted as (
    insert into platform.notifications (org_id, site_id, user_id, type, title, body, payload)
    select org_id, site_id, assigned_to, 'sla_breach', 'SLA Breach: ' || title, 'Work order overdue: ' || title, jsonb_build_object('work_order_id', id)
    from breached
    returning 1
  )
  select count(*) into breached_count from breached;

  return breached_count;
end;
$$;

comment on function ops.check_sla_breaches() is '@graphql({"type": "mutation", "name": "checkSlaBreaches"})';

-- Generate PM work orders from templates
create or replace function ops.generate_pm_work_orders()
returns integer
language plpgsql
security definer
set search_path = ops, portfolio, platform, public
as $$
declare
  tmpl record;
  generated integer := 0;
  wo_id uuid;
begin
  for tmpl in
    select * from ops.work_order_templates
    where is_active = true
    and next_due_at <= now()
  loop
    -- Create work order per site if template is site-specific, or for all sites in org if org-wide
    if tmpl.site_id is not null then
      perform ops.create_work_order(
        tmpl.site_id,
        tmpl.name,
        tmpl.description,
        null, null,
        tmpl.priority,
        'preventive',
        tmpl.next_due_at + interval '7 days'
      );
      generated := generated + 1;
    else
      -- Org-wide: create for each active site in org
      for wo_id in select id from portfolio.sites where org_id = tmpl.org_id and status = 'active' loop
        perform ops.create_work_order(
          wo_id,
          tmpl.name,
          tmpl.description,
          null, null,
          tmpl.priority,
          'preventive',
          tmpl.next_due_at + interval '7 days'
        );
        generated := generated + 1;
      end loop;
    end if;

    -- Update next due based on recurrence (simple handling)
    update ops.work_order_templates
    set next_due_at = case
      when recurrence_rule ilike '%daily%' then next_due_at + interval '1 day'
      when recurrence_rule ilike '%weekly%' then next_due_at + interval '1 week'
      when recurrence_rule ilike '%monthly%' then next_due_at + interval '1 month'
      when recurrence_rule ilike '%quarterly%' then next_due_at + interval '3 months'
      when recurrence_rule ilike '%yearly%' or recurrence_rule ilike '%annual%' then next_due_at + interval '1 year'
      else next_due_at + interval '1 month'
    end,
    updated_at = now()
    where id = tmpl.id;
  end loop;

  return generated;
end;
$$;

-- Check COI expirations
create or replace function vendor.check_coi_expirations()
returns integer
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
declare
  updated integer := 0;
begin
  -- Update status to expiring if within 30 days
  with expiring as (
    update vendor.cois
    set status = 'expiring', updated_at = now()
    where expiry_date between current_date and current_date + interval '30 days'
    and status = 'valid'
    returning org_id, site_id, vendor_id, id, type, expiry_date
  ),
  notif as (
    insert into platform.notifications (org_id, site_id, type, title, body, payload)
    select org_id, site_id, 'coi_expiring', 'COI Expiring: ' || type, 'COI expires on ' || expiry_date::text, jsonb_build_object('coi_id', id, 'vendor_id', vendor_id, 'days_left', (expiry_date - current_date))
    from expiring
    returning 1
  )
  select count(*) into updated from expiring;

  -- Update expired
  with expired as (
    update vendor.cois
    set status = 'expired', updated_at = now()
    where expiry_date < current_date
    and status != 'expired'
    returning org_id, site_id, vendor_id, id, type
  ),
  notif2 as (
    insert into platform.notifications (org_id, site_id, type, title, body, payload)
    select org_id, site_id, 'coi_expired', 'COI Expired: ' || type, 'COI expired', jsonb_build_object('coi_id', id, 'vendor_id', vendor_id)
    from expired
    returning 1
  )
  select count(*) into updated from expired;

  -- Update compliance_status per vendor/site based on cois
  insert into vendor.compliance_status (org_id, vendor_id, site_id, status, issues, last_checked)
  select
    c.org_id,
    c.vendor_id,
    c.site_id,
    case when count(*) filter (where co.status = 'expired') > 0 then 'non_compliant'::vendor.compliance_status_type
         when count(*) filter (where co.status = 'expiring') > 0 then 'pending'::vendor.compliance_status_type
         else 'compliant'::vendor.compliance_status_type
    end,
    coalesce(jsonb_agg(jsonb_build_object('type', co.type, 'status', co.status, 'expiry_date', co.expiry_date, 'coi_id', co.id)) filter (where co.status in ('expiring','expired')), '[]'::jsonb),
    now()
  from vendor.cois co
  join vendor.contracts c on co.contract_id = c.id or (co.contract_id is null and co.vendor_id = c.vendor_id)
  group by c.org_id, c.vendor_id, c.site_id
  on conflict (vendor_id, site_id) do update set
    status = excluded.status,
    issues = excluded.issues,
    last_checked = now(),
    updated_at = now();

  return updated;
end;
$$;

-- Daily metrics rollup
create or replace function metrics.rollup_daily_stats(p_date date default current_date - 1)
returns integer
language plpgsql
security definer
set search_path = metrics, portfolio, ops, tenant, visitor, public
as $$
declare
  rec record;
  inserted integer := 0;
begin
  for rec in select id, org_id from portfolio.sites where status = 'active' loop
    insert into metrics.daily_site_stats (org_id, site_id, date, work_orders_open, work_orders_closed, work_orders_overdue, visitor_count, service_requests_count)
    select
      rec.org_id,
      rec.id,
      p_date,
      (select count(*) from ops.work_orders where site_id = rec.id and status in ('open','in_progress','on_hold') and created_at::date <= p_date and (completed_at is null or completed_at::date > p_date)),
      (select count(*) from ops.work_orders where site_id = rec.id and status = 'completed' and completed_at::date = p_date),
      (select count(*) from ops.work_orders where site_id = rec.id and status = 'overdue' and sla_due_at::date = p_date),
      (select count(*) from visitor.visits where site_id = rec.id and scheduled_at::date = p_date),
      (select count(*) from tenant.service_requests where site_id = rec.id and created_at::date = p_date)
    on conflict (site_id, date) do update set
      work_orders_open = excluded.work_orders_open,
      work_orders_closed = excluded.work_orders_closed,
      work_orders_overdue = excluded.work_orders_overdue,
      visitor_count = excluded.visitor_count,
      service_requests_count = excluded.service_requests_count,
      created_at = now();

    inserted := inserted + 1;
  end loop;

  return inserted;
end;
$$;

-----------------------------
-- PG_CRON JOBS (Scheduler)
-----------------------------
-- Note: In Supabase cloud, these need to be run as postgres user or via dashboard cron UI
-- We'll create them here; they will be created when migration runs as postgres
-- For local supabase start, cron is enabled - wrapped in exception handling to not fail migration if cron not available

do $$
begin
  -- Clean existing jobs with same name
  perform cron.unschedule('check-sla-breaches') where exists (select 1 from cron.job where jobname='check-sla-breaches');
  perform cron.unschedule('generate-pm-work-orders') where exists (select 1 from cron.job where jobname='generate-pm-work-orders');
  perform cron.unschedule('check-coi-expiration') where exists (select 1 from cron.job where jobname='check-coi-expiration');
  perform cron.unschedule('rollup-daily-metrics') where exists (select 1 from cron.job where jobname='rollup-daily-metrics');
  perform cron.unschedule('cleanup-expired-visits') where exists (select 1 from cron.job where jobname='cleanup-expired-visits');
  perform cron.unschedule('lease-expiration-check') where exists (select 1 from cron.job where jobname='lease-expiration-check');
exception when others then 
  raise notice 'cron.unschedule failed - cron extension may not be installed or not postgres role, skipping';
end $$;

-- SLA every 15 minutes
do $$ begin
  perform cron.schedule(
    'check-sla-breaches',
    '*/15 * * * *',
    $$ select ops.check_sla_breaches(); $$
  );
exception when others then raise notice 'cron.schedule check-sla-breaches failed: %', SQLERRM;
end $$;

-- PM work orders daily 2am
do $$ begin
  perform cron.schedule(
    'generate-pm-work-orders',
    '0 2 * * *',
    $$ select ops.generate_pm_work_orders(); $$
  );
exception when others then raise notice 'cron.schedule generate-pm-work-orders failed: %', SQLERRM;
end $$;

-- COI expiration hourly 8am-6pm
do $$ begin
  perform cron.schedule(
    'check-coi-expiration',
    '0 8-18 * * *',
    $$ select vendor.check_coi_expirations(); $$
  );
exception when others then raise notice 'cron.schedule check-coi-expiration failed: %', SQLERRM;
end $$;

-- Daily metrics 3am
do $$ begin
  perform cron.schedule(
    'rollup-daily-metrics',
    '0 3 * * *',
    $$ select metrics.rollup_daily_stats(current_date - 1); $$
  );
exception when others then raise notice 'cron.schedule rollup-daily-metrics failed: %', SQLERRM;
end $$;

-- Cleanup expired visits daily 4am
do $$ begin
  perform cron.schedule(
    'cleanup-expired-visits',
    '0 4 * * *',
    $$
    delete from visitor.visits where status = 'checked_out' and checked_out_at < now() - interval '90 days';
    delete from platform.notifications where created_at < now() - interval '90 days' and is_read = true;
    $$
  );
exception when others then raise notice 'cron.schedule cleanup-expired-visits failed: %', SQLERRM;
end $$;

-- Lease expiration weekly Monday 9am
do $$ begin
  perform cron.schedule(
    'lease-expiration-check',
    '0 9 * * 1',
    $$
    insert into platform.notifications (org_id, site_id, type, title, body, payload)
    select org_id, site_id, 'lease_expiring', 'Lease expiring: ' || coalesce((select name from portfolio.spaces where id = space_id), 'space'), 'Lease ends ' || end_date::text, jsonb_build_object('lease_id', id, 'space_id', space_id, 'days_left', (end_date - current_date))
    from portfolio.leases
    where status = 'active' and end_date between current_date and current_date + interval '30 days';
    $$
  );
exception when others then raise notice 'cron.schedule lease-expiration-check failed: %', SQLERRM;
end $$;

-- Grant cron usage - safe with exception
do $$ begin
  execute 'grant usage on schema cron to postgres';
exception when others then raise notice 'grant on schema cron failed - may not exist yet';
end $$;
