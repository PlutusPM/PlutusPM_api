-- 00037_demo_tenant_roster.sql
-- Add a fuller, connected tenant roster for One Commerce Plaza.
-- Safe to re-run: all records use deterministic ids and conflict guards.

insert into tenant.tenants (id, org_id, site_id, company_name, legal_name, contact_email, contact_phone, status, tenant_type, industry, external_tenant_id, website, company_phone)
values
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1001', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Piedmont Health Advisors', 'Piedmont Health Advisors PLLC', 'operations@piedmonthealth.example.com', '(704) 555-0211', 'active', 'commercial', 'Healthcare Consulting', 'EXT-PHA-007', 'https://piedmonthealth.example.com', '(704) 555-0211'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1002', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Elm Street Partners', 'Elm Street Partners LLC', 'admin@elmstreet.example.com', '(704) 555-0212', 'active', 'commercial', 'Real Estate Advisory', 'EXT-ESP-008', 'https://elmstreet.example.com', '(704) 555-0212'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1003', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Queen City Media Group', 'Queen City Media Group Inc', 'workplace@queencitymedia.example.com', '(704) 555-0213', 'active', 'commercial', 'Media & Communications', 'EXT-QCM-009', 'https://queencitymedia.example.com', '(704) 555-0213'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1004', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Evergreen Workplace Services', 'Evergreen Workplace Services LLC', 'facilities@evergreenworkplace.example.com', '(704) 555-0214', 'active', 'commercial', 'Business Services', 'EXT-EWS-010', 'https://evergreenworkplace.example.com', '(704) 555-0214')
on conflict (id) do nothing;

-- Individual resident-style records. These are intentionally unassigned because the
-- current One Commerce Plaza seed contains commercial office space, not residential units.
insert into tenant.tenants (id, org_id, site_id, company_name, legal_name, contact_email, contact_phone, status, tenant_type, industry, external_tenant_id, website, company_phone)
values
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1101', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Avery Morgan', 'Avery Morgan', 'avery.morgan@example.com', '(704) 555-0221', 'active', 'residential', 'Resident', 'RES-001', null, '(704) 555-0221'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1102', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Jordan Ellis', 'Jordan Ellis', 'jordan.ellis@example.com', '(704) 555-0222', 'active', 'residential', 'Resident', 'RES-002', null, '(704) 555-0222'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1103', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Maya Rodriguez', 'Maya Rodriguez', 'maya.rodriguez@example.com', '(704) 555-0223', 'active', 'residential', 'Resident', 'RES-003', null, '(704) 555-0223'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1104', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Ethan Walker', 'Ethan Walker', 'ethan.walker@example.com', '(704) 555-0224', 'active', 'residential', 'Resident', 'RES-004', null, '(704) 555-0224'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1105', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Sofia Bennett', 'Sofia Bennett', 'sofia.bennett@example.com', '(704) 555-0225', 'active', 'residential', 'Resident', 'RES-005', null, '(704) 555-0225'),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1106', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'Noah Thompson', 'Noah Thompson', 'noah.thompson@example.com', '(704) 555-0226', 'active', 'residential', 'Resident', 'RES-006', null, '(704) 555-0226')
on conflict (id) do nothing;

insert into portfolio.leases (id, org_id, site_id, space_id, tenant_id, start_date, end_date, status, monthly_rent, security_deposit, lease_type, renewal_of_lease_id)
values
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2001', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', '2f1e9b69-816c-5679-af74-2c8d1f70188f', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1001', '2026-09-01', '2028-08-31', 'active', 11800, 23600, 'fixed', null),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2002', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'a9f1954d-2699-5a59-bd24-b5c3970c6824', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1002', '2026-11-01', '2028-10-31', 'active', 10400, 20800, 'fixed', null),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2003', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'd1e0c5c6-8872-56c4-8f53-ca869e94173f', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1003', '2026-12-01', '2028-11-30', 'active', 11200, 22400, 'fixed', null),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2004', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', '44e40606-2514-5357-9184-72c036c27e27', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1004', '2026-08-15', '2028-08-14', 'active', 13600, 27200, 'fixed', null)
on conflict (id) do nothing;

insert into portfolio.lease_spaces (lease_id, space_id, effective_start_date, effective_end_date, square_feet)
values
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2001', '2f1e9b69-816c-5679-af74-2c8d1f70188f', '2026-09-01', '2028-08-31', 3200),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2002', 'a9f1954d-2699-5a59-bd24-b5c3970c6824', '2026-11-01', '2028-10-31', 2800),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2003', 'd1e0c5c6-8872-56c4-8f53-ca869e94173f', '2026-12-01', '2028-11-30', 3000),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2004', '44e40606-2514-5357-9184-72c036c27e27', '2026-08-15', '2028-08-14', 3800)
on conflict do nothing;

insert into tenant.occupancies (id, org_id, site_id, tenant_id, space_id, lease_id, start_date, end_date, move_in_date, move_out_date, occupied_square_feet, status, is_primary, shared_occupancy)
values
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f3001', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1001', '2f1e9b69-816c-5679-af74-2c8d1f70188f', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2001', '2026-09-01', '2028-08-31', '2026-09-01', null, 3200, 'active', true, false),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f3002', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1002', 'a9f1954d-2699-5a59-bd24-b5c3970c6824', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2002', '2026-11-01', '2028-10-31', null, null, 2800, 'future', true, false),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f3003', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1003', 'd1e0c5c6-8872-56c4-8f53-ca869e94173f', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2003', '2026-12-01', '2028-11-30', null, null, 3000, 'future', true, false),
  ('c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f3004', '08f4a9f4-2d61-5c9a-b683-d1d1013f181b', '25b420e7-1544-5cfd-9f7f-dd81420b6693', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f1004', '44e40606-2514-5357-9184-72c036c27e27', 'c1f6a4d0-3c59-5f06-bb8d-9c1b8f4f2004', '2026-08-15', '2028-08-14', '2026-08-15', null, 3800, 'active', true, false)
on conflict (id) do nothing;
