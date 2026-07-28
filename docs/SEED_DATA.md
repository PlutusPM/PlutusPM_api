# Seed Data

`supabase/seed.sql` is picked up automatically by the Supabase CLI's `db reset` convention: any file at that exact path runs once, after every migration has been applied, on every `supabase db reset`. No manual steps, no separate `psql -f` calls, no "run these 5 files in this order."

```bash
supabase db reset
```

That single command gives you a fully populated, login-ready environment.

## Why this file exists

Migrations `00006_seed_demo.sql`, `00008`, `00011`, `00013`, and `00015` (the "Phase N Seed" migrations) predate this file and are **effectively dead code on a fresh reset**. `00006` opens with:

```sql
select id into demo_user_id from auth.users limit 1;
if demo_user_id is null then
  raise notice 'No auth.users found, skipping seed - create a user first';
  return;
end if;
```

`auth.users` is always empty at the point migrations run during `db reset` (migrations run before any seed step, and nothing else creates a user first), so this block — and every seed migration chained after it — silently no-ops. They were only ever exercised by manually running them against a database where a user had *already* been created by hand, which is exactly the multi-step manual flow this file replaces. Those migrations are left in place (they're harmless no-ops) but should not be treated as documentation of what a fresh `db reset` gives you — `seed.sql` is.

`seed.sql` also covers every table added in migrations `00019`–`00030` (tenant occupancy/lease model, tenant documents, settings, communication campaigns, billing + Stripe, documentation/KB, site content, tenant bulk import, webhook log + activity feed), none of which the old seed migrations know about.

## Login accounts

Password is `password123` for all four:

| Email | Role | Scope |
|---|---|---|
| `demo@cre.local` | `owner` | Full org access |
| `manager2@cre.local` | `site_manager` | Scoped to One Commerce Plaza only |
| `tenant@cre.local` | `tenant_admin` | Tenant portal — Horizon Financial Group (Suite 820) |
| `tenant2@cre.local` | `tenant_admin` | Tenant portal — Northstar Legal (Suite 1015) |

These are inserted directly into `auth.users` / `auth.identities` (not via the signup API — `seed.sql` is plain SQL with no HTTP access). Two things GoTrue requires that are easy to miss when doing this by hand:

- `confirmation_token`, `recovery_token`, `email_change_token_new`, `email_change`, `email_change_token_current`, `phone_change`, `phone_change_token`, and `reauthentication_token` must be empty strings (`''`), not `NULL` — GoTrue's Go driver scans these as non-nullable strings and every password-grant login fails with `"Database error querying schema"` / `converting NULL to string is unsupported` if any are left `NULL`.
- A tenant-portal login needs a `platform.memberships` row (role `tenant_admin` or `tenant_user`, `site_ids` scoped to their site) in addition to a `tenant.tenant_contacts` row. `requireTenantBackendContext()` (dashboard's `app/_services/tenant-context.ts`) reads `org_id` off the membership, not off the tenant record — a tenant contact with no membership row gets `BackendAuthError: "The current user does not have a backend membership."` on every tenant portal page.

## What's seeded

One org ("Meridian Commercial Properties"), one portfolio, two sites:

- **One Commerce Plaza** (office, Charlotte NC) — the primary, richly-populated site
- **Riverside Retail Center** (retail, Charlotte NC) — secondary site, for portfolio-level / multi-site testing

| Domain | Coverage |
|---|---|
| Portfolio structure | 2 buildings, 6 floors, 18 spaces spanning every `space_type` and most `space_status` values (vacant, occupied, reserved, maintenance, out_of_service, available_soon) |
| Site content | Narrative overview/front-desk/emergency/parking/etc. for One Commerce Plaza, 3 site contacts, 3 FAQs, org + site setting overrides |
| Tenants | 6 tenants; leases/occupancies covering `active`, `month_to_month`, `future` (upcoming move-in), and `ended` (past move-out) states; 6 tenant documents with versions (lease, COI, handbook ack) in `current`/`expiring_soon`/`expired` states |
| Operations | 6 asset categories, 6 assets, 2 checklists with items, 10 work orders spanning every `work_order_status`, 2 inspections, 2 incidents, 3 work order (PM) templates |
| Inventory | 5 items across 3 categories, including one deliberately at `quantity = 0` (out of stock) and one below its `min_stock_level` (low stock) so the Inventory module's status badges all have something to render |
| Vendors | 4 vendors, 4 contracts, 4 COIs across `valid`/`expiring`/`expired`, compliance status including one `non_compliant` vendor |
| Visitors | 4 visitors, visits across `preregistered`/`checked_in`/`checked_out`/`cancelled`, passes, 2 access devices, 5 access log entries across `granted`/`denied`/`tailgate`/`forced` |
| Tenant experience | 3 amenities, 4 reservations (`confirmed`/`pending`/`cancelled`), 4 announcements, 3 events with RSVPs, 4 service requests |
| Communications | 3 campaigns (`draft`/`scheduled`/`sent`) with recipients and deliveries |
| Billing | 4 billing requests (`draft`/`sent`/`overdue`/`paid`), 2 billing schedules, 1 Stripe connection, 1 checkout session, 2 webhook events |
| Documentation | 5 KB articles across categories/statuses, versions, entity links |
| Metrics | 7 days of `daily_site_stats`, 1 day of `portfolio_daily_stats`, 3 KPI definitions |

Nothing seeded is a placeholder value — company names, addresses, dollar amounts, and dates are all realistic and internally consistent (e.g. a tenant's billing request references a real lease/space, a work order's `asset_id` points at a real asset that exists on the same site).

## Design notes

- **Deterministic IDs.** Every row's `id` is `uuid_generate_v5(namespace, "readable:key")` (see the `uid()` helper at the top of the generator), not `gen_random_uuid()`. Re-running `db reset` produces byte-identical IDs every time, which makes it safe to hardcode a specific tenant/work-order/etc. ID in a manual test or a bug report and have it still resolve after a reset.
- **`on conflict do nothing`** on every insert. The file is safe to run more than once against the same database (though in practice `db reset` always starts from an empty database).
- **Triggers fire normally.** Because these are ordinary `INSERT`s (not a bypass of any kind), the activity-log triggers added in `00029` (`trg_occupancies_activity`, `trg_leases_activity`, `trg_tenant_documents_activity`) populate `tenant.tenant_activity_log` for free — you don't need to seed that table directly.
- **Not seeded:** `tenant.community_posts`/`community_comments`/`community_likes`, `tenant.parking_permits`, `tenant.feedback` — confirmed via a grep of the dashboard's `_services` and `_components` directories that no frontend page reads these tables, so there's nothing to test against them yet.

## Extending it

The generator script used to build `seed.sql` (deterministic `uid()` helper, per-domain `sql()` sections) is not checked in — it was a one-off authoring tool, not a build step. To add more fixture data, edit `supabase/seed.sql` directly with the same conventions: hardcode a readable, stable UUID per new row (or reuse `uuid_generate_v4()` if you don't need it to be deterministic), respect the FK/enum constraints documented in the migration that created the table, and re-run `supabase db reset` to verify.
