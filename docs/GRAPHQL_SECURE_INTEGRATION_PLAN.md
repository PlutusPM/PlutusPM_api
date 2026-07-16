# GraphQL Secure Integration Plan - PlutusPM CRE SaaS

**Goal:** Migrate frontend from mock `plutusData` + mixed REST to **pure GraphQL** for all data fetching, following **GraphQL Best Practices** + **OWASP Top 10** (2021 + GraphQL Top 10).

**Scope:** Both repos - Backend (`PlutusPM_api`) + Frontend (`PlutusPM_dashboard`)
**Branches:** 
- Backend: `feature/graphql-owasp-integration` (this branch)
- Frontend: `feature/graphql-integration` in dashboard repo
**Date:** 2025-07-16
**Status:** Planning → Execution in feature branches (NOT main)

---

## 1. Current State Audit

### Backend (PlutusPM_api)

- **15 migrations** (~6.5k SQL) - 6 schemas (platform, portfolio, ops, tenant, visitor, vendor, metrics), 40+ tables, RLS on every table via `can_access_site(site_id)` + `is_org_member(org_id)`, 10 cron jobs, 11 Edge Functions, 7 Buckets, PostGIS + pg_trgm
- **GraphQL:** pg_graphql native at `/graphql/v1`, exposed via `api.schemas = [..., platform, portfolio, ops, tenant, visitor, vendor, metrics]` + `extra_search_path` includes custom schemas, `inflect_names: true, introspection: true` enabled via migration 00017, SELECT grants to anon/authenticated/service_role, Rebuild + pgrst reload notifications
- **Security Existing:** RLS mandatory, helper SECURITY DEFINER functions, super_admin bypass, audit_logs, notifications, JWT ES256 (new asymmetric), httpOnly cookies via Supabase Auth, service_role never to frontend
- **Gaps for OWASP GraphQL:**
  - Introspection enabled for all schemas (should be **enabled in dev, disabled in prod**)
  - No query depth/complexity limiting, no rate limiting gateway, no persisted queries
  - No field-level security via views hiding sensitive fields (e.g., `stripe_customer_id`, `cost` for tenant role)
  - No Edge Function gateway acting as WAF for GraphQL
  - No explicit OWASP documentation

### Frontend (PlutusPM_dashboard)

- **Stack:** Next.js 16.2.10, React 19, TypeScript 5, Tailwind 4, no `@supabase/supabase-js`, custom `graphqlRequest` + `restRequest` clients using fetch, env vars `NEXT_PUBLIC_SUPABASE_URL`, `GRAPHQL_ENDPOINT`, `REST_ENDPOINT`, `ANON_KEY`
- **Auth:** `auth-actions.ts` uses REST `/auth/v1/token?grant_type=password` with apikey, persists via httpOnly cookies? Actually uses `persistAuthSession` via cookies (good), JWT ES256, refresh token
- **Data Fetching:**
  - `management-context.ts` → REST `platform` profile: memberships, organizations, sites (portfolio) - **Real, wired, compatible**
  - `inspections.ts` → REST `ops` profile: inspections, checklists, assets, profiles, inspection_items - **Real, wired, 100% compatible**
  - `management-tenants.ts`, `tenant-requests.ts`, `tenant-context.ts` → REST `tenant` profile: tenants, service_requests - **Partially wired**
  - **Dashboard, Work Orders, Assets, Vendors, Visitors** → `plutusData` **mock** (`app/_data/plutus.ts`) — 70% of pages still mock, not real
  - GraphQL client exists but rarely used for data, mostly REST
- **Gaps:**
  - No centralized GraphQL data layer, no codegen, no typed queries
  - Mock data means no RLS testing, no real RBAC
  - No Zod validation on inputs
  - No rate limiting, no depth limiting on frontend queries
  - No CSP headers, no secure headers in next.config.ts
  - No error boundaries that hide stack traces
  - No audit logging frontend

---

## 2. Desired State

**Frontend gets ALL data via GraphQL (not REST + mock), with:**

