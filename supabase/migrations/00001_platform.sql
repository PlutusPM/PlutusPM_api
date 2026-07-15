-- 00001_platform.sql
-- Shared platform services: organizations, profiles, memberships, RBAC, audit logs, notifications
-- This is the foundation - everything depends on platform

-- Enable RLS tracking
-- Ensure profiles auto-created on auth.users insert

-----------------------------
-- ROLES ENUM
-----------------------------
do $$ begin
  create type platform.org_role as enum (
    'owner',
    'admin',
    'portfolio_manager',
    'site_manager',
    'building_engineer',
    'security',
    'tenant_admin',
    'tenant_user',
    'vendor',
    'auditor'
  );
exception when duplicate_object then null;
end $$;

-----------------------------
-- ORGANIZATIONS (SaaS tenant)
-----------------------------
create table platform.organizations (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  slug text unique not null check (slug ~ '^[a-z0-9-]+$'),
  owner_id uuid references auth.users(id) on delete set null,
  billing_tier text default 'starter' check (billing_tier in ('starter','growth','enterprise')),
  settings jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create trigger set_platform_orgs_updated_at
  before update on platform.organizations
  for each row execute function public.handle_updated_at();

alter table platform.organizations enable row level security;

-----------------------------
-- PROFILES (extends auth.users)
-----------------------------
create table platform.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  avatar_url text,
  phone text,
  is_super_admin boolean default false,
  preferences jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create trigger set_profiles_updated_at
  before update on platform.profiles
  for each row execute function public.handle_updated_at();

alter table platform.profiles enable row level security;

-- Auto-create profile on signup
create or replace function platform.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = platform, public, auth
as $$
begin
  insert into platform.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url'
  ) on conflict (id) do update set
    email = excluded.email,
    full_name = coalesce(excluded.full_name, platform.profiles.full_name),
    avatar_url = coalesce(excluded.avatar_url, platform.profiles.avatar_url);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function platform.handle_new_user();

-----------------------------
-- MEMBERSHIPS (RBAC per org, with optional site filter)
-----------------------------
create table platform.memberships (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  user_id uuid not null references platform.profiles(id) on delete cascade,
  role platform.org_role not null default 'site_manager',
  portfolio_ids uuid[] default null, -- null = all portfolios in org
  site_ids uuid[] default null,      -- null = all sites in allowed portfolios
  created_at timestamptz default now() not null,
  created_by uuid references platform.profiles(id),
  unique(org_id, user_id)
);

-- Index for fast site membership checks
create index idx_memberships_user on platform.memberships(user_id);
create index idx_memberships_org on platform.memberships(org_id);
create index idx_memberships_user_org on platform.memberships(user_id, org_id);

alter table platform.memberships enable row level security;

-----------------------------
-- AUDIT LOGS
-----------------------------
create table platform.audit_logs (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid references platform.organizations(id) on delete set null,
  site_id uuid, -- generic uuid, FK added later via portfolio.sites to avoid circular dep
  user_id uuid references platform.profiles(id) on delete set null,
  action text not null check (action in ('create','update','delete','login','export','import')),
  entity text not null, -- e.g., 'work_order', 'site', 'contract'
  entity_id uuid,
  diff jsonb, -- {old: {}, new: {}}
  ip_address inet,
  user_agent text,
  created_at timestamptz default now() not null
);

create index idx_audit_org_time on platform.audit_logs(org_id, created_at desc);
create index idx_audit_site_time on platform.audit_logs(site_id, created_at desc);
create index idx_audit_entity on platform.audit_logs(entity, entity_id);

alter table platform.audit_logs enable row level security;

-----------------------------
-- NOTIFICATIONS
-----------------------------
create table platform.notifications (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid, -- nullable for org-wide notifications
  user_id uuid references platform.profiles(id) on delete cascade, -- null = broadcast to site members
  type text not null check (type in (
    'sla_breach', 'coi_expiring', 'coi_expired', 'work_order_assigned', 
    'service_request_created', 'visitor_arrived', 'lease_expiring', 
    'compliance_issue', 'system', 'report_ready', 'reservation_reminder'
  )),
  title text not null,
  body text,
  payload jsonb default '{}'::jsonb,
  is_read boolean default false not null,
  read_at timestamptz,
  created_at timestamptz default now() not null
);

