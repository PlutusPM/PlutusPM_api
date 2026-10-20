-- 00032_rename_organizations_to_tenants.sql
-- platform.organizations -> platform.tenants
-- A platform tenant is a SaaS customer, addressed by subdomain: <slug>.<root domain>.
-- Not to be confused with tenant.tenants, which are the renter companies inside a tenant's sites.
-- org_id columns are unchanged and keep pointing here; FKs, RLS policies and the
-- row type follow the rename automatically. Function bodies do not, so they are recreated below.

alter table platform.organizations rename to tenants;

alter trigger set_platform_orgs_updated_at on platform.tenants rename to set_platform_tenants_updated_at;

-- Both platform.tenants and tenant.tenants would inflect to the same GraphQL type name.
comment on table platform.tenants is e'@graphql({"name": "PlatformTenant"})';

-----------------------------
-- create_organization -> create_tenant
-----------------------------
drop function if exists platform.create_organization(text, text);

create or replace function platform.create_tenant(p_name text, p_slug text)
returns platform.tenants
language plpgsql
security definer
set search_path = platform, public
as $$
declare
  new_tenant platform.tenants;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  if p_slug !~ '^[a-z0-9-]+$' then raise exception 'Slug must be lowercase letters, numbers, hyphens'; end if;

  insert into platform.tenants (name, slug, owner_id)
  values (p_name, p_slug, v_user_id)
  returning * into new_tenant;

  insert into platform.memberships (org_id, user_id, role, site_ids, portfolio_ids)
  values (new_tenant.id, v_user_id, 'owner', null, null);

  return new_tenant;
end;
$$;

comment on function platform.create_tenant(text, text) is '@graphql({"type": "mutation", "name": "createTenant"})';

-----------------------------
-- approve_access_request: notification looks up the tenant name
-----------------------------
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
  values (req.org_id, target_user_id, 'system', 'Access approved: ' || (select name from platform.tenants where id = req.org_id), 'Your access request was approved', jsonb_build_object('org_id', req.org_id, 'role', req.requested_role));

  return new_membership;
end;
$$;

comment on function platform.approve_access_request(uuid) is '@graphql({"type": "mutation", "name": "approveAccessRequest"})';

notify pgrst, 'reload schema';
