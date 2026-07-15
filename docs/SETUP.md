# Setup Instructions - CRE SaaS Supabase Backend

## Prerequisites

- Supabase CLI: `brew install supabase/tap/supabase` or `npm i -g supabase`
- Docker (for local supabase start)
- Node 18+ (for Edge Functions if you want to test locally with Deno, but Deno is bundled in Supabase CLI)

## Local Development

```bash
# Clone (you're already in repo)
# Ensure .env exists? Not needed for local, supabase start generates keys

# Start Supabase stack
supabase start

# Expected output:
# Started supabase local development setup.
# API URL: http://127.0.0.1:54321
# GraphQL URL: http://127.0.0.1:54321/graphql/v1
# DB URL: postgresql://postgres:postgres@127.0.0.1:54322/postgres
# Studio URL: http://127.0.0.1:54323
# ...

# Check status
supabase status

# Apply migrations (auto-applied on start, but to be explicit)
supabase migration list
supabase db reset # drops and re-applies all migrations + seed

# Serve Edge Functions
supabase functions serve --env-file .env.example --debug --import-map supabase/functions/import_map.json

# In another terminal, test health
curl http://127.0.0.1:54321/functions/v1/health -H "apikey: <anon_key_from_start>"
```

## Create Your First User & Seed

Option A: Via Studio (http://127.0.0.1:54323)

1. Go to Authentication > Users > Add User (create demo@cre.local / password123)
2. Copy user ID
3. Go to SQL Editor, run:

```sql
-- Ensure profile
insert into platform.profiles (id, email, full_name) 
values ('USER_ID', 'demo@cre.local', 'Demo Admin')
on conflict (id) do nothing;

-- Create org
select platform.create_organization('Demo CRE Co', 'demo-cre');

-- Run seed file content (copy from supabase/migrations/00006_seed_demo.sql)
```

Option B: Via API

```bash
curl -X POST http://127.0.0.1:54321/auth/v1/signup \
  -H "apikey: <anon>" \
  -H "Content-Type: application/json" \
  -d '{"email": "demo@cre.local", "password": "password123", "data": {"full_name": "Demo Admin"}}'
```

Then run seed.

## Cloud Deployment

```bash
supabase link --project-ref your-project-ref-from-dashboard

# Push migrations
supabase db push

# Deploy functions
supabase functions deploy health
supabase functions deploy compliance-daily-check
supabase functions deploy generate-qr
supabase functions deploy send-visitor-pass

# Set secrets
supabase secrets set RESEND_API_KEY=re_xxx --project-ref your-ref
supabase secrets set SLACK_WEBHOOK_URL=https://hooks.slack.com/... --project-ref your-ref
supabase secrets set SUPABASE_URL=https://your-ref.supabase.co --project-ref your-ref
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=your-service-role --project-ref your-ref

# List secrets
supabase secrets list --project-ref your-ref

# Check cron jobs
# In dashboard SQL Editor:
select * from cron.job;
select * from cron.job_run_details order by start_time desc limit 10;
```

## GraphQL Testing

Supabase does not yet ship GraphiQL in Studio. Use:

- https://graphiql-online.com/ 
  - Endpoint: http://127.0.0.1:54321/graphql/v1 (local) or https://<ref>.supabase.co/graphql/v1
  - Headers: `apikey: <anon>`, `Authorization: Bearer <jwt>`

To get JWT:

```ts
const { data } = await supabase.auth.signInWithPassword({ email, password })
console.log(data.session.access_token)
```

Use that token as Bearer.

## Storage Testing

```ts
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(url, anon, { auth: { persistSession: true } })

await supabase.auth.signInWithPassword({...})

const file = new File(['hello'], 'test.txt')
const path = `${orgId}/${siteId}/test.txt`
const { data, error } = await supabase.storage.from('site-files').upload(path, file)
console.log(data, error)

const { data: signed } = await supabase.storage.from('site-files').createSignedUrl(path, 60)
console.log(signed.signedUrl)
```

## Realtime Testing

```ts
supabase.channel('test')
  .on('postgres_changes', { event: '*', schema: 'ops', table: 'work_orders' }, payload => console.log(payload))
  .subscribe()
```

In another tab, create work order via SQL:

```sql
select ops.create_work_order((select id from portfolio.sites limit 1), 'Test WO', 'Test', null, null);
```

Should see realtime event.

## Generating Types

```bash
supabase gen types typescript --local > src/types/supabase.ts
# or for cloud
supabase gen types typescript --project-id your-ref --schema public,platform,portfolio,ops,tenant,visitor,vendor,metrics > types.ts
```

This gives TypeScript types for your frontend dev.

## Troubleshooting

- `pg_cron` not running locally? Check `supabase status` - should show Inbucket etc. Cron is enabled by default via supabase start. If jobs don't fire, call function manually: `select ops.check_sla_breaches();`
- `storage.objects` RLS errors: Ensure you are authenticated and folder path is `org_id/site_id/...` with valid UUIDs you belong to
- GraphQL returns empty: RLS - ensure memberships entry exists for your user with site_ids null or containing that site
- Edge Functions 401: Check verify_jwt in config.toml - health and compliance have verify false, qr and visitor have true (need Authorization header)

## What's Next

See `README.md` for architecture and `docs/` for frontend guide.
