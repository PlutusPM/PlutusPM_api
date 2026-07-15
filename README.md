# Commercial Real Estate SaaS — Supabase Backend (Phase 0 Built ✅)

**Stack:** Supabase Postgres + pg_graphql + pg_cron + pg_net + PostGIS + Edge Functions
**Architecture:** Portfolio → Sites → Everything on Site (multi-tenant, RLS-secured)
**Status:** Phase 0 Core Complete — Ready to `supabase start` or `db push`

---

## What was built (you approved architecture, now it's coded)

### Migrations (6 files - ready to deploy)

| File | Purpose |
|------|---------|
| `00000_extensions.sql` | pg_graphql, postgis, pg_trgm, ltree, pg_cron, pg_net + 6 schemas |
| `00001_platform.sql` | orgs, profiles, memberships, RBAC helpers (`can_access_site`, `is_org_admin`), audit_logs, notifications, `create_organization()` mutation |
| `00002_portfolio_core.sql` | **CENTER:** portfolios, sites (PostGIS + lat/lng sync), buildings, floors, spaces, leases, search + nearby functions, `create_site_full()` |
| `00003_domain_schemas.sql` | **5 Domains:** ops (assets, work_orders, templates), tenant (tenants, service_requests, reservations), visitor (visitors, visits, access_logs), vendor (vendors, contracts, cois, compliance_status), metrics (daily_site_stats) |
| `00004_graphql_scheduler.sql` | GraphQL mutations (`createWorkOrder`, `completeWorkOrder`, `registerVisitor`, `createServiceRequest`), **Scheduler:** 6 pg_cron jobs (SLA every 15m, PM daily 2am, COI hourly, metrics 3am, cleanup 4am, leases Mon 9am) |
| `00005_storage.sql` | 7 buckets: avatars (public), site-files, floorplans, coi-documents, contract-documents, visitor-photos, work-order-attachments + RLS using `can_access_site()` |
| `00006_seed_demo.sql` | Demo org "Demo CRE Management Co", portfolio "Downtown Portfolio", 2 sites (100 Main Tower + Westfield Mall), buildings, floors, spaces, assets, PM templates, vendors, tenant |

### Edge Functions (4)

- `health` — heartbeat + cron status at `/functions/v1/health`
- `compliance-daily-check` — **Scheduled 9am** via `config.toml` + pg_cron, checks COI expiry, leases, SLA, metrics, sends Slack/Resend notifications
- `generate-qr` — Asset QR generation, uploads to `site-files/{org}/{site}/assets/{asset}/qr-*`, returns signed URL
- `send-visitor-pass` — Visitor pass email with QR via Resend + host notification

### Docs (for your frontend dev)

- `docs/FRONTEND_GUIDE_FOR_DEV.md` — connection, auth, GraphQL client, Realtime, Storage paths, RBAC UI gating
- `docs/graphql-examples.md` — 10 copy/paste queries for all domains
- `ARCHITECTURE.md` — full plan
- `architecture/diagrams/data-model.html` — interactive ER visual
- `architecture/diagrams/platform-overview.png` — isometric overview

### Config

- `supabase/config.toml` — local supabase start config, GraphQL schemas, scheduled functions
- `.env.example` — all keys needed
- `.gitignore`

---

## Quick Start (Local)

```bash
# 1. Install Supabase CLI
brew install supabase/tap/supabase
# or npm i -g supabase

# 2. Start local Supabase (includes Postgres, GraphQL, Realtime, Storage, pg_cron)
supabase start

# This outputs:
# API URL: http://127.0.0.1:54321
# GraphQL URL: http://127.0.0.1:54321/graphql/v1
# anon key, service_role key

# 3. Apply migrations (already auto-applied on start, but if pushing to cloud)
supabase db push
# or supabase migration up

# 4. Test GraphQL
# Open http://127.0.0.1:54323 (Studio) -> SQL Editor -> run:
# select graphql.rebuild_schema();

# Test via curl:
curl -X POST http://127.0.0.1:54321/graphql/v1 \
  -H "apikey: <anon>" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ portfolioSitesCollection { edges { node { id name } } } }"}'

# 5. Create a user (via Studio Auth or API), then run seed:
# In SQL Editor, run content of supabase/migrations/00006_seed_demo.sql
# (it auto-detects first auth user, creates demo data)

# 6. Serve functions locally
supabase functions serve --env-file .env.local --debug

# 7. Deploy to cloud (when ready)
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase functions deploy
supabase secrets set RESEND_API_KEY=re_xxx SLACK_WEBHOOK_URL=https://...
```

