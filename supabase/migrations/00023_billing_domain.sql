-- 00023_billing_domain.sql
-- Stage 5 of PlutusPM_dashboard BUSINESS_RULES.md gap closure: the billing domain schema and
-- SQL-only RPCs. Zero billing tables existed before this migration. Stripe network calls
-- (checkout sessions, webhook signature verification) are deliberately NOT here - that's Stage
-- 6's Edge Functions; this migration only does what pure SQL can safely do.
--
-- Currency: new billing tables use integer cents (amount_cents), matching the dashboard's
-- billing types. Pre-existing decimal(12,2) money columns elsewhere (leases.monthly_rent, etc.)
-- are intentionally left untouched - no broad currency migration.

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type tenant.billing_request_status_enum as enum (
    'draft', 'scheduled', 'sent', 'open', 'paid', 'partially_paid', 'overdue', 'cancelled', 'failed'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.billing_line_item_category_enum as enum (
    'base_rent', 'parking', 'storage', 'utility_reimbursement', 'late_fee', 'other'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.billing_schedule_status_enum as enum ('active', 'paused', 'ended');
exception when duplicate_object then null;
end $$;

-----------------------------
-- TENANT.BILLING_REQUESTS
-----------------------------
create table tenant.billing_requests (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  tenant_id uuid not null references tenant.tenants(id) on delete cascade,
  space_id uuid references portfolio.spaces(id) on delete set null,
  title text not null,
  note text,
  payer_email text,
  due_date date not null,
  total_amount_cents integer not null default 0, -- kept in sync by recompute_billing_request_total()
  status tenant.billing_request_status_enum not null default 'draft',
  sent_at timestamptz,
  viewed_at timestamptz,
  paid_at timestamptz,
  stripe_checkout_url text,
  stripe_invoice_id text,
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_billing_requests_site on tenant.billing_requests(site_id);
create index idx_billing_requests_tenant on tenant.billing_requests(tenant_id);
create index idx_billing_requests_status on tenant.billing_requests(status);
create index idx_billing_requests_due_date on tenant.billing_requests(due_date);

create trigger set_billing_requests_updated_at
  before update on tenant.billing_requests
  for each row execute function public.handle_updated_at();

-----------------------------
-- TENANT.BILLING_LINE_ITEMS
-----------------------------
create table tenant.billing_line_items (
  id uuid primary key default uuid_generate_v4(),
  billing_request_id uuid not null references tenant.billing_requests(id) on delete cascade,
  label text not null,
  category tenant.billing_line_item_category_enum not null default 'other',
  amount_cents integer not null,
  created_at timestamptz default now() not null
);

create index idx_billing_line_items_request on tenant.billing_line_items(billing_request_id);

-- Request total must equal the sum of its line items - recompute-on-write, since a declarative
-- check constraint can't do cross-table aggregation.
create or replace function tenant.recompute_billing_request_total()
returns trigger
language plpgsql
security definer
set search_path = tenant, public
as $$
declare
  v_billing_request_id uuid;
  v_total integer;
begin
  v_billing_request_id := coalesce(new.billing_request_id, old.billing_request_id);
  select coalesce(sum(amount_cents), 0) into v_total
  from tenant.billing_line_items where billing_request_id = v_billing_request_id;

  update tenant.billing_requests set total_amount_cents = v_total, updated_at = now()
  where id = v_billing_request_id;

  return coalesce(new, old);
end;
$$;

create trigger trg_billing_line_items_recompute_total
  after insert or update or delete on tenant.billing_line_items
  for each row execute function tenant.recompute_billing_request_total();

-----------------------------
-- TENANT.BILLING_SCHEDULES
-----------------------------
create table tenant.billing_schedules (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  tenant_id uuid not null references tenant.tenants(id) on delete cascade,
  space_id uuid references portfolio.spaces(id) on delete set null,
  title text not null,
  cadence text not null default 'monthly' check (cadence = 'monthly'), -- BUSINESS_RULES.md: monthly only, for now
  payer_email text,
  status tenant.billing_schedule_status_enum not null default 'active',
  start_date date not null,
  end_date date,
  next_due_date date not null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_billing_schedules_site on tenant.billing_schedules(site_id);
create index idx_billing_schedules_tenant on tenant.billing_schedules(tenant_id);
create index idx_billing_schedules_status_due on tenant.billing_schedules(status, next_due_date);

create trigger set_billing_schedules_updated_at
  before update on tenant.billing_schedules
  for each row execute function public.handle_updated_at();

-----------------------------
-- TENANT.BILLING_SCHEDULE_LINE_ITEMS (template, copied onto each generated request)
-----------------------------
create table tenant.billing_schedule_line_items (
  id uuid primary key default uuid_generate_v4(),
  schedule_id uuid not null references tenant.billing_schedules(id) on delete cascade,
  label text not null,
  category tenant.billing_line_item_category_enum not null default 'other',
  amount_cents integer not null
);

create index idx_billing_schedule_line_items_schedule on tenant.billing_schedule_line_items(schedule_id);

-----------------------------
-- PLATFORM.STRIPE_CONNECTIONS
-----------------------------
create table platform.stripe_connections (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  stripe_account_id text,
  account_display_name text,
  account_email text,
  is_test_mode boolean default true,
  mode text default 'test' check (mode in ('test', 'live')),
  default_currency text default 'usd',
  webhook_status text,
  webhook_health text default 'healthy' check (webhook_health in ('healthy', 'warning', 'disconnected')),
  webhook_endpoint_label text,
  payout_label text,
  connected_at timestamptz,
  last_synced_at timestamptz,
  unique (org_id)
);

alter table platform.stripe_connections enable row level security;

create policy "View stripe connections if org member"
on platform.stripe_connections for select
using (platform.is_org_member(org_id));

create policy "Org admins manage stripe connections"
on platform.stripe_connections for all
using (platform.is_org_admin(org_id));

select platform.attach_audit_trigger('platform', 'stripe_connections');

-----------------------------
-- RLS: BILLING_REQUESTS / LINE_ITEMS / SCHEDULES / SCHEDULE_LINE_ITEMS
-- Staff (site manager or org admin) see/manage everything at their site; a tenant-portal caller
-- may only see their OWN tenant's billing (tenant.is_tenant_contact, from Stage 2's
-- 00020_tenant_documents.sql) - can_access_site alone is not enough here, same reasoning as
-- tenant document visibility.
-----------------------------
alter table tenant.billing_requests enable row level security;

create policy "View billing requests if staff or own tenant"
on tenant.billing_requests for select
using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id) or tenant.is_tenant_contact(tenant_id));

create policy "Managers manage billing requests"
on tenant.billing_requests for all
using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id));

