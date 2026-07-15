# Core Data Model - Portfolio → Sites → Everything On Site

## Entity Relationship (Text Diagram)

```
[auth.users (Supabase)]
        1
        │
        1
[platform.profiles] ───< [platform.memberships] >─── [platform.organizations]
                             │     │                      │ 1
                             │     │                      │ 
                             │     └─ role per org        │ 1
                             │                            │
                             │                            N
                             │                    [portfolio.portfolios]
                             │                            │ 1
                             │                            │ 
                             │                            N
                             │                     [portfolio.sites] ◄── CENTER
                             │                            │ 1
                             │               ┌────────────┼────────────┐
                             │               │            │            │
                             │               N            N            N
                             │        [portfolio.buildings]    [ops.assets]   [tenant.tenants] ...
                             │               │ 1          ...  
                             │               │ 
                             │               N
                             │        [portfolio.floors]
                             │               │ 1
                             │               N
                             └────────  [portfolio.spaces]
                                          │ 1
                                          │
                          ┌───────────────┼────────────────┐
                          N               N                N
                   [ops.work_orders]  [tenant.leases]  [visitor.visits]
```

## Why site_id everywhere?

Every table (except organizations, portfolios, profiles) has `site_id`. This enables:

1. **Fast RLS:** `where site_id = any(auth.site_ids())` - no joins needed
2. **GraphQL filtering:** `sitesCollection.filter: {id: {eq: $siteId}}` automatically filters children
3. **Analytics:** Group by site_id for rollups
4. **Realtime:** Subscribe to `site_id=eq.123` gets all changes on that site
5. **SaaS partitioning:** If site grows huge, can partition tables by site_id

## Key Tables DDL Preview (Phase 0)

See full SQL in `/supabase/migrations/` after approval.

### platform.organizations
SaaS tenant. Example: "Lincoln Property Company" manages many portfolios for different clients.

### platform.profiles
 Mirrors auth.users + custom fields. One profile per user across all orgs.

### portfolio.portfolios
Logical grouping. A client might have "Life Science Portfolio - Boston" containing 5 lab buildings (sites).

### portfolio.sites
The atomic unit. Address, geo, timezone, size. All ops/tenant/visitor data hangs here.

- `type`: office, retail, industrial, lab, hospitality, multifamily, mixed_use, medical, education, datacenter
- `status`: active, onboarding, inactive, disposed
- `metadata jsonb`: flexible for custom fields per property type
- `location geography(Point)` PostGIS for map search

### portfolio.buildings / floors / spaces
- buildings: physical structures at site (campus with 3 towers)
- floors: levels, useful for floorplans and space hierarchy
- spaces: leasable units, common areas, amenities, parking spots - tenant occupies space

## Indexing Strategy

- GIN on `metadata jsonb`
- GiST on PostGIS `location`
- B-tree on `(org_id, site_id)`, `(site_id, status)`, `(site_id, created_at desc)`
- Trigram GIN on `name` for search
- pg_cron jobs use `where status = 'active'` partial indexes

## Soft Deletes vs Hard

Recommendation: `status` enum + `deleted_at` timestamp for all main tables. Keep history for audit. Only truly delete PII via scheduled purge function.

## Multi-tenancy Isolation

- **Row Level Security mandatory** on every table
- **No service_role key to frontend** - ever
- **Cross-org scenario:** If a property manager manages portfolios for external clients (common in CRE), model that as memberships with role `portfolio_manager` across multiple orgs, or have `org_id` = management company, and `client_id` field nullable for who owns asset.

Questions:
- Does one organization ever need to see another org's data? (If yes, we need `access_grants` table)
- Do you have global super-admins?

## Future Extensions

- `portfolio.site_groups` for when 1 portfolio has 100+ sites and you want sub-grouping by region
- `ops.asset_hierarchy` using ltree for parent/child assets (chiller -> pump -> valve)
- `platform.custom_fields` for tenant-defined fields per org (EAV or JSON schema)
