-- Vendor portal: vendor identities, assignment state, safe RPCs, and vendor-scoped RLS.
-- This migration deliberately keeps vendor actions behind security-definer functions.

-----------------------------
-- VENDOR IDENTITY
-----------------------------
create table if not exists vendor.vendor_users (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.tenants(id) on delete cascade,
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  user_id uuid references platform.profiles(id) on delete set null,
  email text not null,
  status text not null default 'invited' check (status in ('invited', 'active', 'suspended')),
  invited_at timestamptz not null default now(),
  accepted_at timestamptz,
  last_login_at timestamptz,
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_vendor_users_vendor on vendor.vendor_users(vendor_id);
create index if not exists idx_vendor_users_user on vendor.vendor_users(user_id);
create index if not exists idx_vendor_users_email on vendor.vendor_users(lower(email));
create unique index if not exists idx_vendor_users_active_email
  on vendor.vendor_users(vendor_id, lower(email))
  where status in ('invited', 'active');
create unique index if not exists idx_vendor_users_org_user
  on vendor.vendor_users(org_id, user_id)
  where user_id is not null;

create or replace function vendor.validate_vendor_user()
returns trigger
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
declare
  vendor_org_id uuid;
begin
  new.email := lower(trim(new.email));
  select v.org_id into vendor_org_id from vendor.vendors v where v.id = new.vendor_id;
  if vendor_org_id is null or vendor_org_id <> new.org_id then
    raise exception 'Vendor and organization do not match';
  end if;

  if new.user_id is not null and not exists (
    select 1 from platform.memberships m
    where m.org_id = new.org_id and m.user_id = new.user_id and m.role = 'vendor'
  ) then
    raise exception 'Vendor user must have a vendor membership';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_vendor_user on vendor.vendor_users;
create trigger validate_vendor_user
  before insert or update on vendor.vendor_users
  for each row execute function vendor.validate_vendor_user();

create trigger set_vendor_users_updated_at
  before update on vendor.vendor_users
  for each row execute function public.handle_updated_at();

alter table vendor.vendor_users enable row level security;

-----------------------------
-- VENDOR ASSIGNMENT STATE
-----------------------------
do $$ begin
  create type ops.vendor_assignment_status as enum (
    'unassigned',
    'pending_acceptance',
    'accepted',
    'declined',
    'in_progress',
    'on_hold',
    'completed_pending_review',
    'completed',
    'cancelled'
  );
exception when duplicate_object then null;
end $$;

alter table ops.work_orders
  add column if not exists vendor_assignment_status ops.vendor_assignment_status not null default 'unassigned',
  add column if not exists vendor_assigned_at timestamptz,
  add column if not exists vendor_responded_at timestamptz,
  add column if not exists vendor_decline_reason text,
  add column if not exists vendor_completed_at timestamptz;

update ops.work_orders
set vendor_assignment_status = 'pending_acceptance',
    vendor_assigned_at = coalesce(vendor_assigned_at, created_at)
where vendor_id is not null and vendor_assignment_status = 'unassigned';

create index if not exists idx_wos_vendor_assignment
  on ops.work_orders(vendor_id, vendor_assignment_status, due_date);

create or replace function ops.apply_vendor_assignment_transition()
returns trigger
language plpgsql
security definer
set search_path = ops, vendor, platform, public
as $$
declare
  vendor_org_id uuid;
begin
  if new.vendor_id is null then
    new.vendor_assignment_status := 'unassigned';
    new.vendor_assigned_at := null;
    new.vendor_responded_at := null;
    new.vendor_decline_reason := null;
    new.vendor_completed_at := null;
    return new;
  end if;

  if new.status = 'cancelled' then
    new.vendor_assignment_status := 'cancelled';
    return new;
  end if;

  select v.org_id into vendor_org_id from vendor.vendors v where v.id = new.vendor_id;
  if vendor_org_id is null or vendor_org_id <> new.org_id then
    raise exception 'Vendor and work-order organization do not match';
  end if;

  if tg_op = 'INSERT' or old.vendor_id is distinct from new.vendor_id then
    new.vendor_assignment_status := 'pending_acceptance';
    new.vendor_assigned_at := now();
    new.vendor_responded_at := null;
    new.vendor_decline_reason := null;
    new.vendor_completed_at := null;
  elsif new.vendor_assignment_status is null then
    new.vendor_assignment_status := 'pending_acceptance';
  end if;

  return new;
end;
$$;

drop trigger if exists apply_vendor_assignment_transition on ops.work_orders;
create trigger apply_vendor_assignment_transition
  before insert or update of vendor_id, vendor_assignment_status, status on ops.work_orders
  for each row execute function ops.apply_vendor_assignment_transition();

create or replace function ops.notify_vendor_assignment()
returns trigger
language plpgsql
security definer
set search_path = ops, vendor, platform, public
as $$
declare
  assigned_user_id uuid;
  wrote_notification boolean := false;
begin
  if new.vendor_id is null or (tg_op <> 'INSERT' and old.vendor_id is not distinct from new.vendor_id) then
    return new;
  end if;

  for assigned_user_id in
    select vu.user_id
    from vendor.vendor_users vu
    where vu.vendor_id = new.vendor_id and vu.org_id = new.org_id
      and vu.status = 'active' and vu.user_id is not null
  loop
    insert into platform.notifications (org_id, site_id, user_id, type, title, body, payload)
    values (
      new.org_id,
      new.site_id,
      assigned_user_id,
      'work_order_assigned',
      'New work order assigned',
      new.title,
      jsonb_build_object('work_order_id', new.id, 'vendor_id', new.vendor_id)
    );
    wrote_notification := true;
  end loop;

  if not wrote_notification then
    insert into platform.notifications (org_id, site_id, type, title, body, payload)
    values (
      new.org_id,
      new.site_id,
      'work_order_assigned',
      'Vendor work order assigned',
      new.title,
      jsonb_build_object('work_order_id', new.id, 'vendor_id', new.vendor_id)
    );
  end if;

  return new;
end;
$$;

drop trigger if exists notify_vendor_assignment on ops.work_orders;
create trigger notify_vendor_assignment
  after insert or update of vendor_id on ops.work_orders
  for each row execute function ops.notify_vendor_assignment();

-----------------------------
-- ROLE AND ACCESS HELPERS
-----------------------------
create or replace function platform.is_management_member(p_org_id uuid)
returns boolean
language sql
security definer
set search_path = platform, public
as $$
  select platform.is_super_admin() or exists (
    select 1
    from platform.memberships m
    where m.org_id = p_org_id
      and m.user_id = auth.uid()
      and m.role not in ('vendor', 'tenant_admin', 'tenant_user')
  );
$$;

create or replace function platform.is_vendor_user(p_org_id uuid)
returns boolean
language sql
security definer
set search_path = platform, vendor, public
as $$
  select exists (
    select 1
    from platform.memberships m
    join vendor.vendor_users vu on vu.org_id = m.org_id and vu.user_id = m.user_id
    join vendor.vendors v on v.id = vu.vendor_id and v.org_id = vu.org_id
    where m.org_id = p_org_id
      and m.user_id = auth.uid()
      and m.role = 'vendor'
      and vu.status = 'active'
      and v.status = 'active'
  );
$$;

create or replace function platform.current_vendor_ids()
returns uuid[]
language sql
security definer
set search_path = platform, vendor, public
as $$
  select coalesce(array_agg(vu.vendor_id), array[]::uuid[])
  from vendor.vendor_users vu
  join platform.memberships m on m.org_id = vu.org_id and m.user_id = vu.user_id and m.role = 'vendor'
  join vendor.vendors v on v.id = vu.vendor_id and v.org_id = vu.org_id
  where vu.user_id = auth.uid() and vu.status = 'active' and v.status = 'active';
$$;

create or replace function platform.vendor_can_access_vendor(p_vendor_id uuid)
returns boolean
language sql
security definer
set search_path = platform, vendor, public
as $$
  select p_vendor_id = any(platform.current_vendor_ids());
$$;

create or replace function platform.vendor_can_access_work_order(p_work_order_id uuid)
returns boolean
language sql
security definer
set search_path = platform, ops, public
as $$
  select exists (
    select 1 from ops.work_orders wo
    where wo.id = p_work_order_id
      and wo.vendor_id = any(platform.current_vendor_ids())
  );
$$;

-- Vendors are scoped by assignment, never by site membership.
create or replace function platform.can_access_site(p_site_id uuid)
returns boolean
language plpgsql
security definer
set search_path = platform, portfolio, public
as $$
declare
  site_org_id uuid;
begin
  if p_site_id is null then return false; end if;
  if platform.is_super_admin() then return true; end if;

  select s.org_id into site_org_id from portfolio.sites s where s.id = p_site_id;
  if site_org_id is null then return false; end if;

  return exists (
    select 1
    from platform.memberships m
    where m.user_id = auth.uid()
      and m.org_id = site_org_id
      and m.role <> 'vendor'
      and (m.site_ids is null or p_site_id = any(m.site_ids))
  );
end;
$$;

-- The previous helper compared the column to itself because its local variable had
-- the same name. Keep one deterministic time bucket per identifier/action and use
-- qualified column references for the sliding-window count.
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
  recent_count integer;
  cutoff timestamptz := now() - (greatest(p_window_seconds, 1) || ' seconds')::interval;
  bucket_start timestamptz := to_timestamp(
    floor(extract(epoch from now()) / greatest(p_window_seconds, 1)) * greatest(p_window_seconds, 1)
  );
begin
  delete from platform.rate_limits rl where rl.window_start < now() - interval '1 hour';

  select coalesce(sum(rl.count), 0)
  into recent_count
  from platform.rate_limits rl
  where rl.identifier = p_identifier
    and rl.action = p_action
    and rl.window_start >= cutoff;

  if recent_count >= greatest(p_limit, 0) then return false; end if;

  insert into platform.rate_limits (identifier, action, count, window_start)
  values (p_identifier, p_action, 1, bucket_start)
  on conflict (identifier, action, window_start)
  do update set count = platform.rate_limits.count + 1;
  return true;
end;
$$;

-----------------------------
-- RLS NARROWING
-----------------------------
do $$
declare
  policy_row record;
begin
  for policy_row in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'vendor'
      and tablename = any (array[
        'vendors', 'contracts', 'cois', 'compliance_status', 'vendor_contacts',
        'documents', 'compliance_rules', 'contract_approvals', 'vendor_approvals',
        'notification_rules', 'compliance_audit_logs'
      ])
  loop
    execute format('drop policy if exists %I on %I.%I', policy_row.policyname, policy_row.schemaname, policy_row.tablename);
  end loop;
end;
$$;

create policy "Management users view vendors"
on vendor.vendors for select using (platform.is_management_member(org_id));
create policy "Management users manage vendors"
on vendor.vendors for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view contracts"
on vendor.contracts for select using (platform.is_management_member(org_id));
create policy "Management users manage contracts"
on vendor.contracts for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view cois"
on vendor.cois for select using (platform.is_management_member(org_id));
create policy "Management users manage cois"
on vendor.cois for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view compliance"
on vendor.compliance_status for select using (platform.is_management_member(org_id));
create policy "Management users manage compliance"
on vendor.compliance_status for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view vendor contacts"
on vendor.vendor_contacts for select using (platform.is_management_member(org_id));
create policy "Management users manage vendor contacts"
on vendor.vendor_contacts for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view vendor documents"
on vendor.documents for select using (platform.is_management_member(org_id));
create policy "Management users manage vendor documents"
on vendor.documents for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view compliance rules"
on vendor.compliance_rules for select using (platform.is_management_member(org_id));
create policy "Management users manage compliance rules"
on vendor.compliance_rules for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view contract approvals"
on vendor.contract_approvals for select using (platform.is_management_member(org_id));
create policy "Management users manage contract approvals"
on vendor.contract_approvals for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view vendor approvals"
on vendor.vendor_approvals for select using (platform.is_management_member(org_id));
create policy "Management users manage vendor approvals"
on vendor.vendor_approvals for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view notification rules"
on vendor.notification_rules for select using (platform.is_management_member(org_id));
create policy "Management users manage notification rules"
on vendor.notification_rules for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users view compliance audit"
on vendor.compliance_audit_logs for select using (platform.is_management_member(org_id));
create policy "Management users manage compliance audit"
on vendor.compliance_audit_logs for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Management users manage vendor users"
on vendor.vendor_users for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));
create policy "Vendor users view own identity"
on vendor.vendor_users for select using (user_id = auth.uid());