- **Server Components** for data fetching (Next.js App Router) — JWT in httpOnly cookie, never exposed to client JS, server-only
- **Typed GraphQL** via `graphql-codegen` generating types from backend schema (introspection enabled in dev)
- **Persisted Queries** in production — Whitelist allowed queries, reject arbitrary queries to prevent DoS + injection
- **Depth/Complexity/Rate Limiting** — Edge Function `graphql-gateway` acts as WAF: max depth 10, max complexity 1000, max alias 20, rate limit 100 req/min per IP + per user, disable batching
- **Introspection** — Enabled in dev (`introspection: true`), **disabled in prod** (`introspection: false`) via migration that checks ENV
- **Field-Level Security** — Views like `ops.work_orders_public` hide `cost` for tenant role, `vendor.vendors_public` hides `stripe_customer_id`, etc. Use RLS + views
- **Input Validation** — Zod schemas for all mutation inputs (createWorkOrder, registerVisitor, etc)
- **RBAC UI Gating + Backend Enforcement** — Frontend hides buttons based on membership role (owner/admin/site_manager/etc) but backend RLS still enforces via `can_access_site`
- **Secure Auth** — httpOnly, Secure, SameSite=Strict cookies, short JWT expiry 1h, refresh token rotation, CSRF token for cookie auth, no localStorage for tokens
- **No Sensitive Data Exposure** — No service_role key to client, no stack traces in errors, generic error messages
- **Monitoring** — Audit logs `platform.audit_logs`, `vendor.compliance_audit_logs`, Edge Function logs, frontend Sentry or similar (optional)
- **OWASP Top 10 Covered** — See Section 4

---

## 3. GraphQL Best Practices (To Implement)

### A. Schema Design

- **Use connections (edges/node) for pagination** — Already done by pg_graphql (Relay style) — keep
- **Use input objects for mutations** — Already done: `input: {pSiteId, pTitle}` — keep, add Zod validation
- **Versionless schema** — pg_graphql auto-generates from Postgres, no versioning needed, use deprecation via comments if needed
- **inflect_names** — Already enabled: snake_case SQL → camelCase GraphQL (e.g., `site_id` → `siteId`) — keep

### B. Performance

- **Persisted Queries** — In production, frontend sends query ID hash, not full query string, backend Edge Function gateway maps ID → query from whitelist JSON file. Prevents arbitrary query DoS
- **Depth Limiting** — Max depth 10 (e.g., `sites { buildings { floors { spaces { ... } } } }` depth 4, allow up to 10 but not 20+)
- **Complexity Limiting** — Assign cost per field (e.g., collection 10, single 1), max 1000 per query
- **Rate Limiting** — Edge Function gateway: 100 req/min per IP, 60 req/min per user (via JWT sub), sliding window, 429 Too Many Requests
- **Disable Batching** — Or limit batch size to 5 to prevent alias overloading DoS (50 queries in one request)
- **Pagination** — Use `first: 20` default, max 100, never unlimited

### C. Security

- **AuthZ via RLS** — Already implemented: `can_access_site(site_id)` checks `memberships.site_ids` + role. Keep, add tests
- **AuthN via JWT** — httpOnly cookie, Secure, SameSite=Strict, short expiry 3600s, refresh rotation
- **Introspection** — Enable in dev, disable in prod via migration that checks `current_setting('app.env')` or via comment toggle
- **Disable GraphiQL in Prod** — Studio GraphiQL only available locally, not in prod
- **Field-Level Auth** — Use views that omit sensitive columns for low-privilege roles. E.g., `ops.work_orders_tenant_view` without `cost`, `labor_hours` for tenant_user role. Grant SELECT on view to tenant_user, not base table
- **Input Validation** — Zod for all mutations: siteId UUID format, title min 3 max 200 chars, priority enum, etc.

---

## 4. OWASP Top 10 Mitigations - Detailed

### OWASP Top 10 2021 + GraphQL Top 10 Mapping

#### A1: Broken Access Control

**Risk:** User accesses sites/orgs they don't belong to, or deletes org they don't own.

**Mitigation:**

- **Backend (Already Done, Verify):**
  - RLS enabled on EVERY table (check `SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname IN ('platform','portfolio','ops','tenant','visitor','vendor','metrics')` → should be true)
  - Helper `can_access_site(site_id)` checks memberships.site_ids null=all or contains + org_id match + is_super_admin bypass
  - `is_org_admin(org_id)` checks role owner/admin
  - `is_site_manager(site_id)` checks role owner/admin/portfolio_manager/site_manager
  - Policies: `USING (can_access_site(site_id))` for select, `WITH CHECK (can_access_site(site_id))` for insert, `USING (is_site_manager)` for delete
  - No service_role key to frontend (env var only server-side)
  - Test RLS: `sql/test-rls.sql` simulates two users different orgs

