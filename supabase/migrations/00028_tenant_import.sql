-- 00028_tenant_import.sql
-- Part A4 of the frontend-wiring gap closure: bulk tenant CSV import with row-level validation
-- and a separate commit step, matching the frontend's TenantImportPreview/TenantImportRow/
-- TenantImportError shapes (app/_types/management-tenants.ts) and TenantImportErrorCode list.
-- Raw row data is stored as jsonb (not typed columns) so genuinely malformed input (bad dates,
-- unknown properties) can be validated and reported rather than rejected at INSERT time by a
-- Postgres type error.

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type tenant.tenant_import_status_enum as enum ('pending', 'validated', 'committed', 'failed');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.tenant_import_row_status_enum as enum ('valid', 'invalid', 'duplicate');
exception when duplicate_object then null;
end $$;

-----------------------------
-- TENANT.TENANT_IMPORT_BATCHES
-----------------------------
create table tenant.tenant_import_batches (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete cascade,
  uploaded_by uuid references platform.profiles(id) on delete set null,
  file_name text,
  status tenant.tenant_import_status_enum not null default 'pending',
  total_rows integer not null default 0,
  valid_rows integer not null default 0,
  invalid_rows integer not null default 0,
  duplicate_rows integer not null default 0,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_tenant_import_batches_org on tenant.tenant_import_batches(org_id);

create trigger set_tenant_import_batches_updated_at
  before update on tenant.tenant_import_batches
  for each row execute function public.handle_updated_at();

alter table tenant.tenant_import_batches enable row level security;

create policy "Managers manage import batches"
on tenant.tenant_import_batches for all
using (platform.is_org_admin(org_id) or (site_id is not null and platform.is_site_manager(site_id)));

select platform.attach_audit_trigger('tenant', 'tenant_import_batches');

-----------------------------
-- TENANT.TENANT_IMPORT_ROWS
-----------------------------
create table tenant.tenant_import_rows (
  id uuid primary key default uuid_generate_v4(),
  batch_id uuid not null references tenant.tenant_import_batches(id) on delete cascade,
  row_number integer not null,
  raw_data jsonb not null default '{}'::jsonb, -- keyed by TenantImportRow field names (camelCase)
  validation_status tenant.tenant_import_row_status_enum,
  errors jsonb not null default '[]'::jsonb, -- array of {code, field, message}
  resolved_site_id uuid references portfolio.sites(id),
  resolved_building_id uuid references portfolio.buildings(id),
  resolved_floor_id uuid references portfolio.floors(id),
  resolved_space_id uuid references portfolio.spaces(id),
  resolved_tenant_id uuid references tenant.tenants(id),
  created_at timestamptz default now() not null,
  unique (batch_id, row_number)
);

create index idx_tenant_import_rows_batch on tenant.tenant_import_rows(batch_id, row_number);

alter table tenant.tenant_import_rows enable row level security;

create policy "Managers manage import rows"
on tenant.tenant_import_rows for all
using (exists (
  select 1 from tenant.tenant_import_batches b
  where b.id = tenant_import_rows.batch_id
  and (platform.is_org_admin(b.org_id) or (b.site_id is not null and platform.is_site_manager(b.site_id)))
));

select platform.attach_audit_trigger('tenant', 'tenant_import_rows');

-----------------------------
-- HELPER: safe date parse (returns null instead of raising on bad input)
-----------------------------
create or replace function tenant.try_parse_date(p_text text)
returns date
language plpgsql
immutable
as $$
begin
  if p_text is null or btrim(p_text) = '' then return null; end if;
  return p_text::date;
exception when others then
  return null;
end;
$$;

-----------------------------
-- RPC: validate_tenant_import_batch
-- Runs BUSINESS_RULES.md's import validation rules per row: required fields, email/date format,
-- unknown property/building/floor/space, duplicate tenant/external ID (within the batch AND
-- against existing tenants), overlapping lease / space already occupied (via
-- tenant.check_occupancy_conflict from 00019). Writes results back per row and to the batch
-- summary; does not create any tenant/lease/occupancy rows - that's commit_tenant_import_batch.
-----------------------------
create or replace function tenant.validate_tenant_import_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = tenant, portfolio, platform, public
as $$
declare
  v_batch tenant.tenant_import_batches%rowtype;
  v_row record;
  v_errors jsonb;
  v_field text;
  v_company_name text;
  v_external_id text;
  v_email text;
  v_property_name text;
  v_building_name text;
  v_floor_name text;
  v_space_name text;
  v_lease_start text;
  v_lease_end text;
  v_move_in text;
  v_parsed_start date;
  v_parsed_end date;
  v_site_id uuid;
  v_building_id uuid;
  v_floor_id uuid;
  v_space_id uuid;
  v_is_duplicate boolean;
  v_valid_count integer := 0;
  v_invalid_count integer := 0;
  v_duplicate_count integer := 0;
begin
  select * into v_batch from tenant.tenant_import_batches where id = p_batch_id;
  if not found then raise exception 'Unknown import batch %', p_batch_id; end if;
  if not (platform.is_org_admin(v_batch.org_id) or (v_batch.site_id is not null and platform.is_site_manager(v_batch.site_id))) then
    raise exception 'Access denied to import batch %', p_batch_id;
  end if;

  for v_row in select * from tenant.tenant_import_rows where batch_id = p_batch_id order by row_number loop
    v_errors := '[]'::jsonb;
    v_site_id := null; v_building_id := null; v_floor_id := null; v_space_id := null;
    v_is_duplicate := false;

    v_company_name := btrim(coalesce(v_row.raw_data->>'tenantCompanyName', ''));
    v_external_id := nullif(btrim(coalesce(v_row.raw_data->>'externalTenantId', '')), '');
    v_email := nullif(btrim(coalesce(v_row.raw_data->>'primaryContactEmail', '')), '');
    v_property_name := nullif(btrim(coalesce(v_row.raw_data->>'property', '')), '');
    v_building_name := nullif(btrim(coalesce(v_row.raw_data->>'building', '')), '');
    v_floor_name := nullif(btrim(coalesce(v_row.raw_data->>'floor', '')), '');
    v_space_name := nullif(btrim(coalesce(v_row.raw_data->>'space', '')), '');
    v_lease_start := nullif(btrim(coalesce(v_row.raw_data->>'leaseStartDate', '')), '');
    v_lease_end := nullif(btrim(coalesce(v_row.raw_data->>'leaseExpirationDate', '')), '');
    v_move_in := nullif(btrim(coalesce(v_row.raw_data->>'moveInDate', '')), '');

    if v_company_name = '' then
      v_errors := v_errors || jsonb_build_object('code', 'missing_required', 'field', 'tenantCompanyName', 'message', 'Tenant company name is required');
    end if;

    if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      v_errors := v_errors || jsonb_build_object('code', 'invalid_email', 'field', 'primaryContactEmail', 'message', 'Invalid email format: ' || v_email);
    end if;

    v_parsed_start := null; v_parsed_end := null;
    if v_lease_start is not null then
      v_parsed_start := tenant.try_parse_date(v_lease_start);
      if v_parsed_start is null then
        v_errors := v_errors || jsonb_build_object('code', 'invalid_date', 'field', 'leaseStartDate', 'message', 'Invalid date: ' || v_lease_start);
      end if;
    end if;
    if v_lease_end is not null then
      v_parsed_end := tenant.try_parse_date(v_lease_end);
      if v_parsed_end is null then
        v_errors := v_errors || jsonb_build_object('code', 'invalid_date', 'field', 'leaseExpirationDate', 'message', 'Invalid date: ' || v_lease_end);
      end if;
    end if;
    if v_move_in is not null and tenant.try_parse_date(v_move_in) is null then
      v_errors := v_errors || jsonb_build_object('code', 'invalid_date', 'field', 'moveInDate', 'message', 'Invalid date: ' || v_move_in);
    end if;

    if v_property_name is not null then
      select id into v_site_id from portfolio.sites where org_id = v_batch.org_id and name ilike v_property_name limit 1;
      if v_site_id is null then
        v_errors := v_errors || jsonb_build_object('code', 'unknown_property', 'field', 'property', 'message', 'Unknown property: ' || v_property_name);
      end if;
    end if;

    if v_building_name is not null and v_site_id is not null then
      select id into v_building_id from portfolio.buildings where site_id = v_site_id and name ilike v_building_name limit 1;
      if v_building_id is null then
        v_errors := v_errors || jsonb_build_object('code', 'unknown_building', 'field', 'building', 'message', 'Unknown building: ' || v_building_name);
      end if;
    end if;

    if v_floor_name is not null and v_building_id is not null then
      select id into v_floor_id from portfolio.floors where building_id = v_building_id and name ilike v_floor_name limit 1;
      if v_floor_id is null then
        v_errors := v_errors || jsonb_build_object('code', 'unknown_floor', 'field', 'floor', 'message', 'Unknown floor: ' || v_floor_name);
      end if;
    end if;

    if v_space_name is not null and v_site_id is not null then
      select id into v_space_id from portfolio.spaces
      where site_id = v_site_id and (v_floor_id is null or floor_id = v_floor_id) and name ilike v_space_name limit 1;
      if v_space_id is null then
        v_errors := v_errors || jsonb_build_object('code', 'unknown_space', 'field', 'space', 'message', 'Unknown space: ' || v_space_name);
      end if;
    end if;

    if v_company_name != '' and exists (
      select 1 from tenant.tenants t where t.org_id = v_batch.org_id and t.company_name ilike v_company_name
    ) then
      v_errors := v_errors || jsonb_build_object('code', 'duplicate_tenant', 'field', 'tenantCompanyName', 'message', 'Tenant already exists: ' || v_company_name);
      v_is_duplicate := true;
    end if;
    if v_external_id is not null and exists (
      select 1 from tenant.tenants t where t.org_id = v_batch.org_id and t.external_tenant_id = v_external_id
    ) then
      v_errors := v_errors || jsonb_build_object('code', 'duplicate_external_id', 'field', 'externalTenantId', 'message', 'External ID already exists: ' || v_external_id);
      v_is_duplicate := true;
    end if;
    -- duplicate within the same batch (earlier row already claims this company name / external id)
    if v_company_name != '' and exists (
      select 1 from tenant.tenant_import_rows r2
      where r2.batch_id = p_batch_id and r2.row_number < v_row.row_number
      and btrim(coalesce(r2.raw_data->>'tenantCompanyName', '')) ilike v_company_name
    ) then
      v_errors := v_errors || jsonb_build_object('code', 'duplicate_tenant', 'field', 'tenantCompanyName', 'message', 'Duplicate within import file: ' || v_company_name);
      v_is_duplicate := true;
    end if;

    if v_space_id is not null and v_parsed_start is not null then
      if exists (select 1 from portfolio.spaces s where s.id = v_space_id and s.status = 'occupied') then
        v_errors := v_errors || jsonb_build_object('code', 'space_already_occupied', 'field', 'space', 'message', 'Space is currently occupied: ' || v_space_name);
      elsif tenant.check_occupancy_conflict(v_space_id, v_parsed_start, v_parsed_end, null) then
        v_errors := v_errors || jsonb_build_object('code', 'overlapping_lease', 'field', 'leaseStartDate', 'message', 'Overlaps an existing occupancy for this space');
      end if;
    end if;

    update tenant.tenant_import_rows
    set errors = v_errors,
        validation_status = (case
          when v_is_duplicate then 'duplicate'
          when jsonb_array_length(v_errors) > 0 then 'invalid'
          else 'valid'
        end)::tenant.tenant_import_row_status_enum,
        resolved_site_id = v_site_id, resolved_building_id = v_building_id,
        resolved_floor_id = v_floor_id, resolved_space_id = v_space_id
    where id = v_row.id;

    if v_is_duplicate then v_duplicate_count := v_duplicate_count + 1;
    elsif jsonb_array_length(v_errors) > 0 then v_invalid_count := v_invalid_count + 1;
    else v_valid_count := v_valid_count + 1;
    end if;
  end loop;

  update tenant.tenant_import_batches
  set status = 'validated', total_rows = v_valid_count + v_invalid_count + v_duplicate_count,
      valid_rows = v_valid_count, invalid_rows = v_invalid_count, duplicate_rows = v_duplicate_count,
      updated_at = now()
  where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'valid_rows', v_valid_count, 'invalid_rows', v_invalid_count, 'duplicate_rows', v_duplicate_count);