do $$
declare
  policy_row record;
begin
  for policy_row in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'platform' and tablename in ('profiles', 'memberships', 'notifications')
  loop
    execute format('drop policy if exists %I on %I.%I', policy_row.policyname, policy_row.schemaname, policy_row.tablename);
  end loop;
end;
$$;

create policy "Users view own or management profiles"
on platform.profiles for select
using (id = auth.uid() or exists (
  select 1 from platform.memberships m
  where m.user_id = auth.uid() and platform.is_management_member(m.org_id)
));
create policy "Users update own profile"
on platform.profiles for update using (id = auth.uid()) with check (id = auth.uid());

create policy "Users view own or management memberships"
on platform.memberships for select
using (user_id = auth.uid() or platform.is_management_member(org_id));
create policy "Management users manage memberships"
on platform.memberships for all using (platform.is_management_member(org_id)) with check (platform.is_management_member(org_id));

create policy "Users view own or management notifications"
on platform.notifications for select
using (
  user_id = auth.uid()
  or (user_id is null and platform.is_management_member(org_id)
      and (site_id is null or platform.can_access_site(site_id)))
);
create policy "Users update own notifications"
on platform.notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Service role inserts notifications"
on platform.notifications for insert with check (true);

do $$ begin
  alter view vendor.v_compliance_dashboard set (security_invoker = true);
