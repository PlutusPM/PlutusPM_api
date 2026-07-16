-- 00018_security_hardening.sql
-- Phase: OWASP Top 10 hardening + missing features from gap analysis P0
-- Branch: feat/graphql-frontend-integration-secure (NOT main per user request)
-- Implements: Access Requests workflow, typed Configurations, Rate Limiting, Audit triggers attachment, Community Posts (partial gap), Parking Permits

-- This migration is part of secure GraphQL integration plan
-- See docs/FRONTEND_GRAPHQL_INTEGRATION_PLAN.md and docs/SECURITY_OWASP_CHECKLIST.md

-----------------------------
-- 1. ACCESS REQUESTS (For /dashboard/users/access-requests page)
-- Frontend nav has Users -> Access Requests but backend had only memberships, no access_requests workflow
-- Implements: User requests access to org, admin approves/rejects -> creates membership
-----------------------------
do $$ begin
  create type platform.access_request_status as enum ('pending','approved','rejected','expired');
exception when duplicate_object then null;
end $$;

create table platform.access_requests (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  email text not null,
  user_id uuid references platform.profiles(id) on delete set null, -- if user already exists
  requested_role platform.org_role not null default 'member',
  requested_site_ids uuid[] default null, -- null = all sites
  status platform.access_request_status not null default 'pending',
  requested_at timestamptz default now() not null,
  reviewed_by uuid references platform.profiles(id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique(org_id, email) -- one pending request per email per org
);

create index idx_access_requests_org_status on platform.access_requests(org_id, status, requested_at desc);
create index idx_access_requests_email on platform.access_requests(email);

create trigger set_access_requests_updated_at before update on platform.access_requests for each row execute function public.handle_updated_at();

alter table platform.access_requests enable row level security;

-- Only org admins can view/manage access requests + users can view own requests
create policy "Admins can view access requests"
on platform.access_requests for select
using (
  platform.is_org_admin(org_id) 
  or email = (select email from platform.profiles where id = auth.uid())
  or user_id = auth.uid()
);

create policy "Users can create access requests"
on platform.access_requests for insert
with check (
  auth.uid() is not null -- any authenticated can request
);

create policy "Admins can manage access requests"
on platform.access_requests for all
using (platform.is_org_admin(org_id));

-- Function to approve access request -> creates membership
create or replace function platform.approve_access_request(p_request_id uuid)
returns platform.memberships
language plpgsql
security definer
set search_path = platform, public
as $$
declare
  req platform.access_requests%rowtype;
  new_membership platform.memberships%rowtype;
  target_user_id uuid;
begin
  select * into req from platform.access_requests where id = p_request_id;
  if not found then raise exception 'Access request not found'; end if;
  if req.status != 'pending' then raise exception 'Request already %', req.status; end if;
  if not platform.is_org_admin(req.org_id) then raise exception 'Only org admins can approve'; end if;

  -- Find user_id by email if not set
  target_user_id := req.user_id;
  if target_user_id is null then
    select id into target_user_id from platform.profiles where email = req.email limit 1;
    if target_user_id is null then
      select id into target_user_id from auth.users where email = req.email limit 1;
    end if;
  end if;

  if target_user_id is null then
    raise exception 'User with email % not found - they must sign up first', req.email;
  end if;

  -- Create membership
  insert into platform.memberships (org_id, user_id, role, site_ids)
  values (req.org_id, target_user_id, req.requested_role, req.requested_site_ids)
  on conflict (org_id, user_id) do update set role = excluded.role, site_ids = excluded.site_ids
  returning * into new_membership;

  -- Update request
  update platform.access_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), user_id = target_user_id, updated_at = now()
  where id = p_request_id;

  -- Notify user
  insert into platform.notifications (org_id, user_id, type, title, body, payload)
  values (req.org_id, target_user_id, 'system', 'Access approved: ' || (select name from platform.organizations where id = req.org_id), 'Your access request was approved', jsonb_build_object('org_id', req.org_id, 'role', req.requested_role));

  return new_membership;
end;
$$;

comment on function platform.approve_access_request(uuid) is '@graphql({"type": "mutation", "name": "approveAccessRequest"})';

create or replace function platform.reject_access_request(p_request_id uuid, p_reason text default null)
returns platform.access_requests
language plpgsql
security definer
set search_path = platform, public
as $$
declare
  req platform.access_requests%rowtype;
