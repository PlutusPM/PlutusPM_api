# Setup Instructions - PlutusPM CRE SaaS Supabase Backend (Complete with Docker)

**Status:** All Phases 0-4 Built - 15 Migrations + 11 Edge Functions + 7 Buckets + 10 Cron Jobs  
**Prerequisites:** Docker Desktop + Supabase CLI + Node 18+

This doc is the detailed Docker local setup. Quick version also in README.md "How to Run Locally with Docker".

---

## Prerequisites - Docker

Supabase CLI runs entire stack via Docker containers: Postgres 15 + PostgREST + GoTrue Auth + Realtime + Storage + Kong + pg_graphql + pg_cron + Inbucket + Studio.

### 1. Install Docker Desktop (Required)

- **Mac:** https://www.docker.com/products/docker-desktop/ → Install → Open Docker Desktop → Wait until whale icon shows "Running" green
- **Windows:** Same link + enable WSL2 backend in Settings → Resources → WSL Integration → Enable Ubuntu, Restart Docker Desktop
- **Linux:** 
  ```bash
  sudo apt-get update
  sudo apt-get install docker.io docker-compose -y
  sudo systemctl start docker
  sudo systemctl enable docker
  sudo usermod -aG docker $USER
  # Log out and log back in for group change
  ```
- Verify:
  ```bash
  docker --version # Docker version 24+ should show
  docker ps # Should list containers or empty list, not error "Cannot connect to Docker daemon"
  ```
  If `Cannot connect`, open Docker Desktop app and wait.

### 2. Install Supabase CLI

- **Mac (brew - recommended):** `brew install supabase/tap/supabase`
- **All (npm):** `npm install -g supabase`
- **Windows (scoop):** `scoop bucket add supabase https://github.com/supabase/scoop-bucket.git` + `scoop install supabase`
- Verify: `supabase --version` → v1.x+

### 3. Git + Node

- `git --version` + `node --version` ≥ 18 + `npm --version`

---

## 1. Clone & Check

```bash
git clone https://github.com/EmmanuelMat/PlutusPM.git
cd PlutusPM

# Verify built files
ls supabase/migrations/ | wc -l # 15
# 00000_extensions.sql ... 00015_phase4_seed.sql

ls supabase/functions/ 
# 11 folders: amenity-booking, compliance-daily-check, compliance-report, engineering-report, export-data, generate-qr, health, parse-coi-pdf, scheduled-reports, send-visitor-pass, visitor-kiosk

cat .env.example # for reference
cp .env.example .env.local
# Edit .env.local optionally for external services:
# RESEND_API_KEY=re_xxx (for visitor pass emails, reports)
# SLACK_WEBHOOK_URL=https://hooks.slack.com/...
# GOOGLE_CLIENT_ID, GITHUB_CLIENT_ID etc for OAuth if needed
# For local supabase start, SUPABASE_URL/ANON_KEY are auto-printed, not needed in .env
```

---

## 2. Start Supabase Stack (Docker)

```bash
# First time pulls images ~1-2 GB, takes 2-3 mins
supabase start

# Expected success output (keys censored):
# Started supabase local development setup.
#          API URL: http://127.0.0.1:54321
#      GraphQL URL: http://127.0.0.1:54321/graphql/v1
#           DB URL: postgresql://postgres:postgres@127.0.0.1:54322/postgres
#       Studio URL: http://127.0.0.1:54323
#     Inbucket URL: http://127.0.0.1:54324
#       JWT secret: super-secret-jwt-token-with-at-least-32-characters-long
#         anon key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
# service_role key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
# (all containers started in Docker)

# Check status anytime
supabase status
# API URL, GraphQL URL, DB URL, Studio URL, Inbucket URL, anon key, service_role key
# Save anon key + service_role key to clipboard or env file

# If error:
# - "Cannot connect to Docker daemon" → Open Docker Desktop, wait green, retry
# - "Port 54321 already in use" → supabase stop or lsof -ti:54321 | xargs kill -9, or change ports in supabase/config.toml [api] port = 54331 etc
# - Docker out of space → Docker Desktop → Settings → Resources → Clean/Purge data, or docker system prune
```