create index idx_notifications_user_read on platform.notifications(user_id, is_read, created_at desc);
create index idx_notifications_site on platform.notifications(site_id, created_at desc);
create index idx_notifications_org on platform.notifications(org_id, created_at desc);

alter table platform.notifications enable row level security;

-----------------------------
-- HELPER FUNCTIONS (SECURITY DEFINER, core of RLS)
-----------------------------

-- Current user's org ids
create or replace function platform.current_org_ids()
returns uuid[]
language sql
security definer
set search_path = platform, public
as $$
  select array_agg(org_id) from platform.memberships where user_id = auth.uid();
$$;

-- Current user's allowed site ids across all orgs (null means all? handled in can_access)
-- Returns all site_ids where membership allows. If user has membership with site_ids NULL, we return null meaning "all"
create or replace function platform.current_allowed_site_ids()
returns uuid[]
language sql
security definer
set search_path = platform, public
as $$
  select case 
    when exists (select 1 from platform.memberships where user_id = auth.uid() and site_ids is null) then null
    else (select array_agg(distinct site_id) from (
      select unnest(site_ids) as site_id from platform.memberships where user_id = auth.uid() and site_ids is not null
    ) s)
  end;
$$;

-- Is super admin?
create or replace function platform.is_super_admin()
returns boolean
language sql
security definer
set search_path = platform, public
as $$
  select exists (select 1 from platform.profiles where id = auth.uid() and is_super_admin = true);
$$;

-- Is org member?
create or replace function platform.is_org_member(p_org_id uuid)
returns boolean
language sql
security definer
set search_path = platform, public
as $$
  select exists (
    select 1 from platform.memberships 
    where org_id = p_org_id and user_id = auth.uid()
  ) or platform.is_super_admin();
$$;

-- Is org admin?
create or replace function platform.is_org_admin(p_org_id uuid)
returns boolean
language sql
security definer
set search_path = platform, public
as $$
  select exists (
    select 1 from platform.memberships
    where org_id = p_org_id and user_id = auth.uid() and role in ('owner','admin')
  ) or platform.is_super_admin();
$$;

-- Can access site? Core function used in every RLS policy
create or replace function platform.can_access_site(p_site_id uuid)
returns boolean
language plpgsql
security definer
set search_path = platform, portfolio, public
as $$
declare
  v_org_id uuid;
  v_membership platform.memberships%rowtype;
begin
  if p_site_id is null then return false; end if;
  if platform.is_super_admin() then return true; end if;

  -- Get org of site (portfolio.sites may not exist yet during migration, handle gracefully)
  begin
    select org_id into v_org_id from portfolio.sites where id = p_site_id;
  exception when undefined_table then
    -- During platform migration, portfolio.sites doesn't exist, fallback to check memberships by site_ids
    return exists (
      select 1 from platform.memberships m
      where m.user_id = auth.uid()
      and (m.site_ids is null or p_site_id = any(m.site_ids))
    );
  end;

  if v_org_id is null then return false; end if;

  -- Check memberships: site_ids null = access all sites in org, or site in allowed list
  return exists (
    select 1 from platform.memberships m
    where m.user_id = auth.uid()
    and m.org_id = v_org_id
    and (m.site_ids is null or p_site_id = any(m.site_ids))
  );
end;
$$;

-- Is site manager/admin for specific site?
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

-- Current org id (first membership)
create or replace function platform.current_org_id()
returns uuid
language sql
security definer
set search_path = platform, public
as $$
  select org_id from platform.memberships where user_id = auth.uid() limit 1;
$$;

-- Generic audit trigger function
create or replace function platform.log_audit()
returns trigger
language plpgsql
security definer set search_path = platform, public
as $$
declare
  v_org_id uuid;
  v_site_id uuid;
  v_user_id uuid := auth.uid();