- **Frontend (To Implement):**
  - Server Components fetch with JWT from httpOnly cookie, server-side
  - UI gating: Hide "Delete Organization" button if role != owner, hide "Create Work Order" if role tenant_user, but backend still enforces via RLS (defense in depth)
  - `requireManagementContext()` already checks memberships and throws BackendAuthError if no membership → redirect to /sign-in
  - Add `useRole()` hook to check role from memberships for UI gating

**GraphQL Specific:** Field-level access control via views: Tenant should not see `cost` field in work_orders. Create view `work_orders_tenant` without cost column, grant SELECT on view to tenant_user role, not base table. Or use RLS + column-level security.

#### A2: Cryptographic Failures

- **HTTPS Only:** Supabase local uses http for dev, but cloud uses https. Frontend next.config.ts should redirect http to https in prod, HSTS header
- **Secure Cookies:** `persistAuthSession` should set cookies httpOnly, Secure (true in prod, false for localhost), SameSite=Strict, Path=/, Max-Age 3600, with `__Host-` prefix
- **JWT:** ES256 asymmetric (new) more secure than HS256, short expiry 3600s, refresh token rotation enabled in config.toml `enable_refresh_token_rotation = true`
- **No Sensitive Data in URL:** Don't put tokens in query params, use Authorization header + httpOnly cookie
- **Encryption at Rest:** Supabase Postgres encrypts at rest by default (cloud), local dev not needed

#### A3: Injection (SQL, NoSQL, etc)

- **pg_graphql** uses parameterized queries internally, no string concatenation, so SQL injection via GraphQL args is prevented by design
- **But still validate inputs:** Use Zod schemas for all mutation inputs to prevent NoSQL/mass assignment:
  ```typescript
  const createWorkOrderSchema = z.object({
    siteId: z.string().uuid(),
    title: z.string().min(3).max(200),
    priority: z.enum(['low','medium','high','urgent']),
    type: z.enum(['preventive','corrective','inspection','service_request','incident'])
  })
  ```
- **No raw SQL in Edge Functions** that concatenates user input. Use Supabase client with parameterized queries

#### A4: Insecure Design

- **Domain-Driven, Least Privilege:** 6 schemas, each domain owns data, shared platform services, principle of least privilege (tenant_user sees only own spaces, vendor sees only own contracts)
- **Secure by Default:** RLS enabled by default, no table exposed without explicit GRANT, deny by default
- **Threat Modeling:** Documented in this plan, plus `docs/CAPABILITY_COVERAGE.md` gap analysis, plus `ARCHITECTURE.md` with RLS strategy

#### A5: Security Misconfiguration

