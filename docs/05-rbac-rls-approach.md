# RBAC & RLS - Multi-Tenant Security Model

## Goal
Organization A must NEVER see Organization B data. Site manager sees only assigned sites. Tenant user sees only own spaces.

## Model

### Memberships Table
```sql
platform.memberships (
  org_id,
  user_id,
  role, -- enum
  portfolio_ids uuid[] nullable, -- if null, all portfolios
  site_ids uuid[] nullable,      -- if null, all sites in allowed portfolios
  created_at
)
```

If `site_ids` is NULL, user can access all sites in org. If array, only those.

### Roles Enum
```sql
create type platform.org_role as enum (
  'owner',              -- billing, can delete org
  'admin',              -- full access
  'portfolio_manager',  -- manages subset portfolios
  'site_manager',       -- manages subset sites
  'building_engineer',  -- ops write, read others
  'security',           -- visitor domain
  'tenant_admin',       -- tenant company admin
  'tenant_user',        -- tenant employee
  'vendor',             -- external vendor
  'auditor'             -- read-only
);
```

Permission matrix stored as JSON? Simpler: role-based checks in functions.

### Helper Functions (SECURITY DEFINER)

```sql
-- Current user's orgs
create or replace function platform.current_org_ids() returns uuid[] ...

-- Current user's site ids (all allowed sites across orgs)
create or replace function platform.current_allowed_site_ids() returns uuid[] ...

-- Can access specific site?
create or replace function platform.can_access_site(p_site_id uuid) returns boolean
language sql security definer as $$
  select exists (
    select 1 from platform.memberships m
    where m.user_id = auth.uid()
      and (
        m.site_ids is null
        or p_site_id = any(m.site_ids)
      )
      -- Also check org of site matches membership org
      and m.org_id = (select org_id from portfolio.sites where id = p_site_id)
  );
$$;

-- Is org admin?
create or replace function platform.is_org_admin(p_org_id uuid) returns boolean ...

-- Get current org_id (from JWT or first membership)
create or replace function platform.current_org_id() returns uuid ...
```

### RLS Template (apply to EVERY table)

```sql
alter table portfolio.sites enable row level security;

create policy "Users can view sites they have access to"
on portfolio.sites for select
using (platform.can_access_site(id));

create policy "Admins can insert sites"
on portfolio.sites for insert
with check (platform.is_org_admin(org_id));

create policy "Managers can update their sites"
on portfolio.sites for update
using (platform.can_access_site(id) and platform.is_site_manager(id));

-- etc for delete
```

For tables without site_id but with org_id:

```sql
create policy "org isolation"
on platform.organizations for select
using (id = any(platform.current_org_ids()));
```

### Tenant Isolation Special Case

Tenant users: should only see spaces where their lease exists + common amenities + their own service requests.

```sql
-- tenant.service_requests RLS
using (
  -- site managers/engineers see all requests in their sites
  platform.can_access_site(site_id)
  or
  -- tenant contacts see only own requests
  tenant_contact_id in (select id from tenant.tenant_contacts where profile_id = auth.uid())
)
```

### Vendor Isolation

Vendors: external users who only see own vendor record + contracts/COIs.

Option 1: Vendors are not auth.users, but contacts - internal users upload COIs for them.
Option 2: Vendors get login via auth.users with role='vendor' and membership linking to vendor_id.

Recommend Option 1 for MVP (vendors don't login), Option 2 later.

### Super Admin

`auth.users` with `is_super_admin = true` in `platform.profiles` bypass? Implement via:

```sql
create or replace function platform.is_super_admin() returns boolean
as $$ select exists (select 1 from platform.profiles where id = auth.uid() and is_super_admin = true) $$;
```

Then in RLS policies add `or platform.is_super_admin()`.

Use sparingly.

### JWT Claims Hook

Supabase allows custom JWT claims via hook: https://supabase.com/docs/guides/auth/auth-hooks

Create function `platform.custom_claims(event jsonb)` returns jsonb -> inject `org_ids`, `site_ids`, `role`.

This makes `auth.jwt() ->> 'site_ids'` available in RLS without extra query - faster. But we can start with helper functions querying memberships, it's fine for <1M rows.

### Audit Logs

Trigger on all tables after insert/update/delete -> insert into `platform.audit_logs` with old/new diff.

Use `supabase_audit` extension? We build simple trigger.

### Frontend Implications (for your dev)

Frontend never needs to manage RLS - it just queries. If 403/empty, means no access. Frontend should:

- Store user's memberships after login
- For site selector, query `portfolio.sitesCollection` - RLS returns only allowed sites, so dropdown auto-filtered
- For role UI, check `platform.memberships` role to show/hide buttons (but backend still enforces)

### Testing RLS

We will provide `sql/test-rls.sql`:

- Create 2 test users in auth.users
- Assign to different orgs/sites
- Set `set local role authenticated; set local request.jwt.claim.sub = '<user1 uuid>';` to simulate
- Query sites - should only see allowed

Critical to test before prod.

### Summary Decision

- **RBAC storage:** platform.memberships with site_ids[] + role
- **Enforcement:** RLS + helper SECURITY DEFINER functions
- **Tenant/Vendor:** special RLS paths
- **Super admin:** flag in profiles
- **JWT hook:** phase 2 optimization
```
Frontend can't bypass. Even GraphQL can't bypass. Secure by default.
```