begin
  -- Try to extract org_id and site_id from NEW or OLD
  begin
    v_org_id := coalesce((to_jsonb(NEW)->>'org_id')::uuid, (to_jsonb(OLD)->>'org_id')::uuid, platform.current_org_id());
  exception when others then v_org_id := platform.current_org_id();
  end;

  begin
    v_site_id := coalesce((to_jsonb(NEW)->>'site_id')::uuid, (to_jsonb(OLD)->>'site_id')::uuid);
  exception when others then v_site_id := null;
  end;

  if TG_OP = 'INSERT' then
    insert into platform.audit_logs (org_id, site_id, user_id, action, entity, entity_id, diff)
    values (v_org_id, v_site_id, v_user_id, 'create', TG_TABLE_NAME, (to_jsonb(NEW)->>'id')::uuid, jsonb_build_object('new', to_jsonb(NEW)));
  elsif TG_OP = 'UPDATE' then
    insert into platform.audit_logs (org_id, site_id, user_id, action, entity, entity_id, diff)
    values (v_org_id, v_site_id, v_user_id, 'update', TG_TABLE_NAME, (to_jsonb(NEW)->>'id')::uuid, jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW)));
  elsif TG_OP = 'DELETE' then
    insert into platform.audit_logs (org_id, site_id, user_id, action, entity, entity_id, diff)
    values (v_org_id, v_site_id, v_user_id, 'delete', TG_TABLE_NAME, (to_jsonb(OLD)->>'id')::uuid, jsonb_build_object('old', to_jsonb(OLD)));
  end if;
  return coalesce(NEW, OLD);
end;
$$;

-----------------------------
-- RLS POLICIES FOR PLATFORM
-----------------------------

-- organizations: can see orgs you belong to
create policy "Users can view their orgs"
on platform.organizations for select
using (platform.is_org_member(id) or platform.is_super_admin());

create policy "Authenticated can create orgs"
on platform.organizations for insert
with check (auth.uid() is not null);

create policy "Admins can update orgs"
on platform.organizations for update
using (platform.is_org_admin(id));

create policy "Owners can delete orgs"
on platform.organizations for delete
using (
  exists (select 1 from platform.memberships where org_id = id and user_id = auth.uid() and role = 'owner')
);

-- profiles: viewable by org members
create policy "Profiles viewable by org members"
on platform.profiles for select
using (
  true -- simplified for MVP: all authenticated can view profiles in same org? We'll tighten later
  -- For now: anyone authenticated can see profiles (needed for assignments)
);

create policy "Users can update own profile"
on platform.profiles for update
using (id = auth.uid());

-- memberships: can view members of same org
create policy "Members can view org memberships"
on platform.memberships for select
using (platform.is_org_member(org_id));

create policy "Admins can manage memberships"
on platform.memberships for all
using (platform.is_org_admin(org_id));

-- audit_logs: org members can view own org logs, if role admin/auditor
create policy "Admins can view audit logs"
on platform.audit_logs for select
using (platform.is_org_member(org_id) and (
  platform.is_org_admin(org_id) or 
  exists (select 1 from platform.memberships where org_id = audit_logs.org_id and user_id = auth.uid() and role in ('auditor','owner','admin'))
));

-- notifications: users can view own notifications + site notifications if they can access site
create policy "Users can view own notifications"
on platform.notifications for select
using (
  user_id = auth.uid() 
  or (user_id is null and site_id is not null and platform.can_access_site(site_id))
  or (user_id is null and org_id = any(platform.current_org_ids()))
);

create policy "Users can update own notifications"
on platform.notifications for update
using (user_id = auth.uid());

-- Needed for GraphQL muts / service_role can insert
create policy "Service role can insert notifications"
on platform.notifications for insert
with check (true);

-----------------------------
-- Custom function for GraphQL: create organization + membership
-----------------------------
create or replace function platform.create_organization(p_name text, p_slug text)
returns platform.organizations
language plpgsql
security definer
set search_path = platform, public
as $$
declare
  new_org platform.organizations;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  if p_slug !~ '^[a-z0-9-]+$' then raise exception 'Slug must be lowercase letters, numbers, hyphens'; end if;

  insert into platform.organizations (name, slug, owner_id)
  values (p_name, p_slug, v_user_id)
  returning * into new_org;

  insert into platform.memberships (org_id, user_id, role, site_ids, portfolio_ids)
  values (new_org.id, v_user_id, 'owner', null, null);

  return new_org;
end;
$$;

comment on function platform.create_organization(text, text) is '@graphql({"type": "mutation", "name": "createOrganization"})';

-- Grant all on platform tables to service_role (bypass RLS) and authenticated for RLS-filtered access
grant all on all tables in schema platform to service_role;
grant all on all sequences in schema platform to service_role;
grant usage, select, insert, update, delete on all tables in schema platform to authenticated;
grant usage on all sequences in schema platform to authenticated;

-- Realtime for notifications, memberships
alter publication supabase_realtime add table platform.notifications;
alter publication supabase_realtime add table platform.memberships;