select platform.attach_audit_trigger('tenant', 'billing_requests');

alter table tenant.billing_line_items enable row level security;

create policy "View billing line items if can view billing request"
on tenant.billing_line_items for select
using (exists (
  select 1 from tenant.billing_requests br
  where br.id = billing_line_items.billing_request_id
  and (platform.is_site_manager(br.site_id) or platform.is_org_admin(br.org_id) or tenant.is_tenant_contact(br.tenant_id))
));

create policy "Managers manage billing line items"
on tenant.billing_line_items for all
using (exists (
  select 1 from tenant.billing_requests br
  where br.id = billing_line_items.billing_request_id
  and (platform.is_site_manager(br.site_id) or platform.is_org_admin(br.org_id))
));

select platform.attach_audit_trigger('tenant', 'billing_line_items');

alter table tenant.billing_schedules enable row level security;

create policy "View billing schedules if staff or own tenant"
on tenant.billing_schedules for select
using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id) or tenant.is_tenant_contact(tenant_id));

create policy "Managers manage billing schedules"
on tenant.billing_schedules for all
using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id));

select platform.attach_audit_trigger('tenant', 'billing_schedules');

alter table tenant.billing_schedule_line_items enable row level security;

create policy "View schedule line items if can view schedule"
on tenant.billing_schedule_line_items for select
using (exists (
  select 1 from tenant.billing_schedules bs
  where bs.id = billing_schedule_line_items.schedule_id
  and (platform.is_site_manager(bs.site_id) or platform.is_org_admin(bs.org_id) or tenant.is_tenant_contact(bs.tenant_id))
));

create policy "Managers manage schedule line items"
on tenant.billing_schedule_line_items for all
using (exists (
  select 1 from tenant.billing_schedules bs
  where bs.id = billing_schedule_line_items.schedule_id
  and (platform.is_site_manager(bs.site_id) or platform.is_org_admin(bs.org_id))
));

select platform.attach_audit_trigger('tenant', 'billing_schedule_line_items');

