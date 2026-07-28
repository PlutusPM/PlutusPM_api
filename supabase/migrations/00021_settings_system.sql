-- 00021_settings_system.sql
-- Stage 3 of PlutusPM_dashboard BUSINESS_RULES.md gap closure: structured, typed settings with
-- org-default + site-override resolution (API_SPEC.md's Management - Settings section).
-- Distinct from platform.configurations (00018_security_hardening.sql), which is a flatter,
-- admin-only, org-or-global key/value store for internal platform config (security/integrations/
-- graphql-type settings, some secret). This system is the product-facing, typed settings surface
-- (setting_definitions + resolvable org/site overrides) - the two are left to coexist.

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type platform.setting_type_enum as enum ('boolean', 'string', 'number', 'enum', 'json');
exception when duplicate_object then null;
end $$;

-----------------------------
-- PLATFORM.SETTING_DEFINITIONS
-----------------------------
create table platform.setting_definitions (
  id uuid primary key default uuid_generate_v4(),
  key text unique not null,
  label text not null,
  description text,
  type platform.setting_type_enum not null,
  default_value jsonb,
  validation_rules jsonb default '{}'::jsonb,
  category text not null default 'general',
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_setting_definitions_category on platform.setting_definitions(category);

create trigger set_setting_definitions_updated_at
  before update on platform.setting_definitions
  for each row execute function public.handle_updated_at();

alter table platform.setting_definitions enable row level security;

create policy "Setting definitions are readable by anyone"
on platform.setting_definitions for select
using (true);

create policy "Org admins manage setting definitions"
on platform.setting_definitions for insert
with check (platform.is_super_admin());

create policy "Org admins update setting definitions"
on platform.setting_definitions for update
using (platform.is_super_admin());

create policy "Org admins delete setting definitions"
on platform.setting_definitions for delete
using (platform.is_super_admin());

select platform.attach_audit_trigger('platform', 'setting_definitions');

-----------------------------
-- PLATFORM.ORGANIZATION_SETTINGS
-----------------------------
create table platform.organization_settings (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  setting_key text not null references platform.setting_definitions(key) on delete cascade,
  value jsonb not null,
  updated_at timestamptz default now() not null,
  unique (org_id, setting_key)
);

create index idx_org_settings_org on platform.organization_settings(org_id);

create trigger set_organization_settings_updated_at
  before update on platform.organization_settings
  for each row execute function public.handle_updated_at();

alter table platform.organization_settings enable row level security;

create policy "View organization settings if org member"
on platform.organization_settings for select
using (platform.is_org_member(org_id));

create policy "Org admins manage organization settings"
on platform.organization_settings for all
using (platform.is_org_admin(org_id));

select platform.attach_audit_trigger('platform', 'organization_settings');

-----------------------------
-- PORTFOLIO.SITE_SETTINGS
-----------------------------
create table portfolio.site_settings (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  setting_key text not null references platform.setting_definitions(key) on delete cascade,
  value jsonb not null,
  updated_at timestamptz default now() not null,
  unique (site_id, setting_key)
);

create index idx_site_settings_site on portfolio.site_settings(site_id);

create trigger set_site_settings_updated_at
  before update on portfolio.site_settings
  for each row execute function public.handle_updated_at();

alter table portfolio.site_settings enable row level security;

create policy "View site settings if can access site"
on portfolio.site_settings for select
using (platform.can_access_site(site_id));

create policy "Site managers manage site settings"
on portfolio.site_settings for all
using (platform.is_site_manager(site_id) or platform.is_org_admin((select org_id from portfolio.sites where id = site_id)));

select platform.attach_audit_trigger('portfolio', 'site_settings');

-----------------------------
-- RESOLUTION RPC: default_value <- organization_settings <- site_settings
-----------------------------
create or replace function platform.get_resolved_settings(p_site_id uuid, p_category text default null)
returns jsonb
language plpgsql
security definer
set search_path = platform, portfolio, public
as $$
declare
  v_org_id uuid;
  v_result jsonb;
begin
  if not platform.can_access_site(p_site_id) then raise exception 'Access denied to site'; end if;
  select org_id into v_org_id from portfolio.sites where id = p_site_id;

  select coalesce(jsonb_object_agg(key, resolved_value), '{}'::jsonb) into v_result
  from (
    select
      sd.key,
      coalesce(ss.value, os.value, sd.default_value) as resolved_value
    from platform.setting_definitions sd
    left join platform.organization_settings os on os.org_id = v_org_id and os.setting_key = sd.key
    left join portfolio.site_settings ss on ss.site_id = p_site_id and ss.setting_key = sd.key
    where p_category is null or sd.category = p_category
  ) resolved
  where resolved_value is not null;

  return v_result;
end;
$$;

comment on function platform.get_resolved_settings(uuid, text) is '@graphql({"type": "query", "name": "getResolvedSettings"})';

-----------------------------
-- SEED: billing-related setting definitions (needed by Stage 5's billing domain)
-----------------------------
insert into platform.setting_definitions (key, label, description, type, default_value, validation_rules, category)
values
  ('billing_grace_period_days', 'Billing Grace Period (Days)', 'Number of days after due date before marking overdue', 'number', '5'::jsonb, '{"min":0,"max":30}'::jsonb, 'billing'),
  ('billing_auto_send_enabled', 'Auto-Send Recurring Billing', 'Automatically send generated billing requests instead of leaving them as drafts', 'boolean', 'false'::jsonb, '{}'::jsonb, 'billing'),
  ('billing_reminder_days_before', 'Billing Reminder (Days Before Due)', 'Number of days before the due date to send a payment reminder', 'number', '7'::jsonb, '{"min":0,"max":30}'::jsonb, 'billing')
on conflict (key) do nothing;

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema platform to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema platform to authenticated, service_role;
grant usage on all sequences in schema platform to anon, authenticated, service_role;

grant select on all tables in schema portfolio to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema portfolio to authenticated, service_role;
grant usage on all sequences in schema portfolio to anon, authenticated, service_role;
