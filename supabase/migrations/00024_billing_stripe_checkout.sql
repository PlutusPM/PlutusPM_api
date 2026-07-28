-- 00024_billing_stripe_checkout.sql
-- Stage 6 (SQL half) of PlutusPM_dashboard BUSINESS_RULES.md gap closure: the DB-side pieces
-- Stripe checkout/webhook Edge Functions need. Signature verification and secret handling stay
-- in the Edge Functions (Deno runtime) - this migration only holds the table and the thin
-- DB-state-transition RPC the verified webhook calls into.

-----------------------------
-- TENANT.CHECKOUT_SESSIONS
-----------------------------
create table tenant.checkout_sessions (
  id uuid primary key default uuid_generate_v4(),
  billing_request_id uuid not null references tenant.billing_requests(id) on delete cascade,
  stripe_session_id text not null unique,
  status text not null default 'ready' check (status in ('ready', 'completed', 'expired')),
  url text,
  expires_at timestamptz,
  created_at timestamptz default now() not null
);

create index idx_checkout_sessions_billing_request on tenant.checkout_sessions(billing_request_id);

alter table tenant.checkout_sessions enable row level security;

create policy "View checkout sessions if can view billing request"
on tenant.checkout_sessions for select
using (exists (
  select 1 from tenant.billing_requests br
  where br.id = checkout_sessions.billing_request_id
  and (platform.is_site_manager(br.site_id) or platform.is_org_admin(br.org_id) or tenant.is_tenant_contact(br.tenant_id))
));

create policy "Managers manage checkout sessions"
on tenant.checkout_sessions for all
using (exists (
  select 1 from tenant.billing_requests br
  where br.id = checkout_sessions.billing_request_id
  and (platform.is_site_manager(br.site_id) or platform.is_org_admin(br.org_id))
));

select platform.attach_audit_trigger('tenant', 'checkout_sessions');

do $$ begin
  alter publication supabase_realtime add table tenant.checkout_sessions;
exception when duplicate_object then null;
end $$;

-----------------------------
-- RPC: apply_stripe_webhook_event
-- Called ONLY by the stripe-webhook Edge Function, AFTER it has verified the Stripe-Signature
-- header - this function does not and cannot verify anything itself, so it must never be
-- reachable from a user JWT. Correlates via payment_intent_data.metadata.billing_request_id
-- (set at checkout-session creation time) for payment_intent.* events, or via
-- billing_requests.stripe_invoice_id for invoice.* events.
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
begin
  v_billing_request_id := nullif(v_object -> 'metadata' ->> 'billing_request_id', '')::uuid;

  if v_billing_request_id is null and p_event_type in ('invoice.paid', 'invoice.payment_failed') then
    select id into v_billing_request_id from tenant.billing_requests where stripe_invoice_id = v_object ->> 'id';
  end if;

  if v_billing_request_id is null then
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

  return jsonb_build_object('handled', true, 'billing_request_id', v_billing_request_id, 'event_type', p_event_type);
end;
$$;

-- Deliberately NOT graphql-exposed (no @graphql comment) and NOT reachable via PostgREST's
-- default anon/authenticated grants below - see the revoke immediately after the grant block.

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated, service_role;
grant usage on all sequences in schema tenant to anon, authenticated, service_role;

-- apply_stripe_webhook_event must only be callable by the service-role Edge Function, never by
-- an end-user JWT (it trusts its input completely - signature verification already happened in
-- the Edge Function before this is called). REVOKE FROM PUBLIC, not just anon/authenticated:
-- Postgres grants EXECUTE to the implicit PUBLIC pseudo-role by default on function creation,
-- and every role (including anon/authenticated) inherits that - revoking only the named roles
-- would leave the PUBLIC grant in effect and the function callable anyway.
revoke execute on function platform.apply_stripe_webhook_event(text, jsonb) from public;
grant execute on function platform.apply_stripe_webhook_event(text, jsonb) to service_role;