**What Docker containers started?** Run `docker ps` → you should see ~7 containers: supabase_db, supabase_rest, supabase_auth, supabase_realtime, supabase_storage, supabase_kong, supabase_studio, supabase_inbucket

---

## 3. Verify Migrations Applied

`supabase start` auto-applies all migrations in `supabase/migrations/` in order.

```bash
# List migration status
supabase migration list
# Should show:
# Local            | Remote | Time (UTC)
# 00000_extensions |        | ...
# 00001_platform
# ...
# 00015_phase4_seed

# If you want to force reset (drops DB, reapplies every migration, rebuilds GraphQL,
# and auto-runs supabase/seed.sql):
supabase db reset

# Quick check via SQL - should be non-zero once db reset finishes, seed.sql already ran
supabase db execute --local "select count(*) from portfolio.sites;"
```

---

## 4. Auth users + demo data are already seeded

`supabase db reset` automatically runs `supabase/seed.sql` after migrations, which creates four ready-to-log-in accounts (password `password123` for all) plus a fully populated demo org - two sites, tenants, work orders, vendors, visitors, billing, campaigns, KB articles, everything. There is no manual seeding step.

| Email | Role |
|---|---|
| `demo@cre.local` | Org owner |
| `manager2@cre.local` | Site manager |
| `tenant@cre.local` | Tenant portal admin |
| `tenant2@cre.local` | Tenant portal contact |

See `docs/SEED_DATA.md` for the full breakdown of what's seeded, why the old `00006`/`00008`/`00011`/`00013`/`00015` "seed" migrations are dead code on a fresh reset, and how to extend the seed data.

To get a JWT for Postman/GraphQL testing, sign in with one of the accounts above:

```bash
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..." # from supabase status

curl -X POST http://127.0.0.1:54321/auth/v1/token?grant_type=password \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email": "demo@cre.local", "password": "password123"}'

# Returns: access_token (JWT), user object with id
```

Or via Postman: import `postman/PlutusPM.postman_collection.json` + `postman/PlutusPM.postman_environment.json`, set `supabaseUrl`/`anonKey` in the environment, and run `0. Auth > Sign In - Get JWT` (auto-saves `userJwt`/`userId`).

**Verify seed data landed:**

```sql
select 'orgs' as tbl, count(*) from platform.organizations
union all select 'sites', count(*) from portfolio.sites
union all select 'tenants', count(*) from tenant.tenants
union all select 'work_orders', count(*) from ops.work_orders
union all select 'vendors', count(*) from vendor.vendors
union all select 'visitors', count(*) from visitor.visitors
union all select 'billing_requests', count(*) from tenant.billing_requests
union all select 'kb_articles', count(*) from platform.kb_articles;
-- orgs 1, sites 2, tenants 6, work_orders 10, vendors 4, visitors 4, billing_requests 4, kb_articles 5
```

---

## 6. Test GraphQL (pg_graphql Native)

No extra server - endpoint auto at `/graphql/v1`

**Via cURL:**

```bash
ANON_KEY="eyJ..." # from supabase status
USER_JWT="eyJ..." # from Sign Up/Sign In access_token

curl -X POST http://127.0.0.1:54321/graphql/v1 \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "query { portfolioSitesCollection { edges { node { id name city type status } } } }"
  }'

# Should return 2 sites because RLS filters via memberships (you belong to the meridian-commercial org)
```

**Via GraphiQL / Altair:**

- Open https://graphiql-online.com/ or https://altairgraphql.dev/ or https://studio.apollographql.com/sandbox
- Endpoint URL: `http://127.0.0.1:54321/graphql/v1`
- Headers: 
  - `apikey: <anonKey>`
  - `Authorization: Bearer <userJwt>`
- Paste query from `docs/graphql-examples.md` (10 collections full)

**Via Postman (recommended - we have collection):**

