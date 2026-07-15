# Commercial Real Estate SaaS — Platform Architecture Plan

**Stack:** Supabase (Postgres + Auth + Realtime + Storage + Edge Functions) + pg_graphql + pg_cron/scheduler + PostGIS
**Model:** Multi-tenant SaaS | Domain-Driven | Portfolio → Sites → Everything on Site

> Status: PLANNING PHASE - No code yet. Review this before we migrate.

---

## 1. Core Insight: Portfolio and Sites as the Aggregate Root

You said **"models everything on site"** - This is the key architectural decision.

Every domain entity belongs to a Site. A Site belongs to a Portfolio. A Portfolio belongs to an Organization (SaaS Tenant).

```
Organization (your SaaS customer - e.g., CBRE, JLL, Property Manager)
 └── Portfolio (grouping - e.g., "Northeast Portfolio", "Client A Assets")
      └── Site (the center of the universe - e.g., "One World Trade, NYC")
           ├── Buildings (1 site can have N buildings)
           │    └── Floors/Levels
           │         └── Spaces/Units (leasable, common, amenity, parking)
           ├── [BUILDING OPS] Assets, Work Orders, Inspections, Inventory
           ├── [TENANT EXP] Tenants, Leases, Reservations, Service Requests
           ├── [VISITOR MGMT] Visitors, Passes, Access Logs
           ├── [COMPLIANCE] Vendors, Contracts, COIs (scoped to site)
           └── [ANALYTICS] Metrics rollups per site
```

**Why this matters:** RLS, GraphQL, Realtime, and Analytics all filter by `site_id`. If user has access to site, they get everything underneath.

---

## 2. Platform Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         SUPABASE PLATFORM                               │
├─────────────────────────────────────────────────────────────────────────┤
│  GraphQL Gateway (pg_graphql)  │  REST (PostgREST) │  Realtime │ Storage │
├─────────────────────────────────────────────────────────────────────────┤
│  Auth (JWT) + RBAC + RLS  │  pg_cron + pg_net  │  Edge Functions       │
├─────────────────────────────────────────────────────────────────────────┤
│                          POSTGRES - 6 SCHEMAS                            │
│  [platform]  [portfolio]  [ops]  [tenant]  [visitor]  [vendor]  [metrics] │
└─────────────────────────────────────────────────────────────────────────┘
```

### Schemas vs Public?

**Recommendation: Use separate Postgres schemas per domain.** This matches your Business Capability doc perfectly and makes GraphQL cleaner.

```sql
create schema platform;   -- auth profiles, orgs, users, roles, audit, notifications
create schema portfolio;  -- portfolios, sites, buildings, floors, spaces
create schema ops;        -- assets, work_orders, inspections, inventory
create schema tenant;     -- tenants, leases, reservations, announcements
create schema visitor;    -- visitors, visits, passes, access_logs
create schema vendor;     -- vendors, contracts, cois, compliance
create schema metrics;    -- materialized views, daily rollups, KPIs
```

**Pros:** Domain ownership, clean GraphQL namespaces (`portfolioSites`, `opsWorkOrders`), least privilege, can evolve independently.
**Cons:** Slightly more complex RLS cross-schema joins (solved with SECURITY DEFINER helper functions).

Alternative is single `public` schema - simpler for MVP. I recommend **schemas for long-term SaaS**, but we can start in `public` with prefixes if you want speed. Decision needed.

---

## 3. Tech Stack Decisions (Your Requirements)

### Postgres (Supabase)
- **PostGIS** extension for geo (site location, visitor tracking)
- **pg_trgm** for search (assets, tenants, vendors)
- **ltree** or closure table for space hierarchy if needed
- All tables have: `id uuid PK, org_id, site_id (where applicable), created_at, updated_at, created_by, metadata jsonb`

### GraphQL - pg_graphql (Native Supabase)
Supabase ships with `pg_graphql` extension. No extra server needed.

```sql
create extension if not exists pg_graphql;
create extension if not exists pg_stat_statements;
```

Exposed at: `https://<project>.supabase.co/graphql/v1`

**How it works:**
- Automatically generates GraphQL schema from Postgres tables/views/functions
- Respects RLS: JWT `auth.uid()` filtered at DB level -> secure by default
- Supports Relations via FKs
- Custom mutations via Postgres functions: e.g., `create_organization(name, slug)` -> GraphQL mutation

**Frontend query example:**
```graphql
query GetPortfolioWithSites {
  platformOrganizationsCollection {
    edges { node { id name } }
  }
  portfolioPortfoliosCollection {
    edges {
      node {
        id name
        portfolioSitesCollection {
          edges {
            node {
              id name address city
              opsAssetsCollection(filter: {status: {eq: ACTIVE}}) {
                edges { node { id name category } }
              }
            }
          }
        }
      }
    }
  }
}
```

