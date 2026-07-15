# Types & Postman Collection

## TypeScript Types

**File:** `types/database.ts` - Complete Database type for all 6 schemas (platform, portfolio, ops, tenant, visitor, vendor, metrics) with all tables from migrations 00000-00015.

**File:** `types/supabase.ts` - Helper exports + helper types (Organization, Site, WorkOrder, etc.)

### Usage for Frontend Dev:

```typescript
import { createClient } from '@supabase/supabase-js'
import type { Database } from './types/database'

const supabase = createClient<Database>(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
)

// Typed queries
const { data: sites } = await supabase
  .schema('portfolio')
  .from('sites')
  .select('*')
  // sites is typed as Site[]
```

To regenerate from a live project (when supabase is running):

```bash
supabase gen types typescript --local > types/supabase-generated.ts
# or for cloud:
supabase gen types typescript --project-id your-project-ref --schema public,platform,portfolio,ops,tenant,visitor,vendor,metrics > types/generated.ts
```

## Postman Collection

**Files:**

- `postman/PlutusPM.postman_collection.json` - 60+ requests
- `postman/PlutusPM.postman_environment.json` - Environment variables

### Import:

1. Open Postman
2. Import → Files → select both collection + environment JSON
3. Select environment "PlutusPM Local & Cloud" top-right
4. Edit environment:
   - `supabaseUrl`: `http://127.0.0.1:54321` (local) or `https://xxx.supabase.co` (cloud)
   - `anonKey`: from `supabase start` output or Dashboard > Settings > API
   - `serviceRoleKey`: same place (secret, only for some Edge Functions)

### Flow:

1. **Auth > Sign Up** (creates demo@cre.local / password123) - auto-saves JWT
2. **Auth > Sign In** - saves userJwt + userId for all other requests
3. **Setup > GraphQL Introspection Test** - should return 1 site if seed ran
4. Then test any domain:
   - Portfolio & Sites: My Organizations, Sites Hierarchy, Search, Nearby (PostGIS), Create Org/Site
   - Building Ops: Assets, WOs Dashboard, Create WO, Checklists, Create/Complete Inspection, Low Stock
   - Tenant: Announcements, Events, Amenities, Check Reservation Conflict, Create Reservation, Service Requests (auto WO)
   - Visitor: Today's Visitors, Register, Generate Pass, Validate (kiosk), Check-In/Out, Stats
   - Compliance: Vendors with Compliance, Evaluate Compliance, Dashboard, Rules
   - Analytics: Site KPIs, Portfolio KPIs, Daily Stats 30d, Benchmark, SLA, Reports list
   - Edge Functions: health, generate-qr, send-visitor-pass, engineering-report, visitor-kiosk (validate/check_in/stats), amenity-booking, parse-coi-pdf, compliance-report, scheduled-reports, export-data
   - Storage: Upload Avatar, Site File, COI Doc, Signed URL
   - Notifications: Get Unread, Mark Read

### Variables Auto-Filled:

After Sign In, `userJwt` and `userId` are auto-set via Test scripts. For other IDs (siteId, orgId, etc), copy from GraphQL responses and paste into environment - then other requests use `{{siteId}}` etc.

### GraphQL Testing Tips:

- All GraphQL POST to `{{supabaseUrl}}/graphql/v1` with headers `apikey: {{anonKey}}` + `Authorization: Bearer {{userJwt}}`
- Queries use Relay style `edges { node }`
- Filters: `filter: {siteId: {eq: $siteId}, status: {eq: active}}`
- Mutations via custom functions: `opsCreateWorkOrder(input: {pSiteId: ...})`

### Edge Functions Auth:

- Public functions (no JWT): health, visitor-kiosk (for kiosk device)
- Authenticated (user JWT): generate-qr, send-visitor-pass, engineering-report, amenity-booking, compliance-report, export-data
- Service role (serviceRoleKey): parse-coi-pdf, scheduled-reports, compliance-daily-check

### Realtime Testing:

Realtime not testable via Postman - use Supabase JS:

```javascript
supabase.channel('test')
  .on('postgres_changes', { event: '*', schema: 'ops', table: 'work_orders', filter: `site_id=eq.${siteId}` }, payload => console.log(payload))
  .subscribe()
```

Then create WO via Postman GraphQL and see realtime event in console.
