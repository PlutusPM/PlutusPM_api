# Frontend Developer Guide - CRE SaaS Backend

This doc is for the person building frontend. Backend is Supabase.

## Connection

```env
NEXT_PUBLIC_SUPABASE_URL=https://xxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGc...
# NEVER expose service_role key
```

**GraphQL Endpoint:** `https://xxx.supabase.co/graphql/v1`
Headers:
```
apikey: <anon_key>
Authorization: Bearer <user_jwt> // from supabase.auth.getSession()
Content-Type: application/json
```

**REST Endpoint (alternative):** `https://xxx.supabase.co/rest/v1/` - also works but GraphQL preferred.

**Realtime:** Use Supabase JS client:
```ts
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(URL, ANON_KEY)

supabase.channel(`site:${siteId}`)
  .on('postgres_changes', { event: '*', schema: 'ops', table: 'work_orders', filter: `site_id=eq.${siteId}` }, payload => {
    // update UI
  })
  .subscribe()
```

## Auth

```ts
// Sign up
await supabase.auth.signUp({ email, password, options: { data: { full_name: 'Jane' } } })

// Sign in
await supabase.auth.signInWithPassword({ email, password })

// OAuth
await supabase.auth.signInWithOAuth({ provider: 'google' })

// Get user
const { data: { user } } = await supabase.auth.getUser()

// Get memberships (orgs/sites you can access)
const { data: memberships } = await supabase.from('memberships').select('*, organizations(*)').eq('user_id', user.id)
// Or via GraphQL
```

After login, profile is auto-created via trigger. Memberships determine access - RLS automatically filters sites/portfolios.

## Core Flow - Portfolio & Sites

Every page should start with site selector. Query allowed sites (RLS filtered):

```graphql
query MySites {
  portfolioSitesCollection(orderBy: {name: AscNullsLast}) {
    edges { node { id name address city type status } }
  }
}
```

Store selected `siteId` in context - all subsequent queries filter by it.

## Example - Building Ops Dashboard

```graphql
query Dashboard($siteId: UUID!) {
  portfolioSitesCollection(filter: {id: {eq: $siteId}}) {
    edges {
      node {
        id name
        opsWorkOrdersCollection(
          filter: {status: {in: [OPEN, IN_PROGRESS, OVERDUE]}}
          orderBy: {createdAt: DescNullsLast}
          first: 20
        ) {
          edges {
            node {
              id title status priority createdAt slaDueAt
              opsAssets { id name }
              assignedToProfile: platformProfilesByAssignedTo { fullName avatarUrl }
            }
          }
        }
        opsAssetsCollection {
          edges { node { id name status category { name } } }
        }
      }
    }
  }
}
```

Mutation to create WO (via custom function):

```graphql
mutation CreateWorkOrder($siteId: UUID!, $title: String!, $desc: String!) {
  opsCreateWorkOrder(input: {pSiteId: $siteId, pTitle: $title, pDescription: $desc}) {
    id title
  }
}
```

## File Uploads - Storage

```ts
// Avatar
const { data, error } = await supabase.storage
  .from('avatars')
  .upload(`${user.id}/avatar.png`, file, { upsert: true })

// Site file - must follow path: org_id/site_id/...
const path = `${orgId}/${siteId}/assets/${assetId}/${file.name}`
await supabase.storage.from('site-files').upload(path, file)

// Get public URL for avatars (private bucket needs signed URL)
const { data: { publicUrl } } = supabase.storage.from('avatars').getPublicUrl(`${user.id}/avatar.png`)
const { data: signed } = await supabase.storage.from('site-files').createSignedUrl(path, 3600)
```

## Notifications

Poll or Realtime:

```ts
supabase.channel('notifications')
  .on('postgres_changes', { event: 'INSERT', schema: 'platform', table: 'notifications', filter: `user_id=eq.${user.id}` }, payload => {
    toast(payload.new.payload.message)
  })
  .subscribe()
```

## RBAC in UI

Get memberships:

```graphql
query MyRole($siteId: UUID!) {
  platformMembershipsCollection(filter: {userId: {eq: $userId}}) {
    edges { node { role orgId siteIds } }
  }
}
```

Show/hide based on role:
- owner/admin/site_manager => can edit site, create buildings, invite members
- building_engineer => only ops domain
- security => visitor domain
- tenant_user => only reservations, view own requests

Backend RLS still enforces - frontend gating is UX only.

## Known Gotchas

1. GraphQL uses `Collection` suffix and `edges { node }` pattern (Relay style)
2. Filter syntax: `filter: {status: {eq: ACTIVE}}`, `filter: {title: {ilike: "%pump%"}}`
3. For JSONB metadata field, use `filter: {metadata: {contains: {custom_key: "value"}}}`
4. Realtime only works if table has REPLICA IDENTITY FULL and added to publication (we did in migration)
5. All UUIDs are strings in JS
6. Dates are ISO strings

## What to Build First (Suggested Order for Frontend)

1. Auth pages + org selector
2. Portfolio list + Site list + Site detail (with building/floor/space hierarchy)
3. Work Orders list + create/edit (Building Ops MVP)
4. Assets list
5. Visitor registration + check-in screen
6. Tenant service request form

Backend will parallel build deeper domains.

## Need Help?

Backend dev owns:
- RLS policies if you get permission denied
- New table? Backend adds migration
- New GraphQL mutation? Backend creates Postgres function with @graphql comment
- Cron jobs? Backend configures
- Storage bucket rules

You own:
- UI/UX
- GraphQL queries/mutations
- Realtime subscriptions
- State management

Ask backend dev for PostGIS geo queries if you need map: `nearby sites within 5km` etc.