We will also deploy a **thin Edge Function `graphql-proxy`** if you need custom middleware (rate limit, logging, persisted queries) - but start with native.

### Scheduler - Chosen: pg_cron + pg_net + Scheduled Edge Functions

You asked for "some scheduler of your choice" - **Best for Supabase is 3-layer:**

**Layer 1: pg_cron (DB inside Supabase)**
Builtin cron inside Postgres. Perfect for DB jobs. No external dependency.

Enable:
```sql
create extension if not exists pg_cron;
grant usage on schema cron to postgres;
```

Use cases:
- Every 15m: Check COI expiring in 30/60/90 days -> insert into notifications
- Every hour: SLA breach detection on work_orders
- Nightly 2am: Rollup metrics -> `metrics.daily_site_stats`
- Daily: Auto-generate PM work orders from templates

**Layer 2: pg_net (call HTTP from cron)**
```sql
-- cron calls edge function
select net.http_post(
  url:='https://<project>.supabase.co/functions/v1/process-compliance-checks',
  headers:='{"Authorization": "Bearer <service_role>"}'::jsonb
);
```

**Layer 3: Supabase Scheduled Edge Functions (config.toml)**
For jobs needing external APIs (Stripe, SendGrid, Slack).

In `supabase/config.toml`:
```toml
[functions.process-compliance-checks]
schedule = "0 9 * * *"  # 9am daily
```

This gives you both internal DB scheduling and external job runner with one pattern.

Do NOT use external BullMQ/Temporal for MVP - adds infra. pg_cron covers 90% of CRE SaaS needs.

---

## 4. Domain Data Model (High Level)

### Platform Schema (Shared)

```sql
platform.organizations (id, name, slug, owner_id, billing_tier)
platform.profiles (id fk auth.users, email, full_name)
platform.memberships (org_id, user_id, role: owner/admin/manager/engineer/security/tenant_user/read_only)
platform.roles + platform.permissions (RBAC)
platform.audit_logs (org_id, site_id, user_id, action, entity, entity_id, diff)
platform.notifications (org_id, site_id, user_id, type, payload, read)
```

### Portfolio Schema

```sql
portfolio.portfolios (id, org_id, name, description, color, manager_id)
portfolio.sites (id, org_id, portfolio_id, name, slug, type: office/retail/industrial/mixed, 
                 address, city, state, zip, timezone, lat/lng via PostGIS, 
                 status, sq_ft, year_built, metadata)
portfolio.buildings (id, site_id, name, floors_count, sq_ft)
portfolio.floors (id, building_id, level_number, name, floorplan_storage_path, sq_ft)
portfolio.spaces (id, site_id, floor_id, building_id, name, code, 
                  type: leasable/common/amenity/parking/storage/external,
                  status: vacant/occupied/reserved/maintenance, 
                  area_sq_ft, tenant_id, lease_id)
portfolio.leases (id, site_id, space_id, tenant_id, start_date, end_date, type, status, monthly_rent)
```

Everything has `org_id` + `site_id` for RLS partitioning.

### Ops Schema

```sql
ops.asset_categories (id, org_id, name, icon)
ops.assets (id, org_id, site_id, building_id, floor_id, space_id, 
            category_id, name, qr_code, status, manufacturer, model, serial, 
            install_date, warranty_end, criticality)
ops.work_order_templates (for PM)
ops.work_orders (id, org_id, site_id, asset_id, space_id, 
                 type: preventive/corrective/inspection/request,
                 title, description, priority, status, 
                 assigned_to, created_by, due_date, completed_at, sla_due_at,
                 labor_hours, cost)
ops.inspections (id, site_id, asset_id, checklist_id, status, score)
ops.checklists + checklist_items
ops.inventory_items + parts + stock_transactions
ops.incidents
```

### Tenant Schema

```sql
tenant.tenants (id, org_id, site_id, company_name, legal_name, contact_email)
tenant.tenant_contacts (tenant_id, profile_id, title)
tenant.service_requests (id, site_id, space_id, tenant_contact_id, 
                         type, title, description, status, priority, 
                         work_order_id fk)
tenant.reservations (id, site_id, space_id (amenity), reserved_by, start, end, status)
tenant.announcements (site_id, title, body, publish_at, audience)
tenant.events (site_id, title, start, end)
```

### Visitor Schema

```sql
visitor.visitors (id, org_id, email, name, company, id_doc_hash)
visitor.visits (id, site_id, visitor_id, host_user_id, host_space_id,
                purpose, status: preregistered/checked_in/checked_out/denied,
                scheduled_at, checked_in_at, checked_out_at, qr_code)
visitor.passes (visit_id, qr_token, expires_at)
visitor.access_logs (site_id, visit_id, device_id, access_point, event: granted/denied, timestamp)
visitor.access_credentials (user_id, type: nfc/bluetooth/qr, credential_id)
```

### Vendor Schema