- **Introspection:** Enable in dev (`introspection: true`), **disable in prod** (`introspection: false`) via migration that checks env or manual toggle before prod deploy. Add comment: `comment on schema public is '@graphql({"introspection": false})';` for prod, true for dev
- **GraphiQL / Playground:** Only available in Studio locally (http://127.0.0.1:54323), not exposed in prod. Ensure `graphql` endpoint not publicly browsable without auth? Actually GraphQL endpoint requires apikey + JWT, so not public
- **CORS:** Supabase CORS handled via config.toml `site_url` + `additional_redirect_urls`, frontend should set CORS only to allowed origins (not *)
- **Secure Headers:** Next.js `next.config.ts` should set:
  ```typescript
  async headers() {
    return [{
      source: '/(.*)',
      headers: [
        { key: 'X-Frame-Options', value: 'DENY' },
        { key: 'X-Content-Type-Options', value: 'nosniff' },
        { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
        { key: 'Content-Security-Policy', value: "default-src 'self'; script-src 'self' 'unsafe-eval' 'unsafe-inline' ..." },
        { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' }
      ]
    }]
  }
  ```
- **Env Vars:** No secrets in code, only via `NEXT_PUBLIC_` prefix for anonKey (public) and server-only for service_role (never NEXT_PUBLIC). Use `.env.local` not committed

#### A6: Vulnerable and Outdated Components

- **Pin Dependencies:** `package-lock.json` committed, use `npm ci` not `npm install` in CI
- **Audit:** `npm audit` in CI, Dependabot alerts enabled in GitHub
- **Keep Updated:** Next.js 16.2.10, React 19, Supabase JS (if used) latest, Deno runtime for Edge Functions latest

#### A7: Identification and Authentication Failures

- **httpOnly Cookies:** Already using `persistAuthSession` via cookies (need to verify httpOnly, Secure, SameSite=Strict, not just regular cookie)
- **Short Expiry:** JWT 3600s (1h) in config.toml `jwt_expiry = 3600`
- **Refresh Rotation:** `enable_refresh_token_rotation = true`, `refresh_token_reuse_interval = 10` in config
- **Lockout:** Supabase Auth has built-in rate limiting for sign-in attempts
- **MFA Ready:** Auth supports MFA via `auth.mfa` config, can enable later
- **No LocalStorage:** Tokens in httpOnly cookies, not localStorage (XSS protection)

#### A8: Software and Data Integrity Failures

- **SRI:** Use Subresource Integrity for external scripts? Next.js handles
- **Codegen:** Use `graphql-codegen` to generate typed queries from backend schema introspection (dev only), ensures frontend queries match backend schema, prevents drift
- **Persisted Queries:** In prod, only allow whitelisted query hashes from codegen, not arbitrary queries — prevents tampering

#### A9: Security Logging and Monitoring Failures

- **Backend:** `platform.audit_logs` (org, site, user, action create/update/delete, entity, diff, ip, user_agent, created_at) via trigger `log_audit()` on all tables, `vendor.compliance_audit_logs`, `cron.job_run_details`, Edge Function logs via `supabase functions logs`
- **Frontend:** Add error boundary that logs to console + Sentry (optional) without leaking stack traces to user, show generic "Something went wrong" message
- **Monitoring:** Supabase Dashboard Logs, plus custom `metrics.v_sla_metrics`, `v_building_benchmark` for operational monitoring

#### A10: Server-Side Request Forgery (SSRF)

- **No User-Controlled URLs in GraphQL:** pg_graphql resolvers are auto-generated from tables, no custom resolvers that fetch user-provided URLs
- **pg_net http_post only to allowed internal Edge Functions:** In cron jobs, we call `net.http_post(url := 'https://.../functions/v1/...')` with hardcoded URLs, not user input. Validate URLs against allowlist `https://*.supabase.co/functions/v1/*`
- **Edge Functions:** If any function fetches user-provided URL (e.g., `parse-coi-pdf` downloads from storage_path, not arbitrary URL), validate storage_path starts with org_id, not `http://`

#### GraphQL Specific OWASP:

- **Excessive Data Exposure:** Use views that hide sensitive fields. Example: `stripe_customer_id` in subscriptions table should NOT be exposed via GraphQL — create view `subscriptions_public` without that column, grant SELECT on view to authenticated, not base table. Similarly `cost` hidden for tenant_user.
- **Mass Assignment:** In mutations like `createWorkOrder`, only allow whitelisted fields via Zod, not arbitrary `metadata` jsonb that could contain secret keys. Validate metadata keys.
- **Rate Limiting / DoS:**
  - Depth limiting: max depth 10 via Edge Function gateway analyzing query AST
  - Complexity: assign cost per field (collection 10, single 1), max 1000
  - Alias overloading: limit alias count max 20
  - Batching: disable batching or limit to 5 queries per request
  - Implement via Edge Function `graphql-gateway` that sits in front of `/graphql/v1`, parses query, checks depth/complexity/alias count, rate limits by IP + user, then proxies to real GraphQL endpoint if passes
- **Introspection Disclosure:** Disable in prod (`introspection: false`), enable in dev (`true`). Our migration 00017 enables for all schemas — should have separate migration for prod that disables.
- **IDOR:** RLS ensures user can only access sites where `can_access_site(site_id)` true via memberships.site_ids. Even if they guess UUID of another site's work order, RLS returns empty (secure by default)

---

## 5. Branching Strategy (Not Main)

- **Backend Repo `PlutusPM_api`:**
  - Branch: `feature/graphql-owasp-integration` (from main)
  - Changes: Docs (SECURITY_OWASP.md, GRAPHQL_BEST_PRACTICES.md), migration 00018 to disable introspection in prod + add field-level views, Edge Function graphql-gateway with rate limiting/depth limiting, update config.toml with secure headers note, update README with security section

- **Frontend Repo `PlutusPM_dashboard`:**
  - Branch: `feature/graphql-integration` (from main)
  - Changes: Create GraphQL data layer, replace mock data with real GraphQL queries, add codegen, Zod validation, error boundaries, secure headers, env vars, documentation

Both branches will be pushed to GitHub, NOT main, for review.

---

## 6. Implementation Plan - Backend Repo

### Step B1: Docs

- Create `docs/SECURITY_OWASP.md` - Detailed OWASP Top 10 mitigations for backend
- Create `docs/GRAPHQL_BEST_PRACTICES.md` - GraphQL best practices + security
- Update `README.md` with Security section + Docker run with env vars

### Step B2: Migration 00018 - Security Hardening

- **Field-Level Security Views:**
  - `ops.work_orders_tenant_view` without cost, labor_hours for tenant role
  - `vendor.vendors_public` without sensitive fields
  - Grant SELECT on views to tenant_user, vendor roles, not base tables

- **Introspection Toggle:**
  - For prod, disable introspection: `comment on schema public is '@graphql({"introspection": false})';` etc for all schemas
  - But keep a separate migration for dev that enables: `00017` already enabled, so `00018` could be for prod disable, with comment that in dev you should have introspection true, in prod false. Or make it conditional via env var.

- **Audit Triggers:**
  - Ensure `log_audit()` trigger attached to all main tables (currently generic function exists but not attached to all tables). Add triggers for all tables missing.

### Step B3: Edge Function graphql-gateway (WAF for GraphQL)

- Create `supabase/functions/graphql-gateway/index.ts`
- Responsibilities:
  - Rate limiting: Use Upstash Redis or in-memory map with IP + user ID sliding window 100 req/min
  - Depth limiting: Parse query AST, count depth, reject if >10
  - Complexity: Simple heuristic count fields, reject if >1000
  - Alias limiting: Count aliases, reject if >20
  - Batching: If query contains multiple operations or batch array >5, reject
  - Persisted Queries: In prod, check if query hash is in whitelist JSON file (generated by codegen), if not, reject
  - Logging: Log all blocked queries with IP, user, reason to audit_logs
  - Proxy: If passes, forward to real GraphQL endpoint `SUPABASE_URL/graphql/v1` with same headers + apikey, return response
  - Config via env vars: MAX_DEPTH, MAX_COMPLEXITY, RATE_LIMIT etc

- Add to `config.toml`:
  ```toml
  [functions.graphql-gateway]
  enabled = true
  verify_jwt = false
  entrypoint = "./functions/graphql-gateway/index.ts"
  ```

- Frontend should then point GRAPHQL_ENDPOINT to `/functions/v1/graphql-gateway` instead of direct `/graphql/v1` in production, for added security layer. In dev, direct.

### Step B4: Config Hardening

- Update `next.config.ts` in frontend (but this is backend repo? Actually backend config.toml already has secure settings)
- For backend, ensure `api.schemas` includes only necessary schemas, not overly permissive
- Ensure `extra_search_path` includes custom schemas but not overly broad

---

## 7. Implementation Plan - Frontend Repo

### Step F1: Setup & Env

- Create branch `feature/graphql-integration` from main
- Create `.env.example` with required env vars:
  ```
  NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
  NEXT_PUBLIC_GRAPHQL_ENDPOINT=http://127.0.0.1:54321/graphql/v1
  NEXT_PUBLIC_GRAPHQL_GATEWAY_ENDPOINT=http://127.0.0.1:54321/functions/v1/graphql-gateway
  NEXT_PUBLIC_REST_ENDPOINT=http://127.0.0.1:54321/rest/v1
  NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
  ```
- Document in README how to get anon key from `supabase status`

### Step F2: GraphQL Codegen Setup

- Install `graphql-codegen` + plugins:
  ```bash
  npm i -D @graphql-codegen/cli @graphql-codegen/client-preset
  ```
- Create `codegen.ts`:
  ```typescript
  import type { CodegenConfig } from '@graphql-codegen/cli';
  const config: CodegenConfig = {
    schema: process.env.NEXT_PUBLIC_GRAPHQL_ENDPOINT + '?apikey=' + process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    documents: ['app/**/*.{ts,tsx}', '!app/_data/**'],
    generates: {
      'app/_lib/graphql/generated/': {
        preset: 'client',
        plugins: []
      }
    }
  };
  export default config;
  ```
- Add script `codegen: graphql-codegen --config codegen.ts` to package.json
- Run `npm run codegen` to generate typed hooks/queries from backend schema introspection (requires dev introspection enabled)
- Generated types provide type-safe queries, prevents drift, enables persisted queries

### Step F3: Secure GraphQL Client

- Update `app/_lib/backend/graphql/client.ts` to be server-only, use httpOnly cookies for JWT
- Ensure `buildGraphQLHeaders` uses apikey from env + Authorization Bearer from cookie (httpOnly)
- Add Zod validation for variables before sending
- Add error handling that hides stack traces, returns generic message to client, logs details server-side
- Add depth/complexity calculation client-side as pre-check? Or rely on gateway
- Use persisted queries in prod: Instead of sending full query string, send hash, gateway maps to query

**New Secure Client Example:**

```typescript
"use server";
import { z } from "zod";
import { getAuthSession } from "../auth-cookies";
import { getPublicBackendEnv } from "../env";

const MAX_QUERY_DEPTH = 10;

function calculateDepth(query: string): number {
  // Simple depth count via braces nesting
  let maxDepth = 0, current = 0;
  for (const char of query) {
    if (char === '{') { current++; maxDepth = Math.max(maxDepth, current); }
    if (char === '}') current--;
  }
  return maxDepth;
}

export async function secureGraphqlRequest<TData, TVariables>(options: {
  query: string;
  variables?: TVariables;
  schema: z.ZodSchema<TVariables>;
}) {
  // 1. Validate variables with Zod
  const parsedVariables = options.schema ? options.schema.parse(options.variables) : options.variables;

  // 2. Depth limiting
  const depth = calculateDepth(options.query);
  if (depth > MAX_QUERY_DEPTH) throw new Error(`Query too deep: ${depth} > ${MAX_QUERY_DEPTH}`);

  // 3. Get session from httpOnly cookie (server-only)
  const session = await getAuthSession();
  if (!session?.accessToken) throw new BackendAuthError();

  // 4. Forward to gateway in prod, direct in dev
  const env = getPublicBackendEnv();
  const endpoint = process.env.NODE_ENV === 'production' 
    ? env.graphqlGatewayEndpoint 
    : env.graphqlEndpoint;

  // 5. Fetch with secure headers
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.anonKey,
      Authorization: `Bearer ${session.accessToken}`,
      "X-Request-ID": crypto.randomUUID(), // for tracing
    },
    body: JSON.stringify({
      query: options.query,
      variables: parsedVariables
    }),
    cache: "no-store"
  });

  // 6. Error handling without leaking details
  if (!response.ok) {
    console.error(`GraphQL ${response.status} for query`, options.query.slice(0, 100));
    throw new BackendError("Failed to fetch data. Please try again.");
  }

  const payload = await response.json();
  if (payload.errors?.length) {
    console.error("GraphQL errors:", payload.errors);
    // Don't expose internal errors to client
    throw new BackendError(payload.errors[0].message.includes("Unknown field") 
      ? "Invalid query" 
      : "Failed to fetch data");
  }

  return payload.data as TData;
}
```

### Step F4: Replace Mock Data with Real GraphQL

- For each dashboard page (work-orders, assets, vendors, visitors, dashboard-overview, etc), replace `plutusData.workOrders` mock with real data fetching via `graphqlRequest` or `secureGraphqlRequest`

**Example: Work Orders Page**

Before (mock):
```typescript
import { plutusData } from "@/app/_data/plutus";
export default function WorkOrdersPage() {
  return <WorkOrdersView workOrders={plutusData.workOrders} />;
}
```

After (real GraphQL, server component):
```typescript
import { requireManagementContext } from "@/app/_services/management-context";
import { graphqlRequest } from "@/app/_lib/backend/graphql/client";
import { z } from "zod";

const WorkOrdersQuery = `
  query WorkOrders($siteId: UUID!) {
    workOrdersCollection(filter: {siteId: {eq: $siteId}}, orderBy: {createdAt: DescNullsLast}, first: 50) {
      edges {
        node {
          id
          title
          status
          priority
          dueDate
          slaDueAt
          createdAt
          siteId
        }
      }
    }
  }
`;

const variablesSchema = z.object({ siteId: z.string().uuid() });

export default async function WorkOrdersPage({ searchParams }: { searchParams: { siteId?: string } }) {
  const context = await requireManagementContext(); // Checks membership, gets siteIds, throws if not auth
  const siteId = searchParams.siteId || context.siteIds[0];

  const data = await secureGraphqlRequest({
    query: WorkOrdersQuery,
    variables: { siteId },
    schema: variablesSchema
  });

  const workOrders = data.workOrdersCollection.edges.map(edge => ({
    id: edge.node.id,
    number: edge.node.id.slice(0, 8).toUpperCase(),
    title: edge.node.title,
    propertyId: edge.node.siteId,
    propertyName: context.properties.find(p => p.id === edge.node.siteId)?.name || "Unknown",
    priority: mapPriority(edge.node.priority),
    status: mapStatus(edge.node.status),
    dueDate: formatDate(edge.node.dueDate),
    sla: calculateSLA(edge.node.slaDueAt),
    // etc
  }));

  return <WorkOrdersView workOrders={workOrders} />;
}
```

- Do same for Assets, Vendors, Visitors, Dashboard metrics (use `dailySiteStatsCollection`, `getSiteKpis` etc)

### Step F5: RBAC UI Gating

- Create hook `useRole()` or server function `getUserRole()` that returns role from memberships
- In UI, hide/show buttons based on role:
  ```typescript
  const { role } = await getUserMembership();
  const canDeleteOrg = role === 'owner';
  const canCreateWorkOrder = ['owner','admin','site_manager','building_engineer'].includes(role);
  ```
- But backend RLS still enforces, so even if UI shows button, backend will block if not authorized (defense in depth)

### Step F6: Input Validation with Zod

- For all mutations (createWorkOrder, createInspection, registerVisitor, etc), define Zod schemas and validate both frontend (client) and backend (via Edge Function gateway or via Postgres check constraints already exist, but add Zod in frontend before sending)

### Step F7: Secure Headers + CSP

- Update `next.config.ts`:
  ```typescript
  const nextConfig = {
    async headers() {
      return [{
        source: '/(.*)',
        headers: [
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
          { key: 'Content-Security-Policy', value: "default-src 'self'; script-src 'self' 'unsafe-eval' 'unsafe-inline' https://127.0.0.1:54321; connect-src 'self' http://127.0.0.1:54321 https://*.supabase.co; ..." },
          { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
          { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' }
        ]
      }]
    }
  }
  ```

### Step F8: Error Boundaries + Logging

- Create `app/_components/shared/error-boundary.tsx` that catches errors, logs to console (or Sentry), shows generic "Something went wrong" without stack trace
- Wrap dashboard pages with error boundary

### Step F9: Documentation

- Update `README.md` in frontend repo with:
  - How to set up env vars
  - How to run `npm run codegen` for GraphQL types
  - How GraphQL integration works (server components, httpOnly cookies, RLS)
  - OWASP mitigations implemented
  - How to test RLS (try accessing site you don't belong to)

- Update `docs/` in backend repo with:
  - `SECURITY_OWASP.md` - OWASP Top 10 mitigations
  - `GRAPHQL_BEST_PRACTICES.md` - Best practices + gateway

---

## 8. Branching & Execution

1. **Create Branches:**
   - Backend: `git checkout -b feature/graphql-owasp-integration` from main
   - Frontend: `git checkout -b feature/graphql-integration` from main (in /tmp/PlutusPM_dashboard)

2. **Backend Changes in Branch:**
   - Create docs/SECURITY_OWASP.md
   - Create docs/GRAPHQL_BEST_PRACTICES.md
   - Create migration 00018_security_hardening.sql (field-level views, audit triggers for all tables, disable introspection in prod comment)
   - Create Edge Function graphql-gateway with rate limiting, depth limiting, persisted queries
   - Update config.toml to add graphql-gateway function
   - Update README with security section

3. **Frontend Changes in Branch:**
   - Create .env.example
   - Install graphql-codegen, zod
   - Create codegen.ts
   - Update graphql client to secure version with Zod, depth limiting, httpOnly cookies
   - Create lib/graphql/queries.ts with typed queries for all domains (portfolios, sites, work orders, assets, vendors, visitors, etc)
   - Replace mock plutusData with real GraphQL in at least 2 pages as example (work-orders, assets), document how to do rest
   - Add next.config.ts secure headers
   - Add error boundary
   - Update README with GraphQL integration guide + OWASP mitigations

4. **Push Branches:**
   - Backend: `git push -u origin feature/graphql-owasp-integration`
   - Frontend: `git push -u origin feature/graphql-integration`

5. **Document Everything:**
   - Both repos have docs/GRAPHQL_SECURE_INTEGRATION_PLAN.md (this file)
   - Backend also has SECURITY_OWASP.md, GRAPHQL_BEST_PRACTICES.md
   - Frontend README updated

---

## 9. Security Checklist (OWASP Top 10) - Final Verification

- [ ] A1 Broken Access Control: RLS on all tables, can_access_site checks, RBAC UI gating, site_ids filtering, membership checks in requireManagementContext
- [ ] A2 Cryptographic Failures: HTTPS redirect, Secure httpOnly SameSite Strict cookies, JWT ES256 short expiry, refresh rotation, no secrets in code
- [ ] A3 Injection: pg_graphql parameterized queries, Zod validation on all inputs, no string concat in SQL
- [ ] A4 Insecure Design: Domain-driven 6 schemas, least privilege, secure by default, threat model in this doc
- [ ] A5 Security Misconfiguration: Introspection disabled in prod, GraphiQL disabled in prod, CORS only allowed origins, secure headers, env vars via .env.local not committed
- [ ] A6 Vulnerable Components: package-lock.json committed, npm audit in CI, Next.js 16 latest, Supabase CLI latest
- [ ] A7 Auth Failures: httpOnly cookies, short JWT, refresh rotation, lockout via Supabase Auth rate limiting, MFA ready
- [ ] A8 Data Integrity: SRI, codegen for type safety, persisted queries whitelist in prod
- [ ] A9 Logging/Monitoring: audit_logs, compliance_audit_logs, cron.job_run_details, Edge Function logs, frontend error boundaries
- [ ] A10 SSRF: No user-controlled URLs in GraphQL resolvers, pg_net http_post only to allowed internal edge functions, storage_path validated starts with org_id
- [ ] GraphQL Excessive Data Exposure: Views hide sensitive fields (cost for tenant, stripe_customer_id)
- [ ] GraphQL Mass Assignment: Zod whitelists allowed fields, metadata keys validated
- [ ] GraphQL DoS: Edge gateway depth 10, complexity 1000, alias 20, rate limit 100/min, disable batching
- [ ] GraphQL Introspection Disclosure: Disabled in prod via comment introspection false, enabled in dev true
- [ ] GraphQL IDOR: RLS ensures can_access_site, even if guessing UUID returns empty

---

## 10. Next Steps After Plan Execution

- Review branches via PRs (not merging to main yet per user request)
- Test locally: supabase start, seed, frontend npm run dev with .env.local pointing to local Supabase, test RLS with two users different orgs
- Security audit: Run `npm audit`, test Burp Suite or GraphQL map for depth/complexity attacks
- Deploy to staging: Supabase cloud project + Vercel frontend with env vars pointing to cloud
- Penetration testing: Try accessing other org's sites via GraphQL with JWT from different org, should return empty due to RLS
- Documentation: Both repos README updated with security section + GraphQL integration guide

---

## References

- Supabase Docs: https://supabase.com/docs/guides/graphql
- pg_graphql Docs: https://github.com/supabase/pg_graphql
- OWASP Top 10 2021: https://owasp.org/Top10/
- OWASP GraphQL Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/GraphQL_Cheat_Sheet.html
- OWASP GraphQL Top 10: https://owasp.org/www-project-graphql-security/
- Supabase RLS Guide: https://supabase.com/docs/guides/auth/row-level-security
