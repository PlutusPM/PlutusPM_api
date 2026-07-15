# Implementation Plan - After Architecture Approval

## Phase 0: Core Platform (2-3 days) - DO THIS FIRST

**Goal:** Portfolio + Sites working, GraphQL live, RBAC, scheduler skeleton.

### Migrations

1. `00000_extensions.sql`
   - pg_graphql, postgis, pg_trgm, pg_cron, pg_net, uuid-ossp, pgcrypto

2. `00001_platform.sql`
   - schemas: platform, portfolio
   - platform.organizations, profiles, memberships
   - handle_new_user trigger
   - helper functions: current_org_ids(), can_access_site(), is_org_admin()
   - RLS enabled + policies
   - audit_logs table + trigger function (generic)

3. `00002_portfolio_core.sql`
   - portfolio.portfolios, sites, buildings, floors, spaces, leases
   - PostGIS on sites.location
   - indexes
   - RLS with can_access_site()
   - materialized view for site occupancy

4. `00003_graphql_setup.sql`
   - Grant usage, comment with @graphql
   - Example custom function `create_organization`
   - Verify endpoint

5. `00004_scheduler_setup.sql`
   - Enable cron, create job to call health check edge function
   - Example functions placeholders

6. `00005_storage.sql`
   - buckets: avatars, site-files, floorplans
   - storage RLS

### Edge Functions (Phase 0)

- `functions/graphql-playground` - serve GraphiQL UI for testing (optional)
- `functions/health` - returns cron status, for pg_cron ping

### Seed

- Demo org "Acme Property Management"
- 1 portfolio "Downtown Portfolio"
- 2 sites: "100 Main St Tower" (office, 20 floors), "Westfield Mall" (retail)
- 3 users with different roles
- Sample buildings/floors/spaces

### Validation

- GraphQL query from docs returns only allowed sites (test with 2 JWTs)
- Realtime works on sites table
- pg_cron job_run_details shows success

---

## Phase 1: Building Operations (Week 1-2)

**Goal:** Property managers can track assets, work orders, inspections

Tables: ops.asset_categories, assets, work_order_templates, work_orders, checklists, inspections, inventory

Features:
- QR code generation (Edge Function using qrcode lib, stores SVG/PNG in storage)
- Work order lifecycle: open -> in_progress -> completed -> verified
- SLA calculation: `sla_due_at = created_at + (priority hours)`
- Preventive Maintenance: template + cron `generate_pm_work_orders()` creates WOs when due
- Realtime: engineers see new WOs instantly

Crons:
- */15 * SLA breach
- 0 2 * * * PM generation

GraphQL: custom mutations `ops.create_work_order`, `ops.complete_work_order`

---

## Phase 2: Tenant Experience + Visitor (Week 2-3)

**Goal:** Tenants interact, visitors managed

Tables: tenant.tenants, contacts, service_requests, reservations, announcements; visitor.* tables

Key linking:
- service_request -> creates work_order automatically (trigger or edge function)
- reservation conflicts check (function `check_reservation_conflict`)

Visitor flow:
1. Tenant preregisters visitor via GraphQL -> creates visit + pass with QR
2. Edge Function `send-visitor-pass-email` sends QR
3. Lobby kiosk scans QR -> updates `checked_in_at` + realtime notify host + access log

Crons: visitor pass cleanup, reservation reminder (24h before -> notification)

---

## Phase 3: Compliance & Vendor (Week 3-4)

Tables: vendor.vendors, contracts, cois, compliance_rules, compliance_status

Complex logic:
- `vendor.check_coi_expirations()` updates status, inserts notifications
- Compliance dashboard = materialized view joining vendors + cois + rules + status
- Document expiry alerts 30/60/90 days

Storage: COIs PDFs private, only org admins + compliance role

Edge Functions:
- `compliance-daily-check` (scheduled) does checks + sends emails via Resend
- `parse-coi-pdf` (optional future) OCR to extract expiry automatically

---

## Phase 4: Analytics & Portfolio (Week 4-5)

Tables/views: metrics.daily_site_stats, materialized KPIs

Jobs:
- Daily 3am rollup: `metrics.rollup_daily_stats()`
- Occupancy: leases active / total spaces
- Asset Health: avg age, failures
- SLA metrics: % breached, avg time to complete
- Vendor compliance %

GraphQL: expose metrics views, use aggregates (pg_graphql supports aggregates via `@graphql` directives? May need custom function returning jsonb for complex KPIs)

Scheduled reports:
- Edge Function `generate-monthly-report` creates PDF (jsPDF) or CSV, stores in storage, emails to portfolio managers
- Cron weekly Monday 7am

---

## Phase 5: Hardening (Week 5-6)

- RLS tests (automated)
- Search: pg_trgm indexes + function `search_sites(query)` -> GraphQL
- Audit logs retention + archive to storage
- Rate limiting Edge Function gateway if needed
- Documentation for frontend dev: Postman collection + GraphQL examples + Realtime subscriptions
- CI/CD: GitHub Actions deploying migrations via `supabase db push` and functions via `supabase functions deploy`

---

## What Frontend Dev Gets After Phase 0

1. **Supabase URL + Anon Key**
2. **GraphQL endpoint + docs**
3. **Sample queries file** (`docs/graphql-examples.md`)
4. **Auth flow** - email/password + Google OAuth (already Supabase Auth)
5. **Realtime channels** to subscribe
6. **Storage bucket structure**
7. **RBAC roles** list for UI gating

They can start building Portfolio/Sites UI immediately while you build remaining domains.

## Decisions Needed Now Before Coding

1. **Schemas:** Use separate schemas (recommended) or public with prefixes?
2. **Site hierarchy:** Site->Building->Floor->Space mandatory, or flexible?
3. **Tenant login:** Should tenant contacts be real auth.users or just records?
4. **Vendor login:** MVP without vendor login okay?
5. **PostGIS:** Need map features now or later?
6. **Billing:** Stripe integration needed now or defer?

Reply with answers + `approve architecture` and I will start building Phase 0 migrations + scaffold full Supabase project structure ready to `supabase start`.
