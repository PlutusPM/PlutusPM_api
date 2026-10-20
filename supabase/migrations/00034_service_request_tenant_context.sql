-- Preserve the tenant and tenant-contact that originated a service request.
-- The tenant portal calls this function through PostgREST RPC.
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
  v_tenant_id uuid;
  v_tenant_contact_id uuid;
  new_sr tenant.service_requests;
  new_wo ops.work_orders;
begin
  if not platform.can_access_site(p_site_id) then
    raise exception 'Access denied';
  end if;

  select org_id into v_org_id from portfolio.sites where id = p_site_id;

  select tc.tenant_id
    into v_tenant_id
    from tenant.tenant_contacts tc
   where tc.profile_id = auth.uid()
     and tc.site_id = p_site_id
   order by tc.is_primary desc, tc.created_at asc
   limit 1;

  -- service_requests.tenant_contact_id currently references platform.profiles.
  -- Keep that FK valid while tenant_id carries the tenant-company relationship.
  v_tenant_contact_id := auth.uid();

  insert into tenant.service_requests (
    org_id, site_id, space_id, tenant_id, tenant_contact_id,
    title, description, priority, created_by, status
  )
  values (
    v_org_id, p_site_id, p_space_id, v_tenant_id, v_tenant_contact_id,
    p_title, p_description, p_priority, auth.uid(), 'open'
  )
  returning * into new_sr;

  insert into ops.work_orders (org_id, site_id, space_id, title, description, priority, type, created_by, status)
  values (v_org_id, p_site_id, p_space_id, 'SR: ' || p_title, p_description, p_priority, 'service_request', auth.uid(), 'open')
  returning * into new_wo;

  update tenant.service_requests
     set work_order_id = new_wo.id
   where id = new_sr.id
   returning * into new_sr;

  return new_sr;
end;
$$;

comment on function tenant.create_service_request(uuid, uuid, text, text, ops.priority_level)
  is '@graphql({"type": "mutation", "name": "createServiceRequest"})';