---

## Deploy to Supabase Cloud

1. Create project at https://supabase.com/dashboard
2. Go to Settings > API, copy URL + anon + service_role
3. Create `.env.local` from `.env.example`
4. Link:

```bash
supabase link --project-ref abcdefgh
supabase db push
supabase functions deploy health --project-ref abcdefgh
supabase functions deploy compliance-daily-check
supabase functions deploy generate-qr
supabase functions deploy send-visitor-pass
supabase secrets set RESEND_API_KEY=... SLACK_WEBHOOK_URL=...
```

5. Enable extensions in Dashboard > Database > Extensions if needed (pg_cron, postgis, pg_graphql already enabled on paid projects)

6. Verify cron jobs:

```sql
select * from cron.job;
select * from cron.job_run_details order by start_time desc limit 20;
```

---

## GraphQL Endpoint (Native Supabase)

No custom server needed. Uses `pg_graphql` extension.

**URL:** `https://<project>.supabase.co/graphql/v1`  
**Headers:**
```
apikey: <anon_key>
Authorization: Bearer <user_jwt>  // from supabase.auth.getSession()
```

### Sample Query (Portfolio → Sites → Assets)

```graphql
query MyPortfolio {
  platformOrganizationsCollection {
    edges { node { id name slug } }
  }
  portfolioPortfoliosCollection {
    edges {
      node {
        id name
        portfolioSitesCollection {
          edges {
            node {
              id name address: addressLine1 city type status
              opsAssetsCollection(filter: {status: {eq: active}}) {
                edges { node { id name qrCode criticality } }
              }
              opsWorkOrdersCollection(filter: {status: {neq: completed}}, first: 5) {
                edges { node { id title priority slaDueAt } }
              }
            }
          }
        }
      }
    }
  }
}
```

### Mutations (Business Logic)

```graphql
mutation CreateWO($siteId: UUID!, $title: String!) {
  opsCreateWorkOrder(input: {pSiteId: $siteId, pTitle: $title, pDescription: "Fix HVAC"}) {
    id title status slaDueAt
  }
}

mutation RegisterVisitor($siteId: UUID!, $name: String!, $email: String!) {
  visitorRegisterVisitor(input: {pSiteId: $siteId, pName: $name, pEmail: $email, pPurpose: "Meeting"}) {
    id qrCode status scheduledAt
  }
}
```

All RLS enforced — user only sees sites in `memberships.site_ids`.

---

## Scheduler - How It Works

**Chosen:** `pg_cron` (DB cron) + `pg_net` (HTTP) + Scheduled Edge Functions

| Job | Schedule | What |
|-----|----------|------|
| check-sla-breaches | */15 * * * * | WO where `sla_due_at < now()` → status overdue + notification |
| generate-pm-work-orders | 0 2 * * * | Loops `work_order_templates` where `next_due_at <= now()` → creates WOs, updates next_due |
| check-coi-expiration | 0 8-18 * * * | COIs expiring 30d → `expiring`, < today → `expired`, updates `compliance_status`, notification |
| rollup-daily-metrics | 0 3 * * * | `metrics.rollup_daily_stats(yesterday)` → `daily_site_stats` |
| cleanup-expired-visits | 0 4 * * * | Delete old visits + read notifications >90d |
| lease-expiration-check | 0 9 * * 1 | Leases ending 30d → notification |
| compliance-daily-check (Edge) | 0 9 * * * | Config.toml scheduled, calls same logic + Resend/Slack |