- Import collection + environment
- Ensure env `supabaseUrl` = `http://127.0.0.1:54321`, `anonKey` = from status, `userJwt` auto-filled after Sign In
- Run folder `0. Setup & Health > GraphQL - Introspection Test` → should return sites
- Then try any from folders 2-7: Portfolio & Sites, Building Ops, Tenant, Visitor, Compliance, Analytics

---

## 7. Test Edge Functions Locally

Edge Functions are Deno, bundled with Supabase CLI.

**Serve all functions (keep this terminal running):**

```bash
# In separate terminal, from repo root:
supabase functions serve --env-file .env.local --debug

# Expected output:
# Serving functions on http://127.0.0.1:54321/functions/v1/<name>
# health: http://127.0.0.1:54321/functions/v1/health
# compliance-daily-check: ...
# ... 11 functions total
#   health
#   compliance-daily-check (scheduled 0 9 * * *)
#   generate-qr
#   send-visitor-pass
#   engineering-report
#   visitor-kiosk (public CORS)
#   amenity-booking
#   parse-coi-pdf
#   compliance-report
#   scheduled-reports (scheduled 0 7 * * *)
#   export-data
```

**Test each (in another terminal):**

```bash
ANON_KEY="eyJ..."
USER_JWT="eyJ..."
SERVICE_KEY="eyJ..." # service_role from supabase status

# 1. Health (public)
curl http://127.0.0.1:54321/functions/v1/health -H "apikey: $ANON_KEY"

# 2. Generate QR for first asset
ASSET_ID=$(supabase db execute --local "select id from ops.assets limit 1;" --output json | jq -r '.result[0].id' 2>/dev/null || echo "get-from-studio")
curl -X POST http://127.0.0.1:54321/functions/v1/generate-qr \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d "{\"asset_id\": \"$ASSET_ID\", \"format\": \"svg\"}"

# 3. Visitor Kiosk - Stats (public CORS for lobby iPad)
SITE_ID=$(supabase db execute --local "select id from portfolio.sites limit 1;" --output json | jq -r '.result[0].id' 2>/dev/null || echo "your-site-id")
curl -X POST http://127.0.0.1:54321/functions/v1/visitor-kiosk \
  -H "Content-Type: application/json" \
  -d "{\"action\": \"stats\", \"site_id\": \"$SITE_ID\"}"

# 4. Amenity Booking - Check Conflict (needs user JWT RLS)
SPACE_ID=$(supabase db execute --local "select id from portfolio.spaces where type='amenity' limit 1;" --output json | jq -r '.result[0].id' 2>/dev/null || echo "your-space-id")
curl -X POST http://127.0.0.1:54321/functions/v1/amenity-booking \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d "{\"action\": \"check_conflict\", \"space_id\": \"$SPACE_ID\", \"start_time\": \"2024-07-20T09:00:00Z\", \"end_time\": \"2024-07-20T10:00:00Z\"}"

# 5. Compliance Report - CSV download (needs user JWT)
curl -X POST http://127.0.0.1:54321/functions/v1/compliance-report \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d "{\"site_id\": \"$SITE_ID\", \"format\": \"csv\"}"

# 6. Scheduled Reports - Run Due (needs service_role)
curl -X POST http://127.0.0.1:54321/functions/v1/scheduled-reports \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'

# 7. Export Data - Work Orders CSV (needs user JWT RLS)
curl -X POST http://127.0.0.1:54321/functions/v1/export-data \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d "{\"table\": \"work_orders\", \"site_id\": \"$SITE_ID\", \"format\": \"csv\", \"limit\": 100}"
```

**Env for external services (Resend, Slack):**

For functions needing email/Slack (send-visitor-pass, compliance-daily-check, scheduled-reports), create `.env.local`:

```
RESEND_API_KEY=re_xxx_your_resend_key
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_SERVICE_ROLE_KEY=your-service-role-from-status
```

Then `supabase functions serve --env-file .env.local --debug` loads them. In cloud, set via `supabase secrets set`.

---

## 8. Test Storage

Storage uses RLS via folder path `{org_id}/{site_id}/...`

**Via Postman Collection:**