-----------------------------
-- RPC: send_billing_request
-- DB-side precondition check + status transition only. Does not call Stripe - Stage 6's Edge
-- Function does that and writes back stripe_invoice_id/stripe_checkout_url via service role.
-----------------------------
create or replace function tenant.send_billing_request(p_billing_request_id uuid)
returns tenant.billing_requests
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
declare
  v_request tenant.billing_requests%rowtype;
begin
  select * into v_request from tenant.billing_requests where id = p_billing_request_id;
  if not found then raise exception 'Unknown billing request %', p_billing_request_id; end if;
  if not (platform.is_org_admin(v_request.org_id) or platform.is_site_manager(v_request.site_id)) then
    raise exception 'Access denied to billing request %', p_billing_request_id;
  end if;
  if v_request.payer_email is null then
    raise exception 'Cannot send billing request %: payer_email is required', p_billing_request_id;
  end if;
  if v_request.status not in ('draft', 'open') then
    raise exception 'Billing request % is not in a sendable state (%)', p_billing_request_id, v_request.status;
  end if;

  update tenant.billing_requests
  set status = 'sent', sent_at = now(), updated_at = now()
  where id = p_billing_request_id
  returning * into v_request;

  return v_request;
end;
$$;

comment on function tenant.send_billing_request(uuid) is '@graphql({"type": "mutation", "name": "sendBillingRequest"})';

-----------------------------
-- RPC: generate_recurring_billing
-- Ends a schedule (instead of generating) when the tenant no longer has an active/future
-- occupancy of the schedule's space - BUSINESS_RULES.md: "may end when a lease is expiring,
-- terminated, or otherwise no longer billable." Relies on tenant.occupancies from Stage 1.
-----------------------------
create or replace function tenant.generate_recurring_billing(p_run_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = tenant, portfolio, platform, public
as $$
declare
  v_schedule record;
  v_billing_request_id uuid;
  v_created_ids uuid[] := array[]::uuid[];
  v_created_count integer := 0;
begin
  for v_schedule in
    select * from tenant.billing_schedules
    where status = 'active' and next_due_date <= p_run_date
  loop
    if v_schedule.space_id is not null and not exists (
      select 1 from tenant.occupancies o
      where o.tenant_id = v_schedule.tenant_id
      and o.space_id = v_schedule.space_id
      and o.status in ('active', 'future')
    ) then
      update tenant.billing_schedules set status = 'ended', updated_at = now() where id = v_schedule.id;
      continue;
    end if;

    insert into tenant.billing_requests (org_id, site_id, tenant_id, space_id, title, payer_email, due_date, status)
    values (v_schedule.org_id, v_schedule.site_id, v_schedule.tenant_id, v_schedule.space_id, v_schedule.title, v_schedule.payer_email, v_schedule.next_due_date, 'draft')
    returning id into v_billing_request_id;

    insert into tenant.billing_line_items (billing_request_id, label, category, amount_cents)
    select v_billing_request_id, label, category, amount_cents
    from tenant.billing_schedule_line_items where schedule_id = v_schedule.id;

    update tenant.billing_schedules
    set next_due_date = (next_due_date + interval '1 month')::date, updated_at = now()
    where id = v_schedule.id;

    v_created_ids := v_created_ids || v_billing_request_id;
    v_created_count := v_created_count + 1;
  end loop;

  return jsonb_build_object('created_count', v_created_count, 'billing_request_ids', to_jsonb(v_created_ids));
end;
$$;

comment on function tenant.generate_recurring_billing(date) is '@graphql({"type": "mutation", "name": "generateRecurringBilling"})';

do $do$ begin
  if not exists (select 1 from cron.job where jobname = 'generate-recurring-billing') then
    perform cron.schedule('generate-recurring-billing', '0 6 1 * *', $cron$ select tenant.generate_recurring_billing(); $cron$);
  end if;
exception when others then raise notice 'cron.schedule generate-recurring-billing failed: %', SQLERRM;
end $do$;

-----------------------------
-- REALTIME
-----------------------------
do $$ begin
  alter publication supabase_realtime add table tenant.billing_requests;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table tenant.billing_schedules;
exception when duplicate_object then null;
end $$;

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated, service_role;
grant usage on all sequences in schema tenant to anon, authenticated, service_role;

grant select on all tables in schema platform to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema platform to authenticated, service_role;
grant usage on all sequences in schema platform to anon, authenticated, service_role;