exception when undefined_table then null;
end $$;
do $$ begin
  alter view vendor.v_compliance_dashboard_summary set (security_invoker = true);
exception when undefined_table then null;
end $$;

-----------------------------
-- WORK ORDER, COMMENT, AND ATTACHMENT RLS
-----------------------------
drop policy if exists "View WOs if can access site" on ops.work_orders;
drop policy if exists "Members can create WOs" on ops.work_orders;
drop policy if exists "Members can update WOs" on ops.work_orders;
drop policy if exists "Managers can delete WOs" on ops.work_orders;
drop policy if exists "Vendors view assigned WOs" on ops.work_orders;
create policy "Management users view WOs"
on ops.work_orders for select using (platform.is_management_member(org_id) and platform.can_access_site(site_id));
-- Vendors use the safe projection RPCs below.  A direct table policy would expose
-- management-only columns such as cost, labor_hours, assigned_to, and metadata.
create policy "Management users create WOs"
on ops.work_orders for insert with check (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Management users update WOs"
on ops.work_orders for update using (platform.is_management_member(org_id) and platform.can_access_site(site_id)) with check (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Management users delete WOs"
on ops.work_orders for delete using (platform.is_management_member(org_id) and platform.is_site_manager(site_id));

drop policy if exists "View comments if can access site" on ops.work_order_comments;
drop policy if exists "Members create comments" on ops.work_order_comments;
create policy "Management users view work-order comments"
on ops.work_order_comments for select
using (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Vendors view public work-order comments"
on ops.work_order_comments for select
using (not is_internal and platform.vendor_can_access_work_order(work_order_id));
create policy "Management users create work-order comments"
on ops.work_order_comments for insert
with check (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Management users update work-order comments"
on ops.work_order_comments for update
using (platform.is_management_member(org_id) and platform.can_access_site(site_id))
with check (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Management users delete work-order comments"
on ops.work_order_comments for delete
using (platform.is_management_member(org_id) and platform.can_access_site(site_id));

drop policy if exists "View attachments if can access site" on ops.work_order_attachments;
drop policy if exists "Members manage attachments" on ops.work_order_attachments;
create policy "Management users view work-order attachments"
on ops.work_order_attachments for select
using (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Vendors view assigned work-order attachments"
on ops.work_order_attachments for select
using (platform.vendor_can_access_work_order(work_order_id));
create policy "Management users create work-order attachments"
on ops.work_order_attachments for insert
with check (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Management users update work-order attachments"
on ops.work_order_attachments for update
using (platform.is_management_member(org_id) and platform.can_access_site(site_id))
with check (platform.is_management_member(org_id) and platform.can_access_site(site_id));
create policy "Management users delete work-order attachments"
on ops.work_order_attachments for delete
using (platform.is_management_member(org_id) and platform.can_access_site(site_id));

update storage.buckets
set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
where id = 'work-order-attachments';

drop policy if exists "Members can manage WO attachments" on storage.objects;
create policy "Management users manage WO attachments"
on storage.objects for all
using (
  bucket_id = 'work-order-attachments'
  and platform.is_management_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
)
with check (
  bucket_id = 'work-order-attachments'
  and platform.is_management_member(((storage.foldername(name))[1])::uuid)
  and platform.can_access_site(((storage.foldername(name))[2])::uuid)
);

-----------------------------
-- SAFE VENDOR PROJECTIONS AND ACTION RPCS
-----------------------------
create or replace function vendor.get_vendor_portal_context()
returns jsonb
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
declare
  context_row record;
begin
  select
    vu.id as vendor_user_id,
    vu.org_id,
    vu.vendor_id,
    vu.email as user_email,
    v.name as vendor_name,
    v.type::text as vendor_type,
    p.full_name as user_name
  into context_row
  from vendor.vendor_users vu
  join platform.memberships m on m.org_id = vu.org_id and m.user_id = vu.user_id and m.role = 'vendor'
  join vendor.vendors v on v.id = vu.vendor_id and v.org_id = vu.org_id and v.status = 'active'
  left join platform.profiles p on p.id = auth.uid()
  where vu.user_id = auth.uid() and vu.status = 'active'
  order by vu.created_at
  limit 1;

  if not found then return null; end if;

  update vendor.vendor_users
  set last_login_at = now()
  where id = context_row.vendor_user_id;

  return jsonb_build_object(
    'user_id', auth.uid(),
    'org_id', context_row.org_id,
    'vendor_id', context_row.vendor_id,
    'vendor_name', context_row.vendor_name,
    'vendor_type', context_row.vendor_type,
    'user_email', context_row.user_email,
    'user_name', context_row.user_name
  );
end;
$$;

create or replace function vendor.work_order_projection(p_work_order_id uuid)
returns jsonb
language sql
security definer
set search_path = vendor, ops, portfolio, platform, public
as $$
  select jsonb_build_object(
    'id', wo.id,
    'number', 'WO-' || upper(substr(replace(wo.id::text, '-', ''), 1, 8)),
    'title', wo.title,
    'description', wo.description,
    'type', wo.type::text,
    'priority', wo.priority::text,
    'internal_status', wo.status::text,
    'vendor_assignment_status', wo.vendor_assignment_status::text,
    'vendor_id', wo.vendor_id,
    'property', jsonb_build_object(
      'id', s.id,
      'name', s.name,
      'address', nullif(concat_ws(', ', s.address_line1, s.city, nullif(concat_ws(' ', s.state, s.zip_code), '')), '')
    ),
    'location', case when sp.id is null then null else jsonb_build_object('id', sp.id, 'name', sp.name, 'code', sp.code) end,
    'due_date', wo.due_date,
    'sla_due_at', wo.sla_due_at,
    'vendor_assigned_at', wo.vendor_assigned_at,
    'vendor_responded_at', wo.vendor_responded_at,
    'vendor_decline_reason', wo.vendor_decline_reason,
    'vendor_completed_at', wo.vendor_completed_at,
    'created_at', wo.created_at,
    'updated_at', wo.updated_at,
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'comment', c.comment,
        'author_name', coalesce(p.full_name, p.email, 'PlutusPM user'),
        'created_at', c.created_at
      ) order by c.created_at)
      from ops.work_order_comments c
      left join platform.profiles p on p.id = c.user_id
      where c.work_order_id = wo.id and c.is_internal = false
    ), '[]'::jsonb),
    'attachments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'file_name', a.file_name,
        'mime_type', a.mime_type,
        'file_size', a.file_size,
        'created_at', a.created_at
      ) order by a.created_at)
      from ops.work_order_attachments a
      where a.work_order_id = wo.id
    ), '[]'::jsonb)
  )
  from ops.work_orders wo
  join portfolio.sites s on s.id = wo.site_id
  left join portfolio.spaces sp on sp.id = wo.space_id
  where wo.id = p_work_order_id and platform.vendor_can_access_work_order(wo.id);
