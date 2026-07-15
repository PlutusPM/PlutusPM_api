# Scheduler Strategy - pg_cron + Edge Functions

## Requirement
Commercial Real Estate SaaS needs lots of background jobs:
- Preventive Maintenance auto-generation
- SLA breach detection
- COI expiration monitoring (30/60/90 days)
- Visitor pass expiration / cleanup
- Daily/weekly analytics rollups
- Scheduled reports email
- Lease expiration reminders
- Inventory reorder alerts

## Chosen Solution: pg_cron (Native) + pg_net + Supabase Scheduled Functions

### Why not ...?
- **BullMQ/Redis:** Extra infra, cost, not needed - Postgres is your queue
- **Temporal / Inngest:** Powerful but overkill for MVP, added complexity
- **External cron (cron-job.org):** OK but pg_cron is already inside Supabase

Supabase has `pg_cron` enabled on all paid projects (and local). It's Postgres-native, reliable, observable via `cron.job_run_details`.

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────────┐
│  pg_cron    │────▶│  pg_net HTTP │────▶│  Edge Function      │
│  (schedule) │     │  (async call)│     │  (complex logic)    │
└─────────────┘     └──────────────┘     └─────────────────────┘
       │                                           │
       │ Direct SQL jobs                           │ External APIs
       ▼                                           ▼
┌─────────────┐                           ┌──────────────┐
│ SQL Job:    │                           │ SendGrid,    │
│ UPDATE,     │                           │ Slack, Stripe│
│ CALL proc() │                           │ etc.         │
└─────────────┘                           └──────────────┘
```

## Setup

### 1. Enable Extensions

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;
```

For Supabase cloud, pg_cron is already installed but needs:
```sql
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;
```

### 2. Examples - Direct SQL Cron Jobs

```sql
-- Every 15 minutes: SLA breach detection
select cron.schedule(
  'check-sla-breaches',
  '*/15 * * * *',
  $$
  update ops.work_orders
  set status = 'overdue', metadata = metadata || '{"sla_breached": true}'::jsonb
  where status not in ('completed', 'cancelled')
    and sla_due_at < now()
    and metadata->>'sla_breached' is null;

  insert into platform.notifications (org_id, site_id, type, payload)
  select org_id, site_id, 'sla_breach',
         jsonb_build_object('work_order_id', id, 'title', title)
  from ops.work_orders
  where status = 'overdue' and updated_at > now() - interval '15 minutes';
  $$
);

-- Daily at 2 AM UTC: Generate PM work orders from templates
select cron.schedule(
  'generate-pm-work-orders',
  '0 2 * * *',
  $$ select ops.generate_pm_work_orders(); $$
);

-- Daily at 3 AM: Rollup metrics
select cron.schedule(
  'rollup-daily-metrics',
  '0 3 * * *',
  $$ select metrics.rollup_daily_stats(current_date - 1); $$
);

-- Hourly: COI expiring check
select cron.schedule(
  'check-coi-expiration',
  '0 * * * *',
  $$ select vendor.check_coi_expirations(); $$
);

-- Daily cleanup: Visitor passes expired > 30 days
select cron.schedule(
  'cleanup-expired-passes',
  '0 4 * * *',
  $$
  delete from visitor.passes where expires_at < now() - interval '30 days';
  delete from visitor.visits where status = 'checked_out' and checked_out_at < now() - interval '90 days' and site_id in (select id from portfolio.sites where metadata->>'auto_cleanup' = 'true');
  $$
);
```

### 3. Calling Edge Functions from Cron (for external APIs)

When job needs to call SendGrid, Slack, Stripe, or complex JS logic.

```sql
-- Daily 9 AM: Compliance checks + notify via Edge Function
select cron.schedule(
  'trigger-compliance-check',
  '0 9 * * *',
  $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/compliance-daily-check',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.service_role_key')
    ),
    body := jsonb_build_object('triggered_by', 'pg_cron')
  ) as request_id;
  $$
);
```

### 4. Supabase Scheduled Edge Functions (Alternative syntax)

In `supabase/config.toml` newer versions support:

```toml
[functions.compliance-daily-check]
enabled = true
verify_jwt = false
schedule = "0 9 * * *"  # cron expression
```

This is actually deployed as pg_cron under the hood, but managed via CLI. Use whichever you prefer - SQL version gives more control.

### 5. Edge Function Example: compliance-daily-check

```typescript
// supabase/functions/compliance-daily-check/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  // 1. Find COIs expiring in 30/60/90 days
  const { data: expiringCois } = await supabase.rpc('vendor_get_expiring_cois', { days: 30 })

  // 2. Group by org/site/vendor
  // 3. Send emails via Resend/SendGrid, Slack notifications
  // 4. Create notifications

  for (const coi of expiringCois) {
    await supabase.from('platform.notifications').insert({
      org_id: coi.org_id,
      site_id: coi.site_id,
      type: 'coi_expiring',
      payload: { coi_id: coi.id, vendor: coi.vendor_name, days_left: coi.days_left }
    })
  }

  return new Response(JSON.stringify({ processed: expiringCois.length }), { status: 200 })
})
```

### 6. Functions you will need to write Postgres side

```sql
-- ops.generate_pm_work_orders()
-- Loops through templates where next_due_date <= today, creates work_order, updates next_due

-- vendor.check_coi_expirations()
-- Updates status to expiring/expired, inserts notifications

-- metrics.rollup_daily_stats(p_date date)
-- INSERT INTO daily_site_stats SELECT count(*) etc FROM work_orders WHERE created_at::date = p_date

-- platform.cleanup_old_audit_logs()
-- Keep 90 days hot, archive rest to storage jsonl maybe
```

### 7. Monitoring & Observability

```sql
-- See all cron jobs
select * from cron.job;

-- See run history (last 10 runs)
select * from cron.job_run_details order by start_time desc limit 20;

-- See pg_net request queue
select * from net.http_request_queue;

-- Failed jobs
select * from cron.job_run_details where status = 'failed' order by start_time desc;
```

We will create a `metrics.cron_health` view for dashboard.

### 8. Testing Cron Locally

With Supabase CLI:

```bash
supabase start  # includes pg_cron
supabase db reset # applies migrations, including cron schedules

# Note: pg_cron won't run in local unless you enable: set cron.database_name?
# For local testing, manually call: select ops.generate_pm_work_orders();
```

Or use `supabase/functions serve --debug` and hit endpoint manually.

### 9. Future Scaling

If you outgrow pg_cron (1000s jobs/sec):
- Migrate to `pgmq` (Postgres Message Queue - Supabase extension, AWS SQS-like)
- Or Supabase Queues (beta) + Edge Functions
- But pg_cron handles <10k jobs/day easily - sufficient for CRE SaaS with 100s of sites.

## Recommended Initial Crons for MVP

| Job | Schedule | Type |
|-----|----------|------|
| SLA breach check | */15 * * * * | SQL |
| Generate PM WOs | 0 2 * * * | SQL function |
| COI expiration scan | 0 8 * * * | SQL + Edge notify |
| Daily metrics rollup | 0 3 * * * | SQL |
| Visitor pass cleanup | 0 4 * * * | SQL |
| Overdue lease check | 0 9 * * 1 | SQL |
| Audit log archive | 0 5 * * 0 (Sun) | SQL + storage |
| Scheduled report emails | 0 7 * * 1 | Edge Function |

All defined in `supabase/migrations/xxxx_scheduler.sql`