- Folder `9. Storage` → Upload Avatar (public) → Upload Site File (private org/site path) → Upload COI Document → Get Signed URL

**Via JS Client (Node or Browser):**

```javascript
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(
  'http://127.0.0.1:54321',
  'ANON_KEY',
  { auth: { persistSession: true } }
)

await supabase.auth.signInWithPassword({ email: 'demo@cre.local', password: 'password123' })

// Get org/site IDs
const { data: org } = await supabase.schema('platform').from('organizations').select('id').limit(1).single()
const { data: site } = await supabase.schema('portfolio').from('sites').select('id').eq('org_id', org.id).limit(1).single()

const file = new File(['hello world'], 'test.txt', { type: 'text/plain' })
const path = `${org.id}/${site.id}/test-folder/test.txt`

// Private bucket site-files, RLS checks is_org_member(org) && can_access_site(site)
const { data, error } = await supabase.storage.from('site-files').upload(path, file, { upsert: true })
console.log(data, error)

if (!error) {
  const { data: signed } = await supabase.storage.from('site-files').createSignedUrl(path, 3600)
  console.log('Signed URL 1h:', signed.signedUrl)
}
```

Path must be `{org_id}/{site_id}/...` else RLS denies.

---

## 9. Test Cron Jobs & Scheduler

Cron jobs run inside Postgres via pg_cron. Locally they auto-fire if supabase start with cron enabled (default).

**Check cron status:**

```sql
-- In Studio SQL Editor → New Query:
select jobname, schedule, active, command, database from cron.job order by jobname;
-- Should list 10+ jobs: check-sla-breaches, generate-pm-work-orders, check-coi-expiration, rollup-daily-metrics, cleanup-expired-visits, lease-expiration-check, check-low-stock, expire-visitor-passes, evaluate-vendor-compliance, check-contract-expirations, check-document-expirations

select * from cron.job_run_details order by start_time desc limit 20;
-- Shows last runs success/failed, start_time, end_time, return_message
```

**Manually trigger for testing (instead of waiting for schedule):**

```sql
-- SLA breach detection:
select ops.check_sla_breaches();

-- Generate PM work orders from templates due:
select ops.generate_pm_work_orders();

-- COI expiration:
select vendor.check_coi_expirations();

-- Daily metrics enhanced rollup + portfolio rollup:
select metrics.rollup_daily_stats_enhanced(current_date - 1);

-- Low stock alert:
select ops.check_low_stock();
insert into platform.notifications (org_id, site_id, type, title, body, payload)
select org_id, site_id, 'system', 'Low stock: ' || (select name from ops.inventory_items where id = inventory_item_id), 'Qty ' || current_qty, jsonb_build_object('item', inventory_item_id) from ops.check_low_stock();

-- Vendor compliance evaluate all:
select vendor.evaluate_all_compliance();

-- Contract expirations:
select vendor.check_contract_expirations();

-- Portfolio stats:
select metrics.rollup_portfolio_daily_stats(current_date - 1);

-- Site KPIs:
select metrics.get_site_kpis((select id from portfolio.sites limit 1));
select metrics.get_portfolio_kpis((select id from portfolio.portfolios limit 1));
```

**Test scheduled Edge Functions via pg_net (simulates pg_cron http_post):**

```sql
-- Inside Docker Postgres, host.docker.internal reaches host's 54321
select net.http_post(
  url := 'http://host.docker.internal:54321/functions/v1/compliance-daily-check',
  headers := '{"Content-Type": "application/json"}'::jsonb
) as request_id;

-- Check response:
select id, status_code, content, created from net._http_response order by created desc limit 5;
```

---

## 10. Generate TypeScript Types

After migrations applied and supabase running:

```bash
# Local types (all schemas we expose)
supabase gen types typescript --local --schema public,platform,portfolio,ops,tenant,visitor,vendor,metrics,storage,graphql > types/supabase-generated.ts

# Cloud project types
supabase gen types typescript --project-id your-project-ref --schema public,platform,portfolio,ops,tenant,visitor,vendor,metrics > types/supabase-cloud.ts

# We already provide manual comprehensive types in types/database.ts (covers 6 schemas with custom logic, more detailed than auto-generated)
# The generated file is supplemental
```