$$;

create or replace function vendor.list_vendor_work_orders(p_filter text default 'needs_response')
returns setof jsonb
language sql
security definer
set search_path = vendor, ops, portfolio, platform, public
as $$
  select vendor.work_order_projection(wo.id)
  from ops.work_orders wo
  where platform.vendor_can_access_work_order(wo.id)
    and case p_filter
      when 'needs_response' then wo.vendor_assignment_status = 'pending_acceptance'
      when 'active' then wo.vendor_assignment_status in ('accepted', 'in_progress')
      when 'on_hold' then wo.vendor_assignment_status = 'on_hold'
      when 'in_review' then wo.vendor_assignment_status = 'completed_pending_review'
      when 'completed' then wo.vendor_assignment_status = 'completed'
      else false
    end
  order by wo.due_date nulls last, wo.created_at desc;
$$;

create or replace function vendor.get_vendor_work_order(p_work_order_id uuid)
returns jsonb
language sql
security definer
set search_path = vendor, ops, portfolio, platform, public
as $$
  select vendor.work_order_projection(p_work_order_id);
$$;

create or replace function vendor.respond_vendor_work_order(
  p_work_order_id uuid,
  p_decision text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = vendor, ops, portfolio, platform, public
as $$
declare
  work_order ops.work_orders%rowtype;
  reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select * into work_order from ops.work_orders where id = p_work_order_id and platform.vendor_can_access_work_order(id) for update;
  if not found then raise exception 'Work order is not available'; end if;
  if work_order.vendor_assignment_status <> 'pending_acceptance' then
    raise exception 'Work order is not awaiting a response';
  end if;
  if p_decision not in ('accept', 'decline') then raise exception 'Invalid vendor decision'; end if;
  if p_decision = 'decline' and reason is null then raise exception 'A decline reason is required'; end if;

  update ops.work_orders
  set vendor_assignment_status = case when p_decision = 'accept' then 'accepted' else 'declined' end,
      vendor_responded_at = now(),
      vendor_decline_reason = case when p_decision = 'decline' then reason else null end
  where id = p_work_order_id;

  return vendor.work_order_projection(p_work_order_id);
end;
$$;

create or replace function vendor.update_vendor_work_order_status(
  p_work_order_id uuid,
  p_status text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = vendor, ops, portfolio, platform, public
as $$
declare
  work_order ops.work_orders%rowtype;
  note_text text := nullif(trim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select * into work_order from ops.work_orders where id = p_work_order_id and platform.vendor_can_access_work_order(id) for update;
  if not found then raise exception 'Work order is not available'; end if;
  if work_order.status in ('cancelled', 'completed') then
    raise exception 'Work order is not active';
  end if;

  if p_status not in ('in_progress', 'on_hold', 'completed') then
    raise exception 'Invalid vendor work-order status';
  end if;
  if p_status = 'completed' and work_order.vendor_assignment_status not in ('accepted', 'in_progress', 'on_hold') then
    raise exception 'Work order is not ready for completion';
  end if;
  if p_status <> 'completed' and work_order.vendor_assignment_status not in ('accepted', 'in_progress', 'on_hold') then
    raise exception 'Work order is not active';
  end if;

  update ops.work_orders
  set vendor_assignment_status = case when p_status = 'completed' then 'completed_pending_review' else p_status::ops.vendor_assignment_status end,
      status = case when p_status = 'completed' then status else p_status::ops.work_order_status end,
      vendor_completed_at = case when p_status = 'completed' then now() else vendor_completed_at end
  where id = p_work_order_id;

  if note_text is not null then
    insert into ops.work_order_comments (work_order_id, org_id, site_id, user_id, comment, is_internal)
    values (work_order.id, work_order.org_id, work_order.site_id, auth.uid(), note_text, false);
  end if;

  if p_status = 'completed' then
    insert into platform.notifications (org_id, site_id, type, title, body, payload)
    values (
      work_order.org_id,
      work_order.site_id,
      'vendor_work_order_review',
      'Vendor completion needs review',
      work_order.title,
      jsonb_build_object('work_order_id', work_order.id, 'vendor_id', work_order.vendor_id)
    );
  end if;

  return vendor.work_order_projection(p_work_order_id);
end;
$$;

create or replace function vendor.add_vendor_work_order_note(
  p_work_order_id uuid,
  p_comment text
)
returns jsonb
language plpgsql
security definer
set search_path = vendor, ops, platform, public
as $$
declare
  work_order ops.work_orders%rowtype;
  comment_row ops.work_order_comments%rowtype;
  comment_text text := nullif(trim(coalesce(p_comment, '')), '');
  author_name text;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if comment_text is null or length(comment_text) > 5000 then raise exception 'A note between 1 and 5000 characters is required'; end if;
  select * into work_order from ops.work_orders where id = p_work_order_id and platform.vendor_can_access_work_order(id);
  if not found then raise exception 'Work order is not available'; end if;

  insert into ops.work_order_comments (work_order_id, org_id, site_id, user_id, comment, is_internal)
  values (work_order.id, work_order.org_id, work_order.site_id, auth.uid(), comment_text, false)
  returning * into comment_row;

  select coalesce(p.full_name, p.email, 'PlutusPM user') into author_name from platform.profiles p where p.id = auth.uid();
  return jsonb_build_object(
    'id', comment_row.id,
    'comment', comment_row.comment,
    'author_name', coalesce(author_name, 'PlutusPM user'),
    'created_at', comment_row.created_at
  );
end;
$$;

create or replace function vendor.review_vendor_completion(
  p_work_order_id uuid,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = vendor, ops, portfolio, platform, public
as $$
declare
  work_order ops.work_orders%rowtype;
  note_text text := nullif(trim(coalesce(p_note, '')), '');
  vendor_user_id uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select * into work_order from ops.work_orders where id = p_work_order_id for update;
  if not found or not platform.is_management_member(work_order.org_id) then raise exception 'Work order is not available'; end if;
  if work_order.vendor_assignment_status <> 'completed_pending_review' then raise exception 'Work order is not awaiting review'; end if;
  if p_decision not in ('approve', 'reject') then raise exception 'Invalid review decision'; end if;
  if p_decision = 'reject' and note_text is null then raise exception 'A rejection note is required'; end if;

  if p_decision = 'approve' then
    update ops.work_orders
    set vendor_assignment_status = 'completed', status = 'completed', completed_at = now()
    where id = p_work_order_id;
  else
    update ops.work_orders
    set vendor_assignment_status = 'in_progress', vendor_completed_at = null
    where id = p_work_order_id;
    insert into ops.work_order_comments (work_order_id, org_id, site_id, user_id, comment, is_internal)
    values (work_order.id, work_order.org_id, work_order.site_id, auth.uid(), note_text, false);
  end if;

  for vendor_user_id in
    select vu.user_id from vendor.vendor_users vu
    where vu.vendor_id = work_order.vendor_id and vu.org_id = work_order.org_id
      and vu.status = 'active' and vu.user_id is not null
  loop
    insert into platform.notifications (org_id, site_id, user_id, type, title, body, payload)
    values (
      work_order.org_id,
      work_order.site_id,
      vendor_user_id,
      'vendor_work_order_review',
      case when p_decision = 'approve' then 'Work order completion approved' else 'Work order completion needs more work' end,
      work_order.title,
      jsonb_build_object('work_order_id', work_order.id, 'decision', p_decision)
    );
  end loop;

  select * into work_order from ops.work_orders where id = p_work_order_id;
  return jsonb_build_object(
    'id', work_order.id,
    'decision', p_decision,
    'status', work_order.status,
    'vendor_assignment_status', work_order.vendor_assignment_status,
    'vendor_completed_at', work_order.vendor_completed_at
  );
end;
$$;

create or replace function vendor.register_vendor_work_order_attachment(
  p_attachment_id uuid,
  p_storage_path text,
  p_file_name text,
  p_file_size integer,
  p_mime_type text
)
returns jsonb
language plpgsql
security definer
set search_path = vendor, ops, platform, public
as $$
declare
  work_order ops.work_orders%rowtype;
  attachment_row ops.work_order_attachments%rowtype;
  expected_prefix text;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select * into work_order from ops.work_orders where id = (regexp_match(p_storage_path, 'work_orders/([0-9a-f-]{36})/'))[1]::uuid and platform.vendor_can_access_work_order(id);
  if not found then raise exception 'Work order is not available'; end if;
  expected_prefix := format('%s/%s/work_orders/%s/', work_order.org_id, work_order.site_id, work_order.id);
  if p_storage_path not like expected_prefix || '%' or position(p_attachment_id::text in p_storage_path) = 0 or position('..' in p_storage_path) > 0 then
    raise exception 'Invalid attachment path';
  end if;
  if p_file_size is null or p_file_size < 1 or p_file_size > 20971520 then raise exception 'Attachment exceeds the size limit'; end if;
  if lower(trim(coalesce(p_mime_type, ''))) not in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif') then
    raise exception 'Unsupported attachment type';
  end if;

  insert into ops.work_order_attachments (id, work_order_id, org_id, site_id, file_name, file_size, mime_type, storage_path, uploaded_by)
  values (p_attachment_id, work_order.id, work_order.org_id, work_order.site_id, p_file_name, p_file_size, lower(trim(p_mime_type)), p_storage_path, auth.uid())
  returning * into attachment_row;

  return jsonb_build_object(
    'id', attachment_row.id,
    'file_name', attachment_row.file_name,
    'mime_type', attachment_row.mime_type,
    'file_size', attachment_row.file_size,
    'created_at', attachment_row.created_at
  );
end;
$$;

create or replace function vendor.authorize_vendor_work_order_attachment(
  p_work_order_id uuid,
  p_attachment_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = vendor, ops, platform, public
as $$
declare
  work_order ops.work_orders%rowtype;
begin
  select * into work_order from ops.work_orders where id = p_work_order_id and platform.vendor_can_access_work_order(id);
  if not found then raise exception 'Work order is not available'; end if;
  return jsonb_build_object('attachment_id', p_attachment_id, 'org_id', work_order.org_id, 'site_id', work_order.site_id, 'work_order_id', work_order.id);
end;
$$;

create or replace function vendor.get_vendor_work_order_attachment(p_attachment_id uuid)
returns jsonb
language sql
security definer
set search_path = vendor, ops, platform, public
as $$
  select jsonb_build_object(
    'id', a.id,
    'file_name', a.file_name,
    'mime_type', a.mime_type,
    'file_size', a.file_size,
    'storage_path', a.storage_path
  )
  from ops.work_order_attachments a
  where a.id = p_attachment_id and platform.vendor_can_access_work_order(a.work_order_id);
$$;

create or replace function vendor.set_vendor_user_status(p_vendor_user_id uuid, p_status text)
returns vendor.vendor_users
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
declare
  user_row vendor.vendor_users%rowtype;
begin
  select * into user_row from vendor.vendor_users where id = p_vendor_user_id for update;
  if not found or not platform.is_management_member(user_row.org_id) then raise exception 'Vendor user is not available'; end if;
  if p_status not in ('active', 'suspended') then raise exception 'Invalid vendor-user status'; end if;
  update vendor.vendor_users set status = p_status, accepted_at = case when p_status = 'active' then coalesce(accepted_at, now()) else accepted_at end
  where id = p_vendor_user_id
  returning * into user_row;
  return user_row;
end;
$$;

drop function if exists vendor.activate_vendor_user();

create function vendor.activate_vendor_user()
returns setof vendor.vendor_users
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
declare
  user_row vendor.vendor_users%rowtype;
  account_email text := lower(coalesce(auth.jwt()->>'email', ''));
  has_linked_invite boolean;
  activated_count integer := 0;
begin
  if auth.uid() is null or account_email = '' then raise exception 'Not authenticated'; end if;
  select exists (
    select 1 from vendor.vendor_users vu
    where vu.user_id = auth.uid() and vu.status = 'invited'
  ) into has_linked_invite;

  for user_row in
    select vu.*
    from vendor.vendor_users vu
    where vu.status = 'invited'
      and (
        (has_linked_invite and vu.user_id = auth.uid())
        or (
          not has_linked_invite
          and vu.user_id is null
          and lower(vu.email) = account_email
          and exists (
            select 1 from platform.memberships m
            where m.org_id = vu.org_id and m.user_id = auth.uid() and m.role = 'vendor'
          )
          and not exists (
            select 1 from platform.memberships m
            where m.org_id = vu.org_id and m.user_id = auth.uid() and m.role <> 'vendor'
          )
        )
      )
    order by vu.created_at, vu.id
    for update
  loop
    if exists (
      select 1 from platform.memberships m
      where m.org_id = user_row.org_id and m.user_id = auth.uid() and m.role <> 'vendor'
    ) then
      raise exception 'Account is already assigned to a management role';
    end if;

    insert into platform.memberships (org_id, user_id, role, created_by)
    values (user_row.org_id, auth.uid(), 'vendor', auth.uid())
    on conflict (org_id, user_id) do update set role = 'vendor';

    update vendor.vendor_users
    set user_id = auth.uid(), status = 'active', accepted_at = coalesce(accepted_at, now())
    where id = user_row.id
    returning * into user_row;
    activated_count := activated_count + 1;
    return next user_row;
  end loop;

  if activated_count = 0 then raise exception 'Vendor invitation is not available'; end if;
  return;
end;
$$;

-- Vendor search must not become an alternate way to enumerate vendors.
create or replace function vendor.search_vendors(p_query text, p_org_id uuid default null, p_limit integer default 20)
returns setof vendor.vendors
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
begin
  if p_org_id is null or not platform.is_management_member(p_org_id) then return; end if;
  return query
  select v.* from vendor.vendors v
  where v.org_id = p_org_id
    and (v.name ilike '%' || p_query || '%' or v.contact_email ilike '%' || p_query || '%' or v.type::text ilike '%' || p_query || '%')
  order by v.name
  limit least(greatest(coalesce(p_limit, 20), 1), 100);
end;
$$;

-- These legacy compliance jobs mutate vendor records and are scheduler/service-role work,
-- not vendor portal operations.
revoke execute on function vendor.evaluate_vendor_compliance(uuid, uuid) from public, authenticated;
revoke execute on function vendor.evaluate_all_compliance(uuid) from public, authenticated;
revoke execute on function vendor.check_contract_expirations() from public, authenticated;
revoke execute on function vendor.check_document_expirations() from public, authenticated;
revoke execute on function vendor.check_coi_expirations() from public, authenticated;
grant execute on function vendor.evaluate_vendor_compliance(uuid, uuid) to service_role;
grant execute on function vendor.evaluate_all_compliance(uuid) to service_role;
grant execute on function vendor.check_contract_expirations() to service_role;
grant execute on function vendor.check_document_expirations() to service_role;
grant execute on function vendor.check_coi_expirations() to service_role;

-----------------------------
-- FUNCTION PRIVILEGES AND NOTIFICATION TYPES
-----------------------------
grant all on vendor.vendor_users to service_role;
grant select, insert, update, delete on vendor.vendor_users to authenticated;

alter table platform.notifications drop constraint if exists notifications_type_check;
alter table platform.notifications add constraint notifications_type_check check (type in (
  'sla_breach', 'coi_expiring', 'coi_expired', 'work_order_assigned',
  'service_request_created', 'visitor_arrived', 'lease_expiring',
  'compliance_issue', 'system', 'report_ready', 'reservation_reminder',
  'document_expiring', 'contract_expiring', 'contract_expired',
  'vendor_work_order_review'
));

revoke execute on function vendor.get_vendor_portal_context() from public;
revoke execute on function vendor.work_order_projection(uuid) from public;
revoke execute on function vendor.list_vendor_work_orders(text) from public;
revoke execute on function vendor.get_vendor_work_order(uuid) from public;
revoke execute on function vendor.respond_vendor_work_order(uuid, text, text) from public;
revoke execute on function vendor.update_vendor_work_order_status(uuid, text, text) from public;
revoke execute on function vendor.add_vendor_work_order_note(uuid, text) from public;
revoke execute on function vendor.review_vendor_completion(uuid, text, text) from public;
revoke execute on function vendor.register_vendor_work_order_attachment(uuid, text, text, integer, text) from public;
revoke execute on function vendor.authorize_vendor_work_order_attachment(uuid, uuid) from public;
revoke execute on function vendor.get_vendor_work_order_attachment(uuid) from public;
revoke execute on function vendor.set_vendor_user_status(uuid, text) from public;
revoke execute on function vendor.activate_vendor_user() from public;
grant execute on function vendor.get_vendor_portal_context() to authenticated, service_role;
grant execute on function vendor.list_vendor_work_orders(text) to authenticated, service_role;
grant execute on function vendor.get_vendor_work_order(uuid) to authenticated, service_role;
grant execute on function vendor.respond_vendor_work_order(uuid, text, text) to authenticated, service_role;
grant execute on function vendor.update_vendor_work_order_status(uuid, text, text) to authenticated, service_role;
grant execute on function vendor.add_vendor_work_order_note(uuid, text) to authenticated, service_role;
grant execute on function vendor.review_vendor_completion(uuid, text, text) to authenticated, service_role;
grant execute on function vendor.register_vendor_work_order_attachment(uuid, text, text, integer, text) to authenticated, service_role;
grant execute on function vendor.authorize_vendor_work_order_attachment(uuid, uuid) to authenticated, service_role;
grant execute on function vendor.get_vendor_work_order_attachment(uuid) to authenticated, service_role;
grant execute on function vendor.set_vendor_user_status(uuid, text) to authenticated, service_role;
grant execute on function vendor.activate_vendor_user() to authenticated, service_role;