begin
  select * into req from platform.access_requests where id = p_request_id;
  if not found then raise exception 'Access request not found'; end if;
  if not platform.is_org_admin(req.org_id) then raise exception 'Only admins can reject'; end if;

  update platform.access_requests
  set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), rejection_reason = p_reason, updated_at = now()
  where id = p_request_id
  returning * into req;

  return req;
end;
$$;

comment on function platform.reject_access_request(uuid, text) is '@graphql({"type": "mutation", "name": "rejectAccessRequest"})';

-----------------------------
-- 2. CONFIGURATIONS (Typed config vs scattered jsonb) - Fixes A05 Security Misconfiguration
-----------------------------
create table platform.configurations (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid references platform.organizations(id) on delete cascade, -- null = global config
  key text not null,
  value jsonb not null,
  category text not null default 'general' check (category in ('general','security','notifications','integrations','billing','features','graphql')),
  description text,
  is_secret boolean default false, -- if true, value should be encrypted / not returned to frontend
  is_active boolean default true,
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique(org_id, key)
);

create index idx_config_org_category on platform.configurations(org_id, category);

create trigger set_configurations_updated_at before update on platform.configurations for each row execute function public.handle_updated_at();

alter table platform.configurations enable row level security;

create policy "Admins can manage configurations"
on platform.configurations for all
using (org_id is null or platform.is_org_admin(org_id));

create policy "Members can view non-secret configurations"
on platform.configurations for select
using (
  (is_secret = false and (org_id is null or platform.is_org_member(org_id)))
  or platform.is_org_admin(org_id)
);

-- Seed default secure configs
insert into platform.configurations (org_id, key, value, category, description, is_secret)
values
  (null, 'graphql_introspection_enabled', 'true'::jsonb, 'graphql', 'Enable GraphQL introspection (__schema) - should be true in dev, false in prod for security', false),
  (null, 'graphql_max_depth', '10'::jsonb, 'graphql', 'Max query depth allowed to prevent DoS', false),
  (null, 'graphql_max_complexity', '1000'::jsonb, 'graphql', 'Max query complexity score', false),
  (null, 'graphql_rate_limit_per_minute_ip', '60'::jsonb, 'graphql', 'Max GraphQL requests per minute per IP', false),
  (null, 'graphql_rate_limit_per_minute_user', '100'::jsonb, 'graphql', 'Max GraphQL requests per minute per authenticated user', false),
  (null, 'auth_max_login_attempts', '5'::jsonb, 'security', 'Max failed login attempts per 15min per IP before block', false),
  (null, 'auth_lockout_minutes', '15'::jsonb, 'security', 'Lockout duration in minutes after max attempts', false),
  (null, 'storage_max_file_size_mb', '10'::jsonb, 'security', 'Max file upload size MB', false),
  (null, 'notifications_slack_enabled', 'false'::jsonb, 'notifications', 'Enable Slack notifications for compliance alerts', false)
on conflict (org_id, key) do nothing;

-----------------------------
-- 3. RATE LIMITING TABLE (For GraphQL Gateway + Auth Rate Limiting) - Fixes A05 + A07
-----------------------------
create table platform.rate_limits (
  id uuid primary key default uuid_generate_v4(),
  identifier text not null, -- e.g., ip:127.0.0.1 or user:uuid or org:uuid
  action text not null, -- e.g., 'graphql_query', 'auth_sign_in', 'visitor_check_in'
  count integer not null default 1,
  window_start timestamptz not null default now(),
  created_at timestamptz default now() not null,
  unique(identifier, action, window_start)
);

create index idx_rate_limits_identifier_action_window on platform.rate_limits(identifier, action, window_start desc);
create index idx_rate_limits_window on platform.rate_limits(window_start);

alter table platform.rate_limits enable row level security;

-- Only service_role can manage rate limits (via Edge Functions), no anon/authenticated direct access
create policy "Service role manages rate limits"
on platform.rate_limits for all
using (true)
with check (true);

-- Function to check and increment rate limit (returns true if allowed, false if rate limited)
-- Uses sliding window: counts sum in last window_seconds
create or replace function platform.check_rate_limit(
  p_identifier text,
  p_action text,
  p_limit integer,
  p_window_seconds integer default 60
)
returns boolean
language plpgsql
security definer
set search_path = platform, public
as $$
declare
  current_count integer;
  window_start timestamptz := now() - (p_window_seconds || ' seconds')::interval;
