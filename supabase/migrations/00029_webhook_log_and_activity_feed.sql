-- 00029_webhook_log_and_activity_feed.sql
-- Part A5 of the frontend-wiring gap closure: a queryable Stripe webhook event log (events were
-- processed by 00024's apply_stripe_webhook_event but never persisted anywhere queryable), and a
-- tenant-scoped activity feed sourced from dedicated triggers rather than reshaping the generic
-- platform.audit_logs diffs.

-----------------------------
-- PLATFORM.WEBHOOK_EVENTS
-----------------------------
do $$ begin
  create type platform.webhook_event_status_enum as enum ('received', 'handled', 'ignored', 'failed');
exception when duplicate_object then null;
end $$;

create table platform.webhook_events (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid references platform.organizations(id) on delete cascade,
  source text not null default 'stripe',
  event_type text not null,
  external_event_id text,
  payload jsonb not null default '{}'::jsonb,
  status platform.webhook_event_status_enum not null default 'received',
  billing_request_id uuid references tenant.billing_requests(id) on delete set null,
  created_at timestamptz default now() not null
);

create index idx_webhook_events_org on platform.webhook_events(org_id, created_at desc);
create unique index idx_webhook_events_external_id on platform.webhook_events(source, external_event_id) where external_event_id is not null;

alter table platform.webhook_events enable row level security;

create policy "Org admins view webhook events"
on platform.webhook_events for select
using (org_id is null or platform.is_org_admin(org_id));

-- No general-purpose write policy: rows are only ever written by apply_stripe_webhook_event,
-- a SECURITY DEFINER function that runs as its owner regardless of RLS (same as its writes to
-- tenant.billing_requests/checkout_sessions already do).

-----------------------------
-- ALTER: apply_stripe_webhook_event now logs to webhook_events on every call
-----------------------------
create or replace function platform.apply_stripe_webhook_event(p_event_type text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
declare
  v_object jsonb := p_payload -> 'data' -> 'object';
  v_billing_request_id uuid;
  v_org_id uuid;
  v_external_event_id text := p_payload ->> 'id';
begin
  v_billing_request_id := nullif(v_object -> 'metadata' ->> 'billing_request_id', '')::uuid;

  if v_billing_request_id is null and p_event_type in ('invoice.paid', 'invoice.payment_failed') then
    select id into v_billing_request_id from tenant.billing_requests where stripe_invoice_id = v_object ->> 'id';
  end if;

  if v_billing_request_id is null then
    insert into platform.webhook_events (org_id, source, event_type, external_event_id, payload, status, billing_request_id)
    values (null, 'stripe', p_event_type, v_external_event_id, p_payload, 'ignored', null)
    on conflict (source, external_event_id) where external_event_id is not null do nothing;

    return jsonb_build_object('handled', false, 'reason', 'no matching billing_request', 'event_type', p_event_type);
  end if;

  select org_id into v_org_id from tenant.billing_requests where id = v_billing_request_id;

  if p_event_type in ('payment_intent.succeeded', 'invoice.paid') then
    update tenant.billing_requests set status = 'paid', paid_at = now(), updated_at = now() where id = v_billing_request_id;
    update tenant.checkout_sessions set status = 'completed' where billing_request_id = v_billing_request_id and status = 'ready';
  elsif p_event_type in ('payment_intent.payment_failed', 'invoice.payment_failed') then
    update tenant.billing_requests set status = 'failed', updated_at = now() where id = v_billing_request_id;
  end if;

  update platform.stripe_connections
  set webhook_status = 'active', webhook_health = 'healthy', last_synced_at = now()
  where org_id = v_org_id;

  insert into platform.webhook_events (org_id, source, event_type, external_event_id, payload, status, billing_request_id)
  values (v_org_id, 'stripe', p_event_type, v_external_event_id, p_payload, 'handled', v_billing_request_id)
  on conflict (source, external_event_id) where external_event_id is not null do nothing;

  return jsonb_build_object('handled', true, 'billing_request_id', v_billing_request_id, 'event_type', p_event_type);
end;
$$;

-----------------------------
-- TENANT.TENANT_ACTIVITY_LOG
-----------------------------
do $$ begin
  create type tenant.tenant_activity_type_enum as enum ('occupancy', 'lease', 'document', 'portal', 'service-request', 'visitor');
exception when duplicate_object then null;
end $$;

create table tenant.tenant_activity_log (
  id uuid primary key default uuid_generate_v4(),
  tenant_id uuid not null references tenant.tenants(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  title text not null,
  detail text,
  type tenant.tenant_activity_type_enum not null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz default now() not null
);

create index idx_tenant_activity_log_tenant on tenant.tenant_activity_log(tenant_id, occurred_at desc);

alter table tenant.tenant_activity_log enable row level security;

create policy "View tenant activity if staff or own tenant"
on tenant.tenant_activity_log for select
using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id) or tenant.is_tenant_contact(tenant_id));

-----------------------------
-- TRIGGERS: populate the feed from real writes rather than reshaping generic audit_logs diffs
-----------------------------
create or replace function tenant.log_occupancy_activity()
returns trigger
language plpgsql
security definer
set search_path = tenant, public
as $$
begin
  insert into tenant.tenant_activity_log (tenant_id, org_id, site_id, title, detail, type)
  values (
    new.tenant_id, new.org_id, new.site_id,
    case when TG_OP = 'INSERT' then 'Occupancy created' else 'Occupancy updated' end,
    'Status: ' || new.status, 'occupancy'
  );
  return new;
end;
$$;

create trigger trg_occupancies_activity
  after insert or update on tenant.occupancies
  for each row execute function tenant.log_occupancy_activity();

create or replace function portfolio.log_lease_activity()
returns trigger
language plpgsql
security definer
set search_path = tenant, portfolio, public
as $$
begin
  if new.tenant_id is not null then
    insert into tenant.tenant_activity_log (tenant_id, org_id, site_id, title, detail, type)
    values (
      new.tenant_id, new.org_id, new.site_id,
      case when TG_OP = 'INSERT' then 'Lease created' else 'Lease updated' end,
      'Status: ' || new.status, 'lease'
    );
  end if;
  return new;
end;
$$;

create trigger trg_leases_activity
  after insert or update on portfolio.leases
  for each row execute function portfolio.log_lease_activity();

create or replace function tenant.log_document_activity()
returns trigger
language plpgsql
security definer
set search_path = tenant, public
as $$
begin
  if new.tenant_id is not null then
    insert into tenant.tenant_activity_log (tenant_id, org_id, site_id, title, detail, type)
    values (
      new.tenant_id, new.org_id, new.site_id,
      case when TG_OP = 'INSERT' then 'Document added: ' || new.name else 'Document updated: ' || new.name end,
      'Status: ' || new.status, 'document'
    );
  end if;
  return new;
end;
$$;

create trigger trg_tenant_documents_activity
  after insert or update on tenant.tenant_documents
  for each row execute function tenant.log_document_activity();

create or replace function tenant.log_contact_portal_activity()
returns trigger
language plpgsql
security definer
set search_path = tenant, public
as $$
begin
  if TG_OP = 'UPDATE' and new.portal_status is distinct from old.portal_status then
    insert into tenant.tenant_activity_log (tenant_id, org_id, site_id, title, detail, type)
    values (new.tenant_id, new.org_id, new.site_id, 'Portal status changed', 'Now: ' || new.portal_status, 'portal');
  end if;
  return new;
end;
$$;

create trigger trg_tenant_contacts_portal_activity
  after update on tenant.tenant_contacts
  for each row execute function tenant.log_contact_portal_activity();

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema platform to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema platform to authenticated, service_role;
grant usage on all sequences in schema platform to anon, authenticated, service_role;

grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated, service_role;
grant usage on all sequences in schema tenant to anon, authenticated, service_role;
