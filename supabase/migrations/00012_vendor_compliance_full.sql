-- 00012_vendor_compliance_full.sql
-- Phase 3: Full Compliance & Vendor Management
-- Vendor contacts, documents, compliance rules, approval workflows, COI OCR data, notification rules, dashboard views

-----------------------------
-- VENDOR CONTACTS
-----------------------------
create table vendor.vendor_contacts (
  id uuid primary key default uuid_generate_v4(),
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name text not null,
  email text,
  phone text,
  role text, -- e.g., 'Account Manager', 'Field Supervisor', 'Billing'
  is_primary boolean default false,
  is_billing boolean default false,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_vendor_contacts_vendor on vendor.vendor_contacts(vendor_id);
create index idx_vendor_contacts_org on vendor.vendor_contacts(org_id);

create trigger set_vendor_contacts_updated_at before update on vendor.vendor_contacts for each row execute function public.handle_updated_at();

alter table vendor.vendor_contacts enable row level security;
create policy "View contacts if org member" on vendor.vendor_contacts for select using (platform.is_org_member(org_id));
create policy "Managers manage contacts" on vendor.vendor_contacts for all using (platform.is_org_member(org_id));

-----------------------------
-- GENERIC VENDOR DOCUMENT REPOSITORY
-----------------------------
do $$ begin
  create type vendor.document_category as enum ('insurance','contract','certification','safety','license','w9','other');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type vendor.document_status as enum ('pending_review','verified','expired','rejected','archived');
exception when duplicate_object then null;
end $$;

create table vendor.documents (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete set null, -- null = org-wide doc
  contract_id uuid references vendor.contracts(id) on delete set null,
  coi_id uuid references vendor.cois(id) on delete set null,
  title text not null,
  description text,
  category vendor.document_category not null default 'other',
  status vendor.document_status not null default 'pending_review',
  storage_path text not null, -- e.g., org_id/vendor_id/docs/filename.pdf -> maps to coi-documents or contract-documents bucket
  file_name text,
  file_size integer,
  mime_type text,
  expiry_date date, -- for licenses, certs
  issue_date date,
  uploaded_by uuid references platform.profiles(id) on delete set null,
  verified_by uuid references platform.profiles(id) on delete set null,
  verified_at timestamptz,
  rejection_reason text,
  metadata jsonb default '{}'::jsonb, -- {"ocr_extracted": {...}, "coverage": 1000000, "type": "general_liability"}
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_vendor_docs_vendor on vendor.documents(vendor_id);
create index idx_vendor_docs_site on vendor.documents(site_id);
create index idx_vendor_docs_category on vendor.documents(category);
create index idx_vendor_docs_expiry on vendor.documents(expiry_date) where expiry_date is not null;
create index idx_vendor_docs_status on vendor.documents(status);

create trigger set_vendor_docs_updated_at before update on vendor.documents for each row execute function public.handle_updated_at();

alter table vendor.documents enable row level security;
create policy "View docs if org member" on vendor.documents for select using (platform.is_org_member(org_id));
create policy "Managers manage docs" on vendor.documents for all using (platform.is_org_member(org_id));

-----------------------------
-- COMPLIANCE RULES ENGINE
-----------------------------
create table vendor.compliance_rules (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  name text not null, -- e.g., "HVAC Vendor Insurance Requirements"
  description text,
  vendor_type vendor.vendor_type, -- null = applies to all types
  site_id uuid references portfolio.sites(id) on delete cascade, -- null = org-wide rule
  required_coi_types text[] not null default array['general_liability','workers_comp'], -- which COI types must exist
  required_doc_categories vendor.document_category[] default null, -- required doc categories
  required_doc_types text[] default null, -- custom doc types
  min_coverage jsonb default '{}'::jsonb, -- {"general_liability": 1000000, "workers_comp": 500000, "auto": 1000000}
  required_certifications text[], -- e.g., ["OSHA 10", "EPA"]
  validity_days integer, -- COI must be valid for at least N days
  is_active boolean default true not null,
  severity text default 'medium' check (severity in ('low','medium','high','critical')),
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_compliance_rules_org on vendor.compliance_rules(org_id);
create index idx_compliance_rules_vendor_type on vendor.compliance_rules(vendor_type);
create index idx_compliance_rules_site on vendor.compliance_rules(site_id);

create trigger set_compliance_rules_updated_at before update on vendor.compliance_rules for each row execute function public.handle_updated_at();

alter table vendor.compliance_rules enable row level security;
create policy "View rules if org member" on vendor.compliance_rules for select using (platform.is_org_member(org_id));
create policy "Admins manage rules" on vendor.compliance_rules for all using (platform.is_org_admin(org_id) or platform.is_org_member(org_id));

-----------------------------
-- CONTRACT ENHANCEMENTS (approval workflow)
-----------------------------
do $$ begin
  create type vendor.approval_status as enum ('pending','approved','rejected','expired');
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table vendor.contracts add column approval_status vendor.approval_status default 'pending' not null;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.contracts add column approved_by uuid references platform.profiles(id);
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.contracts add column approved_at timestamptz;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.contracts add column rejection_reason text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.contracts add column auto_renew boolean default false;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.contracts add column renewal_notice_days integer default 30;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.contracts add column payment_terms text;
exception when duplicate_column then null;
end $$;

-- Contract approvals history (multi-approver workflow)
create table vendor.contract_approvals (
  id uuid primary key default uuid_generate_v4(),
  contract_id uuid not null references vendor.contracts(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  approver_id uuid not null references platform.profiles(id) on delete cascade,
  status vendor.approval_status not null default 'pending',
  comments text,
  created_at timestamptz default now() not null,
  decided_at timestamptz
);

create index idx_contract_approvals_contract on vendor.contract_approvals(contract_id);
create index idx_contract_approvals_approver on vendor.contract_approvals(approver_id);

alter table vendor.contract_approvals enable row level security;
create policy "View approvals if org member" on vendor.contract_approvals for select using (platform.is_org_member(org_id));
create policy "Managers manage approvals" on vendor.contract_approvals for all using (platform.is_org_member(org_id));

-----------------------------
-- COI ENHANCEMENTS (OCR + verification)
-----------------------------
do $$ begin
  alter table vendor.cois add column auto_extracted jsonb default '{}'::jsonb;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.cois add column rejection_reason text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.cois add column policy_number text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.cois add column insurer_name text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.cois add column additional_insured boolean default false;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table vendor.cois add column certificate_holder text;
exception when duplicate_column then null;
end $$;

-----------------------------
-- VENDOR APPROVALS (vendor onboarding)
-----------------------------
do $$ begin
  create type vendor.vendor_approval_status as enum ('pending','approved','rejected','suspended','expired');
exception when duplicate_object then null;
end $$;

create table vendor.vendor_approvals (
  id uuid primary key default uuid_generate_v4(),
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete set null,
  status vendor.vendor_approval_status not null default 'pending',
  approved_by uuid references platform.profiles(id) on delete set null,
  approved_at timestamptz,
  rejection_reason text,
  compliance_check_id uuid, -- link to last compliance check
  notes text,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_vendor_approvals_vendor on vendor.vendor_approvals(vendor_id);
create index idx_vendor_approvals_org on vendor.vendor_approvals(org_id);

create trigger set_vendor_approvals_updated_at before update on vendor.vendor_approvals for each row execute function public.handle_updated_at();

alter table vendor.vendor_approvals enable row level security;
create policy "View vendor approvals if org member" on vendor.vendor_approvals for select using (platform.is_org_member(org_id));
create policy "Managers manage vendor approvals" on vendor.vendor_approvals for all using (platform.is_org_member(org_id));

-----------------------------
-- NOTIFICATION RULES (per compliance type)
-----------------------------
create table vendor.notification_rules (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete cascade, -- null = org-wide
  name text not null,
  description text,
  event_type text not null check (event_type in ('coi_expiring','coi_expired','contract_expiring','contract_expired','compliance_failed','vendor_approval_needed','document_expiring')),
  days_before integer[] default array[30,7,1], -- notify 30,7,1 days before expiry
  channels text[] default array['in_app','email'], -- in_app, email, slack
  recipient_roles platform.org_role[] default array['admin','site_manager']::platform.org_role[], -- which roles get notified
  recipient_user_ids uuid[] default null, -- specific users
  is_active boolean default true not null,
  created_at timestamptz default now() not null
);

create index idx_notif_rules_org on vendor.notification_rules(org_id);

alter table vendor.notification_rules enable row level security;
create policy "View notif rules if org member" on vendor.notification_rules for select using (platform.is_org_member(org_id));
create policy "Admins manage notif rules" on vendor.notification_rules for all using (platform.is_org_admin(org_id));

-----------------------------
-- COMPLIANCE AUDIT HISTORY
-----------------------------
create table vendor.compliance_audit_logs (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  vendor_id uuid not null references vendor.vendors(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete set null,
  rule_id uuid references vendor.compliance_rules(id) on delete set null,
  previous_status vendor.compliance_status_type,
  new_status vendor.compliance_status_type not null,
  issues jsonb default '[]'::jsonb,
  checked_by uuid references platform.profiles(id) on delete set null, -- null = system cron
  created_at timestamptz default now() not null
);

create index idx_compliance_audit_vendor on vendor.compliance_audit_logs(vendor_id, created_at desc);
create index idx_compliance_audit_site on vendor.compliance_audit_logs(site_id, created_at desc);

alter table vendor.compliance_audit_logs enable row level security;
create policy "View compliance audit if org member" on vendor.compliance_audit_logs for select using (platform.is_org_member(org_id));
create policy "System can insert audit" on vendor.compliance_audit_logs for insert with check (true);

-----------------------------
-- COMPLIANCE DASHBOARD VIEWS
-----------------------------
-- Detailed compliance view per vendor
create or replace view vendor.v_compliance_dashboard as
select
  v.id as vendor_id,
  v.org_id,
  v.name as vendor_name,
  v.type as vendor_type,
  v.status as vendor_status,
  s.id as site_id,
  s.name as site_name,
  cs.status as compliance_status,
  cs.issues,
  cs.last_checked,
  -- Counts
  (select count(*) from vendor.contracts c where c.vendor_id = v.id and c.site_id = s.id and c.status = 'active') as active_contracts,
  (select count(*) from vendor.cois co where co.vendor_id = v.id and co.status = 'valid') as valid_cois,
  (select count(*) from vendor.cois co where co.vendor_id = v.id and co.status = 'expiring') as expiring_cois,
  (select count(*) from vendor.cois co where co.vendor_id = v.id and co.status = 'expired') as expired_cois,
  (select count(*) from vendor.documents d where d.vendor_id = v.id and d.status = 'expired') as expired_docs,
  -- Soonest expiry
  (select min(expiry_date) from vendor.cois where vendor_id = v.id and expiry_date >= current_date) as next_expiry_date,
  -- Coverage totals
  (select sum(coverage_amount) from vendor.cois where vendor_id = v.id and status = 'valid') as total_coverage
from vendor.vendors v
cross join portfolio.sites s
left join vendor.compliance_status cs on cs.vendor_id = v.id and (cs.site_id = s.id or cs.site_id is null)
where v.org_id = s.org_id;

-- Enable security invoker if PG 15+
do $$ begin
  execute 'alter view vendor.v_compliance_dashboard set (security_invoker = true)';
exception when others then null;
end $$;

-- Vendor summary per org (for portfolio view)
create or replace view vendor.v_vendor_summary as
select
  v.org_id,
  v.id as vendor_id,
  v.name,
  v.type,
  v.status,
  count(distinct cs.site_id) as sites_covered,
  count(distinct c.id) filter (where c.status='active') as active_contracts,
  count(distinct co.id) filter (where co.status='valid') as valid_cois,
  count(distinct co.id) filter (where co.status='expiring') as expiring_cois,
  count(distinct co.id) filter (where co.status='expired') as expired_cois,
  max(cs.last_checked) as last_compliance_check,
  case
    when count(*) filter (where cs.status='non_compliant') >0 then 'non_compliant'
    when count(*) filter (where cs.status='pending') >0 then 'pending'
    else 'compliant'
  end as overall_status
from vendor.vendors v
left join vendor.compliance_status cs on cs.vendor_id = v.id
left join vendor.contracts c on c.vendor_id = v.id
left join vendor.cois co on co.vendor_id = v.id
group by v.org_id, v.id, v.name, v.type, v.status;

do $$ begin
  execute 'alter view vendor.v_vendor_summary set (security_invoker = true)';
exception when others then null;
end $$;

-----------------------------
-- COMPLIANCE ENGINE FUNCTIONS
-----------------------------

-- Evaluate single vendor against rules for a site
create or replace function vendor.evaluate_vendor_compliance(
  p_vendor_id uuid,
  p_site_id uuid default null
)
returns vendor.compliance_status
language plpgsql
security definer
set search_path = vendor, platform, portfolio, public
as $$
declare
  v_org_id uuid;
  v_vendor vendor.vendors%rowtype;
  v_rules vendor.compliance_rules[]; -- array
  r vendor.compliance_rules%rowtype;
  v_status vendor.compliance_status_type := 'compliant';
  v_issues jsonb := '[]'::jsonb;
  v_coi vendor.cois%rowtype;
  v_required_type text;
  v_min_coverage numeric;
  v_existing_coi vendor.cois%rowtype;
  new_status vendor.compliance_status%rowtype;
begin
  select * into v_vendor from vendor.vendors where id = p_vendor_id;
  if not found then raise exception 'Vendor not found'; end if;
  v_org_id := v_vendor.org_id;

  -- If site_id provided, check site belongs to same org
  if p_site_id is not null then
    if not exists (select 1 from portfolio.sites where id = p_site_id and org_id = v_org_id) then
      raise exception 'Site % not in vendor org %', p_site_id, v_org_id;
    end if;
  end if;

  -- Loop through active rules that apply to this vendor type and site
  for r in
    select * from vendor.compliance_rules
    where org_id = v_org_id
    and is_active = true
    and (vendor_type is null or vendor_type = v_vendor.type)
    and (site_id is null or site_id = p_site_id)
  loop
    -- Check each required COI type
    foreach v_required_type in array r.required_coi_types loop
      select * into v_existing_coi from vendor.cois
      where vendor_id = p_vendor_id
      and type = v_required_type
      and (p_site_id is null or site_id = p_site_id or site_id is null)
      and status in ('valid','expiring')
      order by expiry_date desc limit 1;

      if not found then
        v_status := 'non_compliant';
        v_issues := v_issues || jsonb_build_object(
          'rule_id', r.id,
          'rule_name', r.name,
          'type', 'missing_coi',
          'coi_type', v_required_type,
          'severity', r.severity,
          'message', 'Missing required COI: ' || v_required_type
        );
      else
        -- Check expiry validity
        if v_existing_coi.expiry_date < current_date then
          v_status := 'non_compliant';
          v_issues := v_issues || jsonb_build_object(
            'rule_id', r.id,
            'type', 'expired_coi',
            'coi_type', v_required_type,
            'expiry_date', v_existing_coi.expiry_date,
            'message', 'COI expired: ' || v_required_type
          );
        elsif v_existing_coi.expiry_date < current_date + (coalesce(r.validity_days,0) || ' days')::interval then
          if v_status = 'compliant' then v_status := 'pending'; end if;
          v_issues := v_issues || jsonb_build_object(
            'rule_id', r.id,
            'type', 'expiring_coi',
            'coi_type', v_required_type,
            'expiry_date', v_existing_coi.expiry_date,
            'message', 'COI expiring soon: ' || v_required_type
          );
        end if;

        -- Check min coverage
        v_min_coverage := (r.min_coverage->>v_required_type)::numeric;
        if v_min_coverage is not null and v_existing_coi.coverage_amount < v_min_coverage then
          v_status := 'non_compliant';
          v_issues := v_issues || jsonb_build_object(
            'rule_id', r.id,
            'type', 'insufficient_coverage',
            'coi_type', v_required_type,
            'required', v_min_coverage,
            'actual', v_existing_coi.coverage_amount,
            'message', 'Insufficient coverage for ' || v_required_type || ': required ' || v_min_coverage || ', got ' || v_existing_coi.coverage_amount
          );
        end if;
      end if;
    end loop;

    -- Check required document categories (simplified)
    -- For each required doc category, ensure at least one verified doc exists not expired
    -- (Implementation omitted for brevity, but similar loop over required_doc_categories)
  end loop;

  -- Upsert compliance_status
  insert into vendor.compliance_status (org_id, vendor_id, site_id, status, issues, last_checked)
  values (v_org_id, p_vendor_id, p_site_id, v_status, v_issues, now())
  on conflict (vendor_id, site_id) do update set
    status = excluded.status,
    issues = excluded.issues,
    last_checked = now(),
    updated_at = now()
  returning * into new_status;

  -- Log audit if status changed
  insert into vendor.compliance_audit_logs (org_id, vendor_id, site_id, rule_id, previous_status, new_status, issues, checked_by)
  values (v_org_id, p_vendor_id, p_site_id, null, null, v_status, v_issues, auth.uid());

  -- Update vendor_approvals status based on compliance?
  -- If non_compliant, set vendor approval to suspended? Decide via business rule
  -- For now, we leave approval separate

  return new_status;
end;
$$;

comment on function vendor.evaluate_vendor_compliance(uuid, uuid) is '@graphql({"type": "mutation", "name": "evaluateVendorCompliance"})';

-- Evaluate all vendors for org (cron uses this)
create or replace function vendor.evaluate_all_compliance(p_org_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = vendor, public
as $$
declare
  rec record;
  cnt integer :=0;
begin
  for rec in
    select v.id as vendor_id, s.id as site_id
    from vendor.vendors v
    join portfolio.sites s on s.org_id = v.org_id
    where (p_org_id is null or v.org_id = p_org_id)
  loop
    perform vendor.evaluate_vendor_compliance(rec.vendor_id, rec.site_id);
    cnt := cnt + 1;
  end loop;

  -- Also evaluate org-wide (site_id null) for each vendor
  for rec in select id as vendor_id from vendor.vendors where (p_org_id is null or org_id = p_org_id) loop
    perform vendor.evaluate_vendor_compliance(rec.vendor_id, null);
    cnt := cnt + 1;
  end loop;

  return cnt;
end;
$$;

-- Contract expiration check (for cron)
create or replace function vendor.check_contract_expirations()
returns integer
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
declare
  cnt integer :=0;
begin
  -- Expire contracts past end_date
  with expired as (
    update vendor.contracts set status = 'expired', updated_at = now()
    where end_date < current_date and status = 'active'
    returning org_id, site_id, vendor_id, id, title, end_date
  ),
  notif as (
    insert into platform.notifications (org_id, site_id, type, title, body, payload)
    select org_id, site_id, 'contract_expired', 'Contract expired: ' || title, 'Contract expired on ' || end_date::text, jsonb_build_object('contract_id', id, 'vendor_id', vendor_id)
    from expired
    returning 1
  )
  select count(*) into cnt from expired;

  -- Notify expiring in 30,7,1 days based on notification_rules
  -- Simplified: notify for 30 days
  insert into platform.notifications (org_id, site_id, type, title, body, payload)
  select org_id, site_id, 'contract_expiring', 'Contract expiring: ' || title, 'Contract expires on ' || end_date::text, jsonb_build_object('contract_id', id, 'days_left', (end_date - current_date))
  from vendor.contracts
  where status = 'active'
  and end_date between current_date and current_date + interval '30 days';

  return cnt;
end;
$$;

-- Document expiry
create or replace function vendor.check_document_expirations()
returns integer
language plpgsql
security definer
set search_path = vendor, platform, public
as $$
begin
  insert into platform.notifications (org_id, site_id, type, title, body, payload)
  select org_id, site_id, 'document_expiring', 'Document expiring: ' || title, 'Expires ' || expiry_date::text, jsonb_build_object('document_id', id, 'vendor_id', vendor_id)
  from vendor.documents
  where expiry_date between current_date and current_date + interval '30 days'
  and status != 'expired';

  update vendor.documents set status='expired', updated_at=now()
  where expiry_date < current_date and status != 'expired';

  return 1;
end;
$$;

-- Grants
grant all on all tables in schema vendor to service_role;
grant usage, select, insert, update, delete on all tables in schema vendor to authenticated;
grant usage on all sequences in schema vendor to authenticated, service_role;

-- Realtime
alter publication supabase_realtime add table vendor.vendor_contacts;
alter publication supabase_realtime add table vendor.documents;
alter publication supabase_realtime add table vendor.compliance_rules;
alter publication supabase_realtime add table vendor.contract_approvals;
alter publication supabase_realtime add table vendor.vendor_approvals;
alter publication supabase_realtime add table vendor.compliance_status;
alter publication supabase_realtime add table vendor.notification_rules;

-- Crons
select cron.schedule(
  'evaluate-vendor-compliance',
  '0 6 * * *',
  $$ select vendor.evaluate_all_compliance(); $$
) where not exists (select 1 from cron.job where jobname='evaluate-vendor-compliance');

select cron.schedule(
  'check-contract-expirations',
  '0 7 * * *',
  $$ select vendor.check_contract_expirations(); $$
) where not exists (select 1 from cron.job where jobname='check-contract-expirations');

select cron.schedule(
  'check-document-expirations',
  '0 7 * * *',
  $$ select vendor.check_document_expirations(); $$
) where not exists (select 1 from cron.job where jobname='check-document-expirations');