**Usage in frontend (Next.js example):**

```typescript
import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/database' // or supabase-generated

const supabase = createClient<Database>(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
)

// Typed:
const { data: sites } = await supabase
  .schema('portfolio')
  .from('sites')
  .select('id, name, city')
  .eq('org_id', orgId)
```

---

## 11. Stop, Reset, Logs, Troubleshooting

```bash
# Stop containers (keeps data volume for next start)
supabase stop

# Stop and delete data (fresh next start, need to re-seed)
supabase stop --no-backup

# Reset DB only (drops and reapplies migrations, keeps containers running, fast).
# supabase/seed.sql runs automatically at the end - no manual re-seeding needed.
supabase db reset

# Logs
supabase logs db        # Postgres logs
supabase logs rest      # PostgREST
supabase logs auth      # GoTrue Auth
supabase logs storage   # Storage API
supabase logs realtime  # Realtime
supabase logs functions # Edge Functions logs when serving

# Status
supabase status

# Inspect Docker
docker ps # list containers
docker logs supabase_db_PlutusPM # specific container logs
docker stats # resource usage
```

### Common Issues

| Issue | Fix |
|-------|-----|
| `Cannot connect to the Docker daemon` | Open Docker Desktop app, wait green Running, retry `supabase start` |
| `Port 54321 already in use` | `supabase stop` or `lsof -ti:54321 | xargs kill -9` or edit `supabase/config.toml` [api] port = 54331 etc then restart |
| `Docker out of disk space` | Docker Desktop → Settings → Resources → Clean/Purge data, or `docker system prune -a` (removes unused images) |
| `supabase start` hangs at "Starting containers" | Check Docker has 4GB+ RAM allocated Settings → Resources → Memory 4GB+, `supabase stop --no-backup` then start again |
| `pg_cron extension not found` | Run `supabase db reset`, ensure 00000_extensions.sql creates pg_cron with schema pg_catalog, cloud projects enable via Dashboard Database Extensions |
| `Storage upload 403 RLS` | Path must be `{org_id}/{site_id}/...` with valid UUIDs you belong to via memberships, test `select platform.can_access_site('site-id')` returns true for your JWT user, check storage foldername parsing org/site |
| `GraphQL returns empty []` | RLS: ensure memberships entry exists site_ids null (all sites) or containing that site, Studio SQL `select * from platform.memberships where user_id = auth.uid()` |
| `Edge Functions 401 verify_jwt` | config.toml verify_jwt false for health/visitor-kiosk/compliance-daily-check/scheduled-reports (public), true for others (needs Authorization Bearer userJwt). For service_role functions (parse-coi-pdf, scheduled-reports), need service_role key not anon |
| `Supabase CLI command not found` | Install via brew or npm -g, ensure PATH includes, `which supabase` |
| `Inbucket email not receiving` | Check Inbucket URL http://127.0.0.1:54324 → shows test emails if auth email confirmations enabled, but we disabled confirmations for local (auth.email.enable_confirmations false) so sign up auto confirms |
| `Functions env RESEND_API_KEY not loaded` | Create `.env.local` with keys, serve with `--env-file .env.local`, in cloud set via `supabase secrets set` |

---

## Cloud Deployment

See README.md Deploy to Supabase Cloud section (link project, db push 15 migrations, functions deploy 11, secrets set).

---

## Next Steps

- Frontend dev: Give them `types/` + `postman/` + `docs/FRONTEND_GUIDE_FOR_DEV.md` + `docs/graphql-examples.md`
- Test via Postman collection import + environment
- Read docs/CAPABILITY_COVERAGE.md for 94% gap analysis
- Read docs/PHASE1-4 for domain details
- Architecture diagrams: `architecture/diagrams/data-model.html` interactive + `platform-overview.png` isometric

**Repo ready at https://github.com/EmmanuelMat/PlutusPM - 15 migrations, 11 functions, 7 buckets, 10 crons, 94% coverage, all local Docker setup above.**