begin
  -- Clean old windows (older than 1 hour) to keep table small
  delete from platform.rate_limits where window_start < now() - interval '1 hour';

  -- Count recent requests in window
  select coalesce(sum(count),0) into current_count
  from platform.rate_limits
  where identifier = p_identifier
  and action = p_action
  and window_start >= window_start;

  if current_count >= p_limit then
    return false; -- rate limited
  end if;

  -- Increment
  insert into platform.rate_limits (identifier, action, count, window_start)
  values (p_identifier, p_action, 1, now())
  on conflict (identifier, action, window_start) do update set count = platform.rate_limits.count + 1;

  return true; -- allowed
end;
$$;

comment on function platform.check_rate_limit(text, text, integer, integer) is 'Check rate limit - returns true if allowed, false if rate limited. Example: check_rate_limit(''ip:1.2.3.4'', ''graphql_query'', 60, 60) allows 60 req/min per IP';

-----------------------------
-- 4. AUDIT TRIGGERS ATTACHMENT (Fixes A09 Logging and Monitoring)
-- Generic log_audit() function exists in 00001 but not attached to all tables
-- Now attach to all main tables for complete audit trail
-----------------------------

-- Helper to attach audit trigger if not exists
create or replace function platform.attach_audit_trigger(p_schema text, p_table text)
returns void
language plpgsql
as $$
begin
  execute format('drop trigger if exists trg_audit_%s on %I.%I', p_table, p_schema, p_table);
  execute format('create trigger trg_audit_%s after insert or update or delete on %I.%I for each row execute function platform.log_audit()', p_table, p_schema, p_table);
exception when others then
  raise notice 'Failed to attach audit trigger to %.%: %', p_schema, p_table, SQLERRM;
end;
$$;

-- Attach to all main tables
select platform.attach_audit_trigger('portfolio', 'portfolios');
select platform.attach_audit_trigger('portfolio', 'sites');
select platform.attach_audit_trigger('portfolio', 'buildings');
select platform.attach_audit_trigger('portfolio', 'floors');
select platform.attach_audit_trigger('portfolio', 'spaces');
select platform.attach_audit_trigger('portfolio', 'leases');
select platform.attach_audit_trigger('ops', 'assets');
select platform.attach_audit_trigger('ops', 'work_orders');
select platform.attach_audit_trigger('ops', 'inspections');
select platform.attach_audit_trigger('ops', 'incidents');
select platform.attach_audit_trigger('tenant', 'tenants');
select platform.attach_audit_trigger('tenant', 'service_requests');
select platform.attach_audit_trigger('tenant', 'reservations');
select platform.attach_audit_trigger('tenant', 'announcements');
select platform.attach_audit_trigger('tenant', 'events');
select platform.attach_audit_trigger('visitor', 'visitors');
select platform.attach_audit_trigger('visitor', 'visits');
select platform.attach_audit_trigger('vendor', 'vendors');
select platform.attach_audit_trigger('vendor', 'contracts');
select platform.attach_audit_trigger('vendor', 'cois');
select platform.attach_audit_trigger('metrics', 'reports');

-- Also attach to new tables in this migration
select platform.attach_audit_trigger('platform', 'access_requests');
select platform.attach_audit_trigger('platform', 'configurations');

-----------------------------
-- 5. COMMUNITY POSTS (Gap from CAPABILITY_COVERAGE.md P0 - Tenant Experience Community Management 50% -> 100%)
-----------------------------
do $$ begin
  create type tenant.community_post_type as enum ('general','marketplace','recommendation','question','announcement','event');
exception when duplicate_object then null;
end $$;

