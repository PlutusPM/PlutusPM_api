-- 00006_seed_demo.sql
-- Demo data for testing - Run manually after creating a user
-- This is idempotent-ish, but best to run once

-- This seed expects you to replace YOUR_USER_ID with actual auth.users id
-- For local dev, you can create user via supabase auth, then run this

-- Helper: if no org exists, create demo org
-- Note: This will only work if you run as authenticated user or service_role

do $$
declare
  demo_org_id uuid;
  demo_user_id uuid;
  portfolio_id uuid;
  site_a_id uuid;
  site_b_id uuid;
  building_a_id uuid;
  floor_a_id uuid;
  space_a_id uuid;
  vendor_id uuid;
  asset_cat_id uuid;
begin
  -- Try to get first user as demo user (for local)
  select id into demo_user_id from auth.users limit 1;
  if demo_user_id is null then
    raise notice 'No auth.users found, skipping seed - create a user first';
    return;
  end if;

  -- Check if demo org already exists
  select id into demo_org_id from platform.organizations where slug = 'demo-cre' limit 1;
  if demo_org_id is not null then
    raise notice 'Demo org already exists % - skipping org creation', demo_org_id;
  else
    insert into platform.organizations (name, slug, owner_id, billing_tier)
    values ('Demo CRE Management Co', 'demo-cre', demo_user_id, 'growth')
    returning id into demo_org_id;

    -- Ensure profile exists
    insert into platform.profiles (id, email, full_name)
    values (demo_user_id, 'demo@cre.local', 'Demo Admin')
    on conflict (id) do nothing;

    -- Membership
    insert into platform.memberships (org_id, user_id, role)
    values (demo_org_id, demo_user_id, 'owner')
    on conflict (org_id, user_id) do nothing;

    raise notice 'Created demo org %', demo_org_id;
  end if;

  -- Portfolio
  select id into portfolio_id from portfolio.portfolios where org_id = demo_org_id limit 1;
  if portfolio_id is null then
    insert into portfolio.portfolios (org_id, name, description, manager_id)
    values (demo_org_id, 'Downtown Portfolio', 'Core office assets in downtown district', demo_user_id)
    returning id into portfolio_id;
  end if;

  -- Site A: Office Tower
  select id into site_a_id from portfolio.sites where slug = '100-main-tower' and org_id = demo_org_id limit 1;
  if site_a_id is null then
    insert into portfolio.sites (org_id, portfolio_id, name, slug, type, address_line1, city, state, zip_code, timezone, sq_ft, floors_count, latitude, longitude, created_by)
    values (
      demo_org_id, portfolio_id, '100 Main Street Tower', '100-main-tower', 'office',
      '100 Main Street', 'Austin', 'TX', '78701', 'America/Chicago',
      250000, 20, 30.2672, -97.7431, demo_user_id
    ) returning id into site_a_id;

    insert into portfolio.buildings (org_id, site_id, name, floors_count, sq_ft)
    values (demo_org_id, site_a_id, '100 Main Tower', 20, 250000)
    returning id into building_a_id;

    -- Create 5 floors as example
    for i in 1..5 loop
      insert into portfolio.floors (org_id, site_id, building_id, level_number, name, sq_ft)
      values (demo_org_id, site_a_id, building_a_id, i, 'Floor ' || i, 12500)
      returning id into floor_a_id;

      -- Create spaces per floor
      if i = 1 then
        insert into portfolio.spaces (org_id, site_id, building_id, floor_id, name, code, type, status, area_sq_ft)
        values 
          (demo_org_id, site_a_id, building_a_id, floor_a_id, 'Lobby', 'L-01', 'common', 'occupied', 3000),
          (demo_org_id, site_a_id, building_a_id, floor_a_id, 'Cafe', 'A-01', 'amenity', 'occupied', 1500),
          (demo_org_id, site_a_id, building_a_id, floor_a_id, 'Security Desk', 'S-01', 'common', 'occupied', 200);
      else
        insert into portfolio.spaces (org_id, site_id, building_id, floor_id, name, code, type, status, area_sq_ft)
        values
          (demo_org_id, site_a_id, building_a_id, floor_a_id, 'Suite '||i||'00', 'STE '||i||'00', 'leasable', case when i%2=0 then 'vacant' else 'occupied' end, 5000),
          (demo_org_id, site_a_id, building_a_id, floor_a_id, 'Suite '||i||'01', 'STE '||i||'01', 'leasable', 'occupied', 4000),
          (demo_org_id, site_a_id, building_a_id, floor_a_id, 'Conference Room '||i, 'CR-'||i, 'amenity', 'occupied', 500);
      end if;
    end loop;

    raise notice 'Created Site A %', site_a_id;
  end if;

  -- Site B: Retail Mall
  select id into site_b_id from portfolio.sites where slug = 'westfield-mall' and org_id = demo_org_id limit 1;
  if site_b_id is null then
    insert into portfolio.sites (org_id, portfolio_id, name, slug, type, address_line1, city, state, zip_code, sq_ft, floors_count, created_by)
    values (demo_org_id, portfolio_id, 'Westfield Shopping Center', 'westfield-mall', 'retail', '500 Commerce Blvd', 'Austin', 'TX', '78702', 400000, 2, demo_user_id)
    returning id into site_b_id;

    insert into portfolio.buildings (org_id, site_id, name, floors_count, sq_ft)
    values (demo_org_id, site_b_id, 'Westfield Mall Building', 2, 400000);

    raise notice 'Created Site B %', site_b_id;
  end if;

  -- Asset categories
  select id into asset_cat_id from ops.asset_categories where org_id = demo_org_id and name = 'HVAC' limit 1;
  if asset_cat_id is null then
    insert into ops.asset_categories (org_id, name, icon) values
    (demo_org_id, 'HVAC', 'wind'),
    (demo_org_id, 'Electrical', 'zap'),
    (demo_org_id, 'Plumbing', 'droplet'),
    (demo_org_id, 'Elevator', 'arrow-up'),
    (demo_org_id, 'Fire Safety', 'flame'),
    (demo_org_id, 'Security', 'shield')
    returning id into asset_cat_id;
  end if;

  -- Sample asset
  if site_a_id is not null and not exists (select 1 from ops.assets where site_id = site_a_id limit 1) then
    insert into ops.assets (org_id, site_id, category_id, name, description, status, criticality, manufacturer, model, serial_number)
    select demo_org_id, site_a_id, ac.id, 'Chiller Unit 1', 'Main chiller for tower cooling', 'active', 'critical', 'Trane', 'CVHF580', 'CH-001'
    from ops.asset_categories ac where ac.org_id = demo_org_id and ac.name = 'HVAC' limit 1;

    insert into ops.assets (org_id, site_id, category_id, name, status, criticality)
    select demo_org_id, site_a_id, ac.id, 'Elevator Car A', 'active', 'high'
    from ops.asset_categories ac where ac.org_id = demo_org_id and ac.name = 'Elevator' limit 1;

    insert into ops.assets (org_id, site_id, category_id, name, status, criticality)
    select demo_org_id, site_a_id, ac.id, 'Fire Panel Main', 'active', 'critical'
    from ops.asset_categories ac where ac.org_id = demo_org_id and ac.name = 'Fire Safety' limit 1;
  end if;

  -- PM templates
  if not exists (select 1 from ops.work_order_templates where org_id = demo_org_id limit 1) then
    insert into ops.work_order_templates (org_id, site_id, name, description, type, priority, recurrence_rule, next_due_at)
    values
      (demo_org_id, site_a_id, 'Monthly HVAC Inspection', 'Inspect filters, belts, refrigerant levels', 'preventive', 'medium', 'FREQ=MONTHLY', now() + interval '1 day'),
      (demo_org_id, site_a_id, 'Quarterly Fire Safety Test', 'Test alarms, sprinklers, emergency lights', 'preventive', 'high', 'FREQ=MONTHLY;INTERVAL=3', now() + interval '7 days'),
      (demo_org_id, null, 'Weekly Lobby Cleaning Audit', 'Audit cleaning quality in common areas', 'inspection', 'low', 'FREQ=WEEKLY', now() + interval '2 days');
  end if;

  -- Vendors
  select id into vendor_id from vendor.vendors where org_id = demo_org_id limit 1;
  if vendor_id is null then
    insert into vendor.vendors (org_id, name, type, status, contact_email) values
    (demo_org_id, 'Cool Air HVAC Services', 'hvac', 'active', 'dispatch@coolair.example.com'),
    (demo_org_id, 'SecureGuard Security', 'security', 'active', 'ops@secureguard.example.com'),
    (demo_org_id, 'CleanPro Janitorial', 'cleaning', 'active', 'service@cleanpro.example.com')
    returning id into vendor_id;

    -- Sample contract
    insert into vendor.contracts (org_id, vendor_id, site_id, title, status, start_date, end_date, value)
    values (demo_org_id, vendor_id, site_a_id, 'HVAC Maintenance 2024-2025', 'active', '2024-01-01', '2025-12-31', 75000);

    -- Sample COI expiring soon (for cron test)
    insert into vendor.cois (org_id, vendor_id, site_id, type, issue_date, expiry_date, status, coverage_amount)
    values (demo_org_id, vendor_id, site_a_id, 'general_liability', '2024-01-01', current_date + interval '20 days', 'valid', 2000000);
  end if;

  -- Tenant
  if site_a_id is not null and not exists (select 1 from tenant.tenants where site_id = site_a_id limit 1) then
    insert into tenant.tenants (org_id, site_id, company_name, contact_email, status)
    values (demo_org_id, site_a_id, 'Acme Tech Inc', 'facilities@acme.example.com', 'active');
  end if;

  raise notice 'Seed completed for org % with sites % and %', demo_org_id, site_a_id, site_b_id;
end $$;

-- Show what we created
select 'Organizations' as table_name, count(*) from platform.organizations
union all select 'Portfolios', count(*) from portfolio.portfolios
union all select 'Sites', count(*) from portfolio.sites
union all select 'Buildings', count(*) from portfolio.buildings
union all select 'Spaces', count(*) from portfolio.spaces
union all select 'Assets', count(*) from ops.assets
union all select 'Vendors', count(*) from vendor.vendors;
