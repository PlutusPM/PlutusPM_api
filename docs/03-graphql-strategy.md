# GraphQL Strategy with Supabase pg_graphql

## TL;DR
We use Supabase's native `pg_graphql` extension. Zero extra servers. RLS enforced. Auto-generated CRUD from tables. Custom logic via Postgres functions.

## Why pg_graphql vs Hasura / PostGraphile?

| Feature | pg_graphql (native) | Hasura | PostGraphile |
|---------|---------------------|--------|--------------|
| Infra | 0 extra, inside Postgres | 1 more container | 1 more container |
| RLS | Native, automatic | Needs webhook | Native |
| Supabase Auth | Works out of box | Needs custom | Needs custom |
| Performance | Excellent (C extension) | Excellent | Good |
| Extensibility | SQL functions -> GQL | Actions | Plugins |
| Real-time | Use Supabase Realtime (separate) | Subscriptions | Subscriptions |

**Decision:** Start with `pg_graphql`. If you hit limits (complex authz, N+1), we can add PostGraphile as Edge Function later. For CRE SaaS, pg_graphql is sufficient for 95%.

## Enablement

```sql
-- In first migration
create extension if not exists pg_graphql with schema graphql;
create extension if not exists postgis;
grant usage on schema portfolio, platform, ops, tenant, visitor, vendor, metrics to anon, authenticated, service_role;
grant usage on schema graphql to anon, authenticated;

-- pg_graphql reads from graphql schema config
-- Expose schemas to GraphQL
comment on schema public is '@graphql({"inflect_names": true})';
comment on schema portfolio is '@graphql({"inflect_names": true})';
comment on schema platform is '@graphql({"inflect_names": true})';
comment on schema ops is '@graphql({"inflect_names": true})';
comment on schema tenant is '@graphql({"inflect_names": true})';
comment on schema visitor is '@graphql({"inflect_names": true})';
comment on schema vendor is '@graphql({"inflect_names": true})';
```

Endpoint automatically available at:
`https://<project-ref>.supabase.co/graphql/v1`
Needs `apikey` header (anon key) + `Authorization: Bearer <jwt>` for user queries.

## How Frontend Queries

### Setup Client (Example for your frontend dev - any framework)

```typescript
import { GraphQLClient } from 'graphql-request';

const client = new GraphQLClient('https://xxx.supabase.co/graphql/v1', {
  headers: {
    apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    Authorization: `Bearer ${session.access_token}`
  }
});

// RLS automatically applies - user only sees sites they belong to
```

### Example Queries

```graphql
# 1. Get my orgs, portfolios, sites
query MyPortfolio {
  platformOrganizationsCollection {
    edges { node { id name slug } }
  }
  portfolioPortfoliosCollection {
    edges {
      node {
        id name
        portfolioSitesCollection(orderBy: {name: AscNullsLast}) {
          edges {
            node {
              id name address city state
              type status totalSqFt: sqFt
              portfolioBuildingsCollection {
                edges { node { id name floorsCount } }
              }
              # count assets
              opsAssetsCollection(filter: {status: {eq: ACTIVE}}) {
                pageInfo { hasNextPage }
                edges { node { id name } }
              }
            }
          }
        }
      }
    }
  }
}

# 2. Building Ops Dashboard for a site
query SiteOps($siteId: UUID!) {
  portfolioSitesCollection(filter: {id: {eq: $siteId}}) {
    edges {
      node {
        id name
        opsWorkOrdersCollection(
          filter: {status: {neq: COMPLETED}}
          orderBy: {priority: DescNullsLast, createdAt: DescNullsLast}
        ) {
          edges {
            node {
              id title priority status slaDueAt
              opsAssets { id name }
              platformProfilesByAssignedTo { fullName }
            }
          }
        }
        opsAssetsCollection {
          edges { node { id name status criticality lastInspectionAt } }
        }
      }
    }
  }
}

# 3. Visitor Management
query TodaysVisitors($siteId: UUID!) {
  visitorVisitsCollection(
    filter: {
      siteId: {eq: $siteId}
      scheduledAt: {gte: "2024-07-15", lte: "2024-07-16"}
    }
    orderBy: {scheduledAt: AscNullsLast}
  ) {
    edges {
      node {
        id status scheduledAt checkedInAt
        visitorVisitors { name company email }
        platformProfilesByHostUserId { fullName }
      }
    }
  }
}

# 4. Compliance Dashboard
query Compliance($siteId: UUID!) {
  vendorVendorsCollection(filter: {status: {eq: ACTIVE}}) {
    edges {
      node {
        id name type
        vendorContractsCollection(filter: {siteId: {eq: $siteId}}) {
          edges { node { id title status endDate } }
        }
        vendorCoisCollection(orderBy: {expiryDate: AscNullsLast}) {
          edges { node { id type expiryDate status } }
        }
        vendorComplianceStatusCollection(filter: {siteId: {eq: $siteId}}) {
          edges { node { status issues lastChecked } }
        }
      }
    }
  }
}
```

### Mutations via Functions

pg_graphql exposes Postgres functions as mutations if they are marked.

```sql
-- Example: Create work order with business logic
create or replace function ops.create_work_order(
  p_site_id uuid,
  p_title text,
  p_description text,
  p_asset_id uuid default null,
  p_priority text default 'medium'
) returns ops.work_orders
language plpgsql
security definer
as $$
declare
  new_wo ops.work_orders;
begin
  -- Check access
  if not platform.can_access_site(p_site_id) then
    raise exception 'Access denied to site';
  end if;

  insert into ops.work_orders (site_id, org_id, title, description, asset_id, priority, created_by, status)
  values (p_site_id, platform.current_org_id(), p_title, p_description, p_asset_id, p_priority::ops.priority_level, auth.uid(), 'open')
  returning * into new_wo;

  -- Log audit
  insert into platform.audit_logs (org_id, site_id, user_id, action, entity, entity_id)
  values (platform.current_org_id(), p_site_id, auth.uid(), 'create', 'work_order', new_wo.id);

  return new_wo;
end;
$$;

comment on function ops.create_work_order is '@graphql({"type": "mutation"})';
```

GraphQL then:
```graphql
mutation CreateWO($siteId: UUID!, $title: String!, $desc: String!) {
  opsCreateWorkOrder(input: {pSiteId: $siteId, pTitle: $title, pDescription: $desc}) {
    id title status
  }
}
```

## Security Notes

- **Never expose service_role key to GraphQL client** - only anon + user JWT
- **RLS is your firewall** - pg_graphql respects RLS automatically. If user not member of site, query returns empty, not error (secure by default)
- **Field-level security:** Use views to hide sensitive fields (e.g., `stripe_customer_id` not exposed). Create `ops.work_orders_public` view without cost/labor fields for tenant role.
- **Rate limit:** Add Edge Function `graphql-gateway` if you need WAF/rate limit. Native endpoint has Supabase API gateway limits (100 req/s anon). Can increase.

## Alternative: If you need Advanced GraphQL Features

If you later need:
- Persisted queries
- Query batching
- Field-level permissions beyond RLS
- Custom scalars

We can deploy **Graphile Starter / PostGraphile as Edge Function** or external service reading same Postgres with same RLS. But defer until needed.

## GraphiQL

Supabase Dashboard does NOT have GraphiQL yet. Recommend frontend dev use:
- https://graphiql-online.com/ pointing to your endpoint
- Or deploy `supabase/graphql` Edge Function that serves GraphiQL playground (I can scaffold)

We will include `docs/FRONTEND_GUIDE.md` with full setup.