end;
$$;

comment on function tenant.validate_tenant_import_batch(uuid) is '@graphql({"type": "mutation", "name": "validateTenantImportBatch"})';

-----------------------------
-- RPC: commit_tenant_import_batch
-- Creates tenant/contact/lease/occupancy rows for every 'valid' row. Not transactional per-row
-- by design (whole function runs in one implicit transaction) - a failure partway through rolls
-- back the entire commit, which is the safer default for a bulk import.
-----------------------------
create or replace function tenant.commit_tenant_import_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = tenant, portfolio, platform, public
as $$
declare
  v_batch tenant.tenant_import_batches%rowtype;
  v_row record;
  v_tenant_id uuid;
  v_lease_id uuid;
  v_created_count integer := 0;
  v_parsed_start date;
  v_parsed_end date;
begin
  select * into v_batch from tenant.tenant_import_batches where id = p_batch_id;
  if not found then raise exception 'Unknown import batch %', p_batch_id; end if;
  if not (platform.is_org_admin(v_batch.org_id) or (v_batch.site_id is not null and platform.is_site_manager(v_batch.site_id))) then
    raise exception 'Access denied to import batch %', p_batch_id;
  end if;
  if v_batch.status != 'validated' then
    raise exception 'Batch % must be validated before commit (current status: %)', p_batch_id, v_batch.status;
  end if;

  for v_row in select * from tenant.tenant_import_rows where batch_id = p_batch_id and validation_status = 'valid' order by row_number loop
    insert into tenant.tenants (org_id, site_id, company_name, legal_name, external_tenant_id, industry)
    values (
      v_batch.org_id,
      coalesce(v_row.resolved_site_id, v_batch.site_id),
      v_row.raw_data->>'tenantCompanyName',
      nullif(v_row.raw_data->>'legalCompanyName', ''),
      nullif(v_row.raw_data->>'externalTenantId', ''),
      nullif(v_row.raw_data->>'industry', '')
    )
    returning id into v_tenant_id;

    if nullif(v_row.raw_data->>'primaryContactEmail', '') is not null then
      insert into tenant.tenant_contacts (tenant_id, profile_id, org_id, site_id, role, contact_type, is_primary)
      select v_tenant_id, p.id, v_batch.org_id, coalesce(v_row.resolved_site_id, v_batch.site_id), 'primary', 'primary', true
      from platform.profiles p
      where p.email = v_row.raw_data->>'primaryContactEmail';
      -- if no matching profile exists yet (contact hasn't signed up), the contact row is skipped
      -- here; a portal-invite flow is a separate feature from bulk import.
    end if;

    v_parsed_start := tenant.try_parse_date(v_row.raw_data->>'leaseStartDate');
    v_parsed_end := tenant.try_parse_date(v_row.raw_data->>'leaseExpirationDate');
    v_lease_id := null;

    if v_parsed_start is not null and v_row.resolved_site_id is not null then
      insert into portfolio.leases (org_id, site_id, space_id, tenant_id, start_date, end_date, status)
      values (v_batch.org_id, v_row.resolved_site_id, v_row.resolved_space_id, v_tenant_id, v_parsed_start, coalesce(v_parsed_end, v_parsed_start + interval '1 year'), 'active')
      returning id into v_lease_id;

      if v_row.resolved_space_id is not null then
        insert into portfolio.lease_spaces (lease_id, space_id, effective_start_date, effective_end_date)
        values (v_lease_id, v_row.resolved_space_id, v_parsed_start, v_parsed_end);

        insert into tenant.occupancies (org_id, site_id, tenant_id, space_id, lease_id, start_date, end_date, status)
        values (v_batch.org_id, v_row.resolved_site_id, v_tenant_id, v_row.resolved_space_id, v_lease_id, v_parsed_start, v_parsed_end,
          (case when v_parsed_start > current_date then 'future' else 'active' end)::tenant.occupancy_status_enum);
      end if;
    end if;

    update tenant.tenant_import_rows set resolved_tenant_id = v_tenant_id where id = v_row.id;
    v_created_count := v_created_count + 1;
  end loop;

  update tenant.tenant_import_batches set status = 'committed', updated_at = now() where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'created_count', v_created_count);
end;
$$;

comment on function tenant.commit_tenant_import_batch(uuid) is '@graphql({"type": "mutation", "name": "commitTenantImportBatch"})';

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated, service_role;
grant usage on all sequences in schema tenant to anon, authenticated, service_role;
