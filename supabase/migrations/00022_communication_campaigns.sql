-- 00022_communication_campaigns.sql
-- Stage 4 of PlutusPM_dashboard BUSINESS_RULES.md gap closure: communication campaigns,
-- distinct from tenant.announcements/tenant.events (00009_tenant_expansion.sql), which are
-- already implemented and untouched here. Zero tables existed for campaigns before this.

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type tenant.campaign_status_enum as enum ('draft', 'scheduled', 'sent', 'failed');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.campaign_delivery_status_enum as enum (
    'pending', 'sent', 'delivered', 'opened', 'clicked', 'bounced', 'failed'
  );
exception when duplicate_object then null;
end $$;

-----------------------------
-- TENANT.COMMUNICATION_CAMPAIGNS
-----------------------------
create table tenant.communication_campaigns (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete cascade, -- nullable: org-wide via audience_filter
  name text not null,
  subject text not null,
  body text not null,
  audience_filter jsonb default '{}'::jsonb, -- e.g. {"role": ["billing"]}, {"tenant_type": ["commercial"]}
  status tenant.campaign_status_enum not null default 'draft',
  scheduled_at timestamptz,
  sent_at timestamptz,
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_campaigns_org on tenant.communication_campaigns(org_id);
create index idx_campaigns_site on tenant.communication_campaigns(site_id);
create index idx_campaigns_status on tenant.communication_campaigns(status);

create trigger set_communication_campaigns_updated_at
  before update on tenant.communication_campaigns
  for each row execute function public.handle_updated_at();

alter table tenant.communication_campaigns enable row level security;

create policy "View campaigns if org member"
on tenant.communication_campaigns for select
using (platform.is_org_member(org_id));

create policy "Managers manage campaigns"
on tenant.communication_campaigns for all
using (platform.is_org_admin(org_id) or (site_id is not null and platform.is_site_manager(site_id)));

select platform.attach_audit_trigger('tenant', 'communication_campaigns');

-----------------------------
-- TENANT.CAMPAIGN_RECIPIENTS
-----------------------------
create table tenant.campaign_recipients (
  id uuid primary key default uuid_generate_v4(),
  campaign_id uuid not null references tenant.communication_campaigns(id) on delete cascade,
  recipient_email text not null,
  recipient_name text,
  tenant_contact_id uuid references tenant.tenant_contacts(id) on delete set null,
  status tenant.campaign_delivery_status_enum not null default 'pending',
  created_at timestamptz default now() not null
);

create index idx_campaign_recipients_campaign on tenant.campaign_recipients(campaign_id);

alter table tenant.campaign_recipients enable row level security;

create policy "View campaign recipients if can view campaign"
on tenant.campaign_recipients for select
using (exists (
  select 1 from tenant.communication_campaigns c
  where c.id = campaign_recipients.campaign_id and platform.is_org_member(c.org_id)
));

create policy "Managers manage campaign recipients"
on tenant.campaign_recipients for all
using (exists (
  select 1 from tenant.communication_campaigns c
  where c.id = campaign_recipients.campaign_id and platform.is_org_admin(c.org_id)
));

select platform.attach_audit_trigger('tenant', 'campaign_recipients');

-----------------------------
-- TENANT.CAMPAIGN_DELIVERIES (populated by inbound email-provider webhook events)
-----------------------------
create table tenant.campaign_deliveries (
  id uuid primary key default uuid_generate_v4(),
  campaign_id uuid not null references tenant.communication_campaigns(id) on delete cascade,
  recipient_email text not null,
  status tenant.campaign_delivery_status_enum not null default 'pending',
  delivered_at timestamptz,
  opened_at timestamptz,
  clicked_at timestamptz,
  bounced_at timestamptz,
  created_at timestamptz default now() not null
);

create index idx_campaign_deliveries_campaign on tenant.campaign_deliveries(campaign_id);
create index idx_campaign_deliveries_email on tenant.campaign_deliveries(recipient_email);

alter table tenant.campaign_deliveries enable row level security;

create policy "View campaign deliveries if can view campaign"
on tenant.campaign_deliveries for select
using (exists (
  select 1 from tenant.communication_campaigns c
  where c.id = campaign_deliveries.campaign_id and platform.is_org_member(c.org_id)
));

create policy "Managers manage campaign deliveries"
on tenant.campaign_deliveries for all
using (exists (
  select 1 from tenant.communication_campaigns c
  where c.id = campaign_deliveries.campaign_id and platform.is_org_admin(c.org_id)
));

select platform.attach_audit_trigger('tenant', 'campaign_deliveries');

-----------------------------
-- RPC: send_campaign
-- DB-side only: resolves audience_filter against tenant_contacts (respecting
-- receives_announcements from Stage 1), inserts campaign_recipients, marks status sent.
-- The actual email send happens in the send-campaign Edge Function, which calls this RPC
-- first for recipient resolution, then sends via the email provider.
-----------------------------
create or replace function tenant.send_campaign(p_campaign_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
declare
  v_campaign tenant.communication_campaigns%rowtype;
  v_role_filter text[];
  v_recipient_count integer;
begin
  select * into v_campaign from tenant.communication_campaigns where id = p_campaign_id;
  if not found then raise exception 'Unknown campaign %', p_campaign_id; end if;
  if not platform.is_org_admin(v_campaign.org_id) and not (v_campaign.site_id is not null and platform.is_site_manager(v_campaign.site_id)) then
    raise exception 'Access denied to campaign %', p_campaign_id;
  end if;
  if v_campaign.status = 'sent' then raise exception 'Campaign % was already sent', p_campaign_id; end if;

  select array(select jsonb_array_elements_text(v_campaign.audience_filter -> 'role')) into v_role_filter;

  insert into tenant.campaign_recipients (campaign_id, recipient_email, recipient_name, tenant_contact_id, status)
  select
    p_campaign_id,
    p.email,
    p.full_name,
    tc.id,
    'pending'
  from tenant.tenant_contacts tc
  join platform.profiles p on p.id = tc.profile_id
  join tenant.tenants t on t.id = tc.tenant_id
  where tc.receives_announcements
    and p.email is not null
    and (v_campaign.site_id is null or t.site_id = v_campaign.site_id)
    and t.org_id = v_campaign.org_id
    and (v_role_filter is null or array_length(v_role_filter, 1) is null or tc.contact_type::text = any(v_role_filter));

  get diagnostics v_recipient_count = row_count;

  update tenant.communication_campaigns set status = 'sent', sent_at = now() where id = p_campaign_id;

  return jsonb_build_object('campaign_id', p_campaign_id, 'recipient_count', v_recipient_count, 'sent_at', now(), 'status', 'sent');
end;
$$;

comment on function tenant.send_campaign(uuid) is '@graphql({"type": "mutation", "name": "sendCampaign"})';

-----------------------------
-- REALTIME
-----------------------------
do $$ begin
  alter publication supabase_realtime add table tenant.communication_campaigns;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table tenant.campaign_deliveries;
exception when duplicate_object then null;
end $$;

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated, service_role;
grant usage on all sequences in schema tenant to anon, authenticated, service_role;