```sql
vendor.vendors (id, org_id, name, type: cleaning/hvac/security/etc, status, website)
vendor.vendor_contacts
vendor.contracts (id, vendor_id, site_id, title, start_date, end_date, value, status, storage_path)
vendor.cois (id, vendor_id, contract_id, type, issue_date, expiry_date, 
             status: valid/expiring/expired, storage_path, verified_at)
vendor.compliance_rules (org_id, vendor_type, required_coi_types, min_coverage)
vendor.compliance_status (vendor_id, site_id, status: compliant/non_compliant/pending, 
                          issues jsonb, last_checked)
```

### Metrics Schema

Materialized views + rollups:
```sql
metrics.daily_site_stats (site_id, date, work_orders_open, work_orders_closed, 
                          sla_breaches, visitor_count, occupancy_rate, compliance_rate)
metrics.kpi_definitions
```

---

## 5. RBAC & RLS Strategy (Critical for Multi-Tenant)

**Roles:**
- `org_owner` - full access, billing
- `portfolio_manager` - all sites in portfolios assigned
- `site_manager` - full access to specific sites
- `building_engineer` - ops domain only, assigned sites
- `security_officer` - visitor domain, check-in/out
- `tenant_admin` - own company spaces, can create service requests
- `tenant_user` - limited to reservations
- `vendor` - only own contracts/COIs
- `read_only_auditor`

**Implementation:**
1. JWT custom claims: `org_id`, `site_ids[]`, `role`, `portfolio_ids[]` via `auth.jwt()` hook
2. Helper functions: `platform.is_org_member(org_id)`, `platform.can_access_site(site_id)`, `platform.has_permission('ops.work_orders:write')`
3. RLS on every table: `using (platform.can_access_site(site_id))`
4. Audit logs via trigger on all tables -> `platform.audit_logs`

GraphQL automatically inherits RLS - frontend cannot bypass.

---

## 6. Realtime & Notifications

- Supabase Realtime on: `ops.work_orders`, `visitor.visits`, `tenant.service_requests`, `platform.notifications`
- Frontend subscribes: `supabase.channel('site:123').on('postgres_changes', {table: 'work_orders', filter: 'site_id=eq.123'}, ...)`
- Notifications table + pg_notify -> Edge Function calls OneSignal/SendGrid/Slack

---

## 7. File Storage Structure

```
Bucket: site-files (private)
  /{org_id}/{site_id}/floorplans/{floor_id}.pdf
  /{org_id}/{site_id}/assets/{asset_id}/photos/{file}
  /{org_id}/{site_id}/inspections/{inspection_id}/{file}
  /{org_id}/{site_id}/cois/{vendor_id}/{coi_id}.pdf
  /{org_id}/{site_id}/contracts/{contract_id}.pdf
Bucket: avatars (public)
Bucket: visitor-photos (private, 24h retention)
```

All storage RLS uses `platform.can_access_site()` parsing folder path.

---

## 8. Implementation Phases

**Phase 0 (This week - Architecture & Core):**
- Setup Supabase project, enable extensions (pg_graphql, pg_cron, pg_net, postgis, pg_trgm)
- Create schemas, platform + portfolio core tables, RBAC helpers, RLS
- GraphQL endpoint working
- Seeded demo org + portfolio + 2 sites

**Phase 1 (Building Ops MVP):**
- Assets, Work Orders, Inspections, Inventory
- QR code generation function
- SLA cron job
- Realtime

**Phase 2 (Tenant + Visitor):**
- Tenants, Service Requests <-> Work Orders link
- Visitor registration + QR passes
- Access logs

**Phase 3 (Compliance + Vendor):**
- Vendors, Contracts, COIs
- Expiration cron + notifications
- Compliance dashboard materialized view

**Phase 4 (Portfolio & Analytics):**
- Daily rollup crons
- Executive dashboard queries via GraphQL aggregations
- Scheduled reports (Edge Function + pg_cron)

---

## 9. Open Decisions For You

1. **Schemas:** Separate schemas per domain (my rec) vs single public schema?
2. **Space hierarchy depth:** Do you need `Site -> Building -> Floor -> Space` or is `Site -> Space` enough for MVP?
3. **GraphQL auth:** Native pg_graphql only, or also deploy Hasura/PostGraphile wrapper?
4. **Multi-tenancy strictness:** One org sees only its data (typical) - or do you need cross-org for property managers managing for clients?
5. **Scheduler detail:** Should PM work orders auto-generate? What COI expiration windows trigger notifications? (30/60/90 days?)

---

## Next Step

If you approve this architecture, I will:
1. Scaffold Supabase project with all schemas, extensions, RLS helpers
2. Create full migration for Phase 0 (platform + portfolio core)
3. Enable GraphQL and show sample queries
4. Create first cron jobs + Edge Function template
5. Provide API docs for your frontend dev

Reply `approve` or tell me what to change.