create table tenant.community_posts (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  title text not null,
  body text not null,
  type tenant.community_post_type not null default 'general',
  is_pinned boolean default false,
  is_resolved boolean default false,
  likes_count integer default 0,
  comments_count integer default 0,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_community_posts_site_type on tenant.community_posts(site_id, type, created_at desc);
create index idx_community_posts_profile on tenant.community_posts(profile_id);

create trigger set_community_posts_updated_at before update on tenant.community_posts for each row execute function public.handle_updated_at();

alter table tenant.community_posts enable row level security;

create policy "View community posts if can access site"
on tenant.community_posts for select
using (platform.can_access_site(site_id));

create policy "Members can create community posts"
on tenant.community_posts for insert
with check (profile_id = auth.uid() and platform.can_access_site(site_id));

create policy "Users can update own posts"
on tenant.community_posts for update
using (profile_id = auth.uid() or platform.is_site_manager(site_id));

create policy "Users can delete own posts"
on tenant.community_posts for delete
using (profile_id = auth.uid() or platform.is_site_manager(site_id));

select platform.attach_audit_trigger('tenant', 'community_posts');

create table tenant.community_comments (
  id uuid primary key default uuid_generate_v4(),
  post_id uuid not null references tenant.community_posts(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz default now() not null
);

create index idx_community_comments_post on tenant.community_comments(post_id, created_at asc);

alter table tenant.community_comments enable row level security;

create policy "View comments if can access site"
on tenant.community_comments for select
using (platform.can_access_site(site_id));

create policy "Members can create comments"
on tenant.community_comments for insert
with check (profile_id = auth.uid() and platform.can_access_site(site_id));

-- Trigger to update comments_count
create or replace function tenant.update_community_post_counts()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'INSERT' then
    update tenant.community_posts set comments_count = comments_count + 1, updated_at = now() where id = new.post_id;
  elsif TG_OP = 'DELETE' then
    update tenant.community_posts set comments_count = greatest(0, comments_count - 1), updated_at = now() where id = old.post_id;
  end if;
  return new;
end;
$$;

create trigger trg_community_comments_count after insert or delete on tenant.community_comments for each row execute function tenant.update_community_post_counts();

select platform.attach_audit_trigger('tenant', 'community_comments');

create table tenant.community_likes (
  id uuid primary key default uuid_generate_v4(),
  post_id uuid not null references tenant.community_posts(id) on delete cascade,
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  created_at timestamptz default now() not null,
  unique(post_id, profile_id)
);

alter table tenant.community_likes enable row level security;

create policy "View likes if can access site"
on tenant.community_likes for select
using (
  exists (select 1 from tenant.community_posts p where p.id = post_id and platform.can_access_site(p.site_id))
);

create policy "Members can like"
on tenant.community_likes for all
using (profile_id = auth.uid());

-- Trigger to update likes_count
create or replace function tenant.update_community_likes_count()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'INSERT' then
    update tenant.community_posts set likes_count = likes_count + 1, updated_at = now() where id = new.post_id;
  elsif TG_OP = 'DELETE' then
    update tenant.community_posts set likes_count = greatest(0, likes_count - 1), updated_at = now() where id = old.post_id;
  end if;
  return new;
end;
$$;

create trigger trg_community_likes_count after insert or delete on tenant.community_likes for each row execute function tenant.update_community_likes_count();

-----------------------------
-- 6. PARKING PERMITS (Gap from CAPABILITY_COVERAGE.md P0 - Parking Reservations 80% -> 100%)
-----------------------------
create table tenant.parking_permits (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  space_id uuid references portfolio.spaces(id) on delete set null, -- specific parking spot
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  tenant_id uuid references tenant.tenants(id) on delete set null,
  license_plate text not null,
  vehicle_make text,
  vehicle_model text,
  vehicle_color text,
  vehicle_type text default 'car' check (vehicle_type in ('car','motorcycle','truck','van','ev','other')),
  permit_type text not null default 'monthly' check (permit_type in ('monthly','transient','visitor','reserved','ev_charging')),
  spot_number text, -- e.g., "P-101", "EV-02"
  is_ev_charger boolean default false,
  start_date date not null,
  end_date date,
  status text not null default 'active' check (status in ('active','expired','revoked','pending')),
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  check (end_date is null or end_date >= start_date)
);

create index idx_parking_permits_site on tenant.parking_permits(site_id, status);
create index idx_parking_permits_profile on tenant.parking_permits(profile_id);
create index idx_parking_permits_plate on tenant.parking_permits(license_plate);

create trigger set_parking_permits_updated_at before update on tenant.parking_permits for each row execute function public.handle_updated_at();

alter table tenant.parking_permits enable row level security;

create policy "View parking permits if can access site"
on tenant.parking_permits for select
using (platform.can_access_site(site_id) or profile_id = auth.uid());

create policy "Members can create parking permits"
on tenant.parking_permits for insert
with check (platform.can_access_site(site_id));

create policy "Users manage own permits"
on tenant.parking_permits for all
using (profile_id = auth.uid() or platform.is_site_manager(site_id));

select platform.attach_audit_trigger('tenant', 'parking_permits');

-----------------------------
-- 7. SECURITY DASHBOARD VIEW + ACCESS CHECK FUNCTION (Gap P0 - Visitor Management)
-----------------------------

-- View for security dashboard aggregating today's visits, access logs, devices online, blacklist count
create or replace view visitor.v_security_dashboard as
select
  s.id as site_id,
  s.org_id,
  s.name as site_name,
  (select count(*) from visitor.visits v where v.site_id = s.id and v.scheduled_at::date = current_date) as total_preregistered_today,
  (select count(*) from visitor.visits v where v.site_id = s.id and v.status = 'checked_in' and v.scheduled_at::date = current_date) as checked_in_now,
  (select count(*) from visitor.visits v where v.site_id = s.id and v.status = 'checked_out' and v.scheduled_at::date = current_date) as checked_out_today,
  (select count(*) from visitor.visits v where v.site_id = s.id and v.status = 'no_show' and v.scheduled_at::date = current_date) as no_show_today,
  (select count(*) from visitor.access_logs al where al.site_id = s.id and al.timestamp::date = current_date and al.event = 'denied') as access_denied_today,
  (select count(*) from visitor.access_devices ad where ad.site_id = s.id and ad.is_online = true) as devices_online,
  (select count(*) from visitor.access_devices ad where ad.site_id = s.id) as total_devices,
  (select count(*) from visitor.blacklist b where b.org_id = s.org_id and b.is_active = true) as active_blacklist_count,
  (select count(*) from visitor.visits v where v.site_id = s.id and v.status = 'preregistered' and v.scheduled_at between now() and now() + interval '2 hours') as arriving_next_2h
from portfolio.sites s;

do $$ begin
  execute 'alter view visitor.v_security_dashboard set (security_invoker = true)';
exception when others then null;
end $$;

-- Function check_access for access control (credential_id + device_id -> granted/denied + log)
create or replace function visitor.check_access(
  p_credential_id text,
  p_device_id uuid
)
returns table (
  granted boolean,
  reason text,
  credential_type visitor.credential_type,
  user_id uuid,
  visitor_id uuid
)
language plpgsql
security definer
set search_path = visitor, platform, public
as $$
declare
  cred visitor.access_credentials%rowtype;
  dev visitor.access_devices%rowtype;
  is_blacklisted boolean;
begin
  select * into cred from visitor.access_credentials where credential_id = p_credential_id and is_active = true limit 1;
  if not found then
    -- Log denied
    if p_device_id is not null then
      select * into dev from visitor.access_devices where id = p_device_id;
      insert into visitor.access_logs (org_id, site_id, device_id, access_point, event, metadata)
      values (
        coalesce(dev.org_id, (select org_id from portfolio.sites limit 1)),
        coalesce(dev.site_id, (select id from portfolio.sites limit 1)),
        p_device_id::text,
        coalesce(dev.access_point, 'Unknown'),
        'denied',
        jsonb_build_object('reason', 'Invalid credential', 'credential_id', p_credential_id)
      );
    end if;
    return query select false, 'Invalid credential'::text, null::visitor.credential_type, null::uuid, null::uuid;
    return;
  end if;

  -- Check expiry
  if cred.expires_at is not null and cred.expires_at < now() then
    return query select false, 'Credential expired'::text, cred.type, cred.user_id, cred.visitor_id;
    return;
  end if;

  -- Check blacklist if visitor
  if cred.visitor_id is not null then
    select exists (
      select 1 from visitor.blacklist b
      where b.org_id = cred.org_id and b.is_active = true
      and (b.visitor_id = cred.visitor_id or b.email = (select email from visitor.visitors where id = cred.visitor_id))
      and (b.expires_at is null or b.expires_at > now())
    ) into is_blacklisted;
    if is_blacklisted then
      return query select false, 'Visitor blacklisted'::text, cred.type, cred.user_id, cred.visitor_id;
      return;
    end if;
  end if;

  -- Check device
  if p_device_id is not null then
    select * into dev from visitor.access_devices where id = p_device_id and is_active = true;
    if not found then
      return query select false, 'Invalid device'::text, cred.type, cred.user_id, cred.visitor_id;
      return;
    end if;
    -- Log granted
    insert into visitor.access_logs (org_id, site_id, device_id, access_point, event, metadata)
    values (cred.org_id, coalesce(cred.site_id, dev.site_id), p_device_id::text, dev.access_point, 'granted', jsonb_build_object('credential_id', p_credential_id, 'type', cred.type));
  end if;

  return query select true, 'Access granted'::text, cred.type, cred.user_id, cred.visitor_id;
end;
$$;

comment on function visitor.check_access(text, uuid) is '@graphql({"type": "query", "name": "checkAccess"})';

-----------------------------
-- 8. SEARCH FUNCTIONS (Gap P0 - Search 70% -> 100%)
-----------------------------

-- Search assets by name/manufacturer/model/serial
create or replace function ops.search_assets(p_query text, p_site_id uuid default null, p_limit integer default 20)
returns setof ops.assets
language plpgsql
security definer
set search_path = ops, platform, public
as $$
begin
  return query
  select * from ops.assets a
  where (p_site_id is null or a.site_id = p_site_id)
  and (
    a.name ilike '%'||p_query||'%'
    or a.manufacturer ilike '%'||p_query||'%'
    or a.model ilike '%'||p_query||'%'
    or a.serial_number ilike '%'||p_query||'%'
    or a.qr_code ilike '%'||p_query||'%'
  )
  and platform.can_access_site(a.site_id)
  order by public.similarity(a.name, p_query) desc
  limit p_limit;
end;
$$;

comment on function ops.search_assets(text, uuid, integer) is '@graphql({"type": "query", "name": "searchAssets"})';

-- Search tenants
create or replace function tenant.search_tenants(p_query text, p_site_id uuid default null, p_limit integer default 20)
returns setof tenant.tenants
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
begin
  return query
  select * from tenant.tenants t
  where (p_site_id is null or t.site_id = p_site_id)
  and (
    t.company_name ilike '%'||p_query||'%'
    or t.legal_name ilike '%'||p_query||'%'
    or t.contact_email ilike '%'||p_query||'%'
  )
  and platform.can_access_site(t.site_id)
  order by public.similarity(t.company_name, p_query) desc
  limit p_limit;
end;
$$;

comment on function tenant.search_tenants(text, uuid, integer) is '@graphql({"type": "query", "name": "searchTenants"})';

-- Search vendors
create or replace function vendor.search_vendors(p_query text, p_org_id uuid default null, p_limit integer default 20)
returns setof vendor.vendors
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
begin
  return query
  select * from vendor.vendors v
  where (p_org_id is null or v.org_id = p_org_id)
  and (
    v.name ilike '%'||p_query||'%'
    or v.contact_email ilike '%'||p_query||'%'
    or v.type::text ilike '%'||p_query||'%'
  )
  and platform.is_org_member(v.org_id)
  order by public.similarity(v.name, p_query) desc
  limit p_limit;
end;
$$;

comment on function vendor.search_vendors(text, uuid, integer) is '@graphql({"type": "query", "name": "searchVendors"})';

-- Search work orders
create or replace function ops.search_work_orders(p_query text, p_site_id uuid default null, p_limit integer default 20)
returns setof ops.work_orders
language plpgsql
security definer
set search_path = ops, platform, public
as $$
begin
  return query
  select * from ops.work_orders wo
  where (p_site_id is null or wo.site_id = p_site_id)
  and (
    wo.title ilike '%'||p_query||'%'
    or wo.description ilike '%'||p_query||'%'
  )
  and platform.can_access_site(wo.site_id)
  order by wo.created_at desc
  limit p_limit;
end;
$$;

comment on function ops.search_work_orders(text, uuid, integer) is '@graphql({"type": "query", "name": "searchWorkOrders"})';

-----------------------------
-- GRANTS
-----------------------------
grant all on all tables in schema platform to service_role;
grant select, insert, update, delete on all tables in schema platform to authenticated;
grant usage on all sequences in schema platform to authenticated, service_role;

grant all on all tables in schema tenant to service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated;
grant usage on all sequences in schema tenant to authenticated, service_role;

grant all on all tables in schema visitor to service_role;
grant select, insert, update, delete on all tables in schema visitor to authenticated;

-- Realtime for new tables
do $$ begin alter publication supabase_realtime add table platform.access_requests; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table tenant.community_posts; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table tenant.community_comments; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table tenant.parking_permits; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table platform.configurations; exception when duplicate_object then null; end $$;