Monitor:
```sql
select jobname, schedule, active from cron.job;
select * from cron.job_run_details where status='failed' order by start_time desc;
select * from extensions.net._http_response; -- pg_net responses
```

---

## RBAC & Security (Critical)

- Every table has `enable row level security`
- All policies use `platform.can_access_site(site_id)` or `platform.is_org_member(org_id)`
- Helper `platform.can_access_site()` is `SECURITY DEFINER` — checks memberships
- `site_ids = null` in memberships means "all sites in org" (owner/admin)
- Super admin flag in `profiles.is_super_admin` bypasses

Roles: `owner, admin, portfolio_manager, site_manager, building_engineer, security, tenant_admin, tenant_user, vendor, auditor`

**Frontend never gets service_role key.** GraphQL respects RLS automatically.

---

## Storage Buckets (7)

```
avatars/{user_id}/avatar.png  (public)
site-files/{org_id}/{site_id}/assets/{asset_id}/...
floorplans/{org_id}/{site_id}/{building_id}/{floor_id}.pdf
coi-documents/{org_id}/{vendor_id}/{coi_id}.pdf
contract-documents/{org_id}/{vendor_id}/{contract_id}.pdf
visitor-photos/{org_id}/{site_id}/{visitor_id}.jpg
work-order-attachments/{org_id}/{site_id}/{work_order_id}/{file}
```

RLS via folder path parsing: `platform.is_org_member(folder[1]::uuid) && can_access_site(folder[2]::uuid)`

---

## What Your Frontend Dev Gets

Give them:
1. `SUPABASE_URL` + `ANON_KEY` (from `.env`)
2. `docs/FRONTEND_GUIDE_FOR_DEV.md`
3. `docs/graphql-examples.md`
4. This README's GraphQL section

They can build:
- Auth (email + Google) via `supabase.auth`
- Site selector (`portfolioSitesCollection` RLS auto-filters)
- Work Orders dashboard + Realtime subscription
- Visitor registration + QR display
- Asset list + QR generation (calls `generate-qr` function)

---

## Next Phases (Future)

- **Phase 1:** Full Building Ops UI + Inspections + Checklists + Inventory
- **Phase 2:** Tenant portal + Reservations + Service Request → WO auto-link
- **Phase 3:** Vendor Compliance dashboard + COI PDF parsing (OCR edge function)
- **Phase 4:** Portfolio Analytics materialized views + Scheduled Reports (PDF via Edge Function)
- **Phase 5:** Workflow engine + Search (pg_trgm) + Audit log archive

---

## Test Locally (No Frontend Needed)

```sql
-- 1. Create user via Studio Auth UI, then:
select auth.uid(); -- should return user id when logged in via SQL Editor with JWT

-- 2. Create org via GraphQL mutation or function:
select platform.create_organization('My Company', 'my-company');

-- 3. Run seed
\i supabase/migrations/00006_seed_demo.sql

-- 4. Check RLS
select * from portfolio.sites; -- should only see demo sites

-- 5. Test mutations
select ops.create_work_order(
  (select id from portfolio.sites limit 1),
  'Fix lobby lights',
  'Lights flickering in lobby',
  null, null, 'high'::ops.priority_level, 'corrective'::ops.work_order_type
);

-- 6. Search
select * from portfolio.search_sites('Main', null, 10);

-- 7. Nearby (need lat/lng set)
select * from portfolio.nearby_sites(30.2672, -97.7431, 5000, 10);
```

---

## Need Customization?

Tell me your specific SaaS needs and I'll tailor tables. For now Phase 0 covers:
- Multi-tenant orgs
- Portfolio → Site → Building → Floor → Space hierarchy (models everything on site as you requested)
- Assets + Work Orders + Vendors + Visitors + Tenants scaffolds
- GraphQL + Scheduler + Storage + RBAC ready

Frontend can start NOW.

Want me to generate TypeScript types from DB? Run: `supabase gen types typescript --local > types/supabase.ts`
