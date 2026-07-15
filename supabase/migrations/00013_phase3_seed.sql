-- 00013_phase3_seed.sql
-- Seed Phase 3: Compliance rules, vendor documents, notification rules, approvals

do $$
declare
  demo_org_id uuid;
  demo_site_id uuid;
  vendor_id uuid;
  profile_id uuid;
  rule_id uuid;
  contract_id uuid;
begin
  select id into demo_org_id from platform.organizations where slug='demo-cre' limit 1;
  if demo_org_id is null then raise notice 'No demo org'; return; end if;

  select id into demo_site_id from portfolio.sites where org_id=demo_org_id limit 1;
  select id into profile_id from platform.profiles limit 1;
  select id into vendor_id from vendor.vendors where org_id=demo_org_id limit 1;

  -- Compliance Rules
  if not exists (select 1 from vendor.compliance_rules where org_id=demo_org_id limit 1) then
    insert into vendor.compliance_rules (org_id, name, description, vendor_type, required_coi_types, min_coverage, validity_days, severity, is_active, created_by)
    values
      (demo_org_id, 'Default Insurance Requirements - All Vendors', 'All vendors must have General Liability $1M and Workers Comp $500k valid for at least 30 days', null, array['general_liability','workers_comp'], '{"general_liability": 1000000, "workers_comp": 500000}'::jsonb, 30, 'high', true, profile_id),
      (demo_org_id, 'HVAC Vendors - Enhanced', 'HVAC vendors require General Liability $2M, Workers Comp $1M, Auto $1M', 'hvac'::vendor.vendor_type, array['general_liability','workers_comp','auto'], '{"general_liability":2000000,"workers_comp":1000000,"auto":1000000}'::jsonb, 60, 'critical', true, profile_id),
      (demo_org_id, 'Security Vendors', 'Security requires General Liability $2M and Auto $1M', 'security'::vendor.vendor_type, array['general_liability','auto'], '{"general_liability":2000000,"auto":1000000}'::jsonb, 30, 'high', true, profile_id),
      (demo_org_id, 'Elevator Vendors - High Risk', 'Elevator vendors require $5M general liability + umbrella', 'elevator'::vendor.vendor_type, array['general_liability','umbrella','workers_comp'], '{"general_liability":5000000,"umbrella":5000000,"workers_comp":1000000}'::jsonb, 90, 'critical', true, profile_id);

    raise notice 'Created compliance rules';
  end if;

  -- Vendor Contacts for demo vendors
  if vendor_id is not null and not exists (select 1 from vendor.vendor_contacts where vendor_id=vendor_id limit 1) then
    insert into vendor.vendor_contacts (vendor_id, org_id, name, email, phone, role, is_primary)
    select id, org_id, 'John Manager', 'john@' || lower(replace(name,' ','_')) || '.example.com', '+1-555-' || (1000 + (random()*9000)::int)::text, 'Account Manager', true
    from vendor.vendors where org_id=demo_org_id limit 3;

    insert into vendor.vendor_contacts (vendor_id, org_id, name, email, phone, role)
    select id, org_id, 'Billing Dept', 'billing@' || lower(replace(name,' ','_')) || '.example.com', '+1-555-' || (1000 + (random()*9000)::int)::text, 'Billing'
    from vendor.vendors where org_id=demo_org_id limit 3;
  end if;

  -- Notification Rules
  if not exists (select 1 from vendor.notification_rules where org_id=demo_org_id limit 1) then
    insert into vendor.notification_rules (org_id, name, description, event_type, days_before, channels, recipient_roles, is_active)
    values
      (demo_org_id, 'COI Expiring Alerts', 'Notify managers when COI expiring', 'coi_expiring', array[30,14,7,1], array['in_app','email'], array['admin','site_manager']::platform.org_role[], true),
      (demo_org_id, 'COI Expired Critical', 'Immediate alert when COI expired', 'coi_expired', array[0], array['in_app','email','slack'], array['owner','admin','site_manager']::platform.org_role[], true),
      (demo_org_id, 'Contract Expiring', 'Notify 30 and 7 days before contract ends', 'contract_expiring', array[30,7], array['in_app','email'], array['admin','site_manager']::platform.org_role[], true),
      (demo_org_id, 'Compliance Failure', 'When vendor becomes non-compliant', 'compliance_failed', array[0], array['in_app','email','slack'], array['owner','admin','auditor']::platform.org_role[], true),
      (demo_org_id, 'Document Expiring', 'Licenses, certs expiring', 'document_expiring', array[30,7], array['in_app'], array['admin']::platform.org_role[], true);
  end if;

  -- Vendor Documents (generic)
  if vendor_id is not null and not exists (select 1 from vendor.documents where vendor_id=vendor_id limit 1) then
    insert into vendor.documents (org_id, vendor_id, site_id, title, category, status, storage_path, file_name, expiry_date, uploaded_by)
    values
      (demo_org_id, vendor_id, demo_site_id, 'Business License 2024', 'license', 'verified', demo_org_id::text || '/' || vendor_id::text || '/docs/license-2024.pdf', 'license-2024.pdf', current_date + interval '200 days', profile_id),
      (demo_org_id, vendor_id, demo_site_id, 'Safety Certification OSHA 10', 'certification', 'verified', demo_org_id::text || '/' || vendor_id::text || '/docs/osha10.pdf', 'osha10.pdf', current_date + interval '400 days', profile_id),
      (demo_org_id, vendor_id, demo_site_id, 'W9 Form', 'other', 'verified', demo_org_id::text || '/' || vendor_id::text || '/docs/w9.pdf', 'w9.pdf', null, profile_id);
  end if;

  -- Update existing contracts to have approval workflow demo
  update vendor.contracts set approval_status='approved', approved_by=profile_id, approved_at=now(), auto_renew=true
  where org_id=demo_org_id and approval_status='pending';

  -- Add a pending contract for approval demo
  if vendor_id is not null and demo_site_id is not null and not exists (select 1 from vendor.contracts where vendor_id=vendor_id and title like '%Pending Approval%') then
    insert into vendor.contracts (org_id, vendor_id, site_id, title, description, status, approval_status, start_date, end_date, value)
    values (demo_org_id, vendor_id, demo_site_id, 'Cleaning Services 2025 - Pending Approval', 'Annual cleaning contract awaiting approval', 'active', 'pending', '2025-01-01', '2025-12-31', 45000);
  end if;

  -- Evaluate compliance for all demo vendors
  perform vendor.evaluate_all_compliance(demo_org_id);

  raise notice 'Phase 3 seed done for org %', demo_org_id;
end $$;

-- Show summary
select 'Compliance Rules' as tbl, count(*) from vendor.compliance_rules
union all select 'Vendor Contacts', count(*) from vendor.vendor_contacts
union all select 'Documents', count(*) from vendor.documents
union all select 'Notification Rules', count(*) from vendor.notification_rules
union all select 'Compliance Status', count(*) from vendor.compliance_status
union all select 'Compliance Audit Logs', count(*) from vendor.compliance_audit_logs;
