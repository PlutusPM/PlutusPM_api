-- 00033_portfolio_settings.sql
-- Add portfolio-scoped settings between organization defaults and property overrides.

create table portfolio.portfolio_settings (
  id uuid primary key default uuid_generate_v4(),
  portfolio_id uuid not null references portfolio.portfolios(id) on delete cascade,
  setting_key text not null references platform.setting_definitions(key) on delete cascade,
  value jsonb not null,
  updated_at timestamptz default now() not null,
  unique (portfolio_id, setting_key)
);

create index idx_portfolio_settings_portfolio on portfolio.portfolio_settings(portfolio_id);

create trigger set_portfolio_settings_updated_at
  before update on portfolio.portfolio_settings
  for each row execute function public.handle_updated_at();

alter table portfolio.portfolio_settings enable row level security;

create policy "View portfolio settings if org member"
on portfolio.portfolio_settings for select
using (
  platform.is_org_member((select org_id from portfolio.portfolios where id = portfolio_id))
);

create policy "Org admins manage portfolio settings"
on portfolio.portfolio_settings for all
using (
  platform.is_org_admin((select org_id from portfolio.portfolios where id = portfolio_id))
)
with check (
  platform.is_org_admin((select org_id from portfolio.portfolios where id = portfolio_id))
);

select platform.attach_audit_trigger('portfolio', 'portfolio_settings');

grant select, insert, update, delete on portfolio.portfolio_settings to authenticated, service_role;

-- Resolution order is now: definition default <- organization <- portfolio <- property.
create or replace function platform.get_resolved_settings(p_site_id uuid, p_category text default null)
returns jsonb
language plpgsql
security definer
set search_path = platform, portfolio, public
as $$
declare
  v_org_id uuid;
  v_portfolio_id uuid;
  v_result jsonb;
begin
  if not platform.can_access_site(p_site_id) then raise exception 'Access denied to site'; end if;
  select org_id, portfolio_id into v_org_id, v_portfolio_id from portfolio.sites where id = p_site_id;

  select coalesce(jsonb_object_agg(key, resolved_value), '{}'::jsonb) into v_result
  from (
    select
      sd.key,
      coalesce(ss.value, ps.value, os.value, sd.default_value) as resolved_value
    from platform.setting_definitions sd
    left join platform.organization_settings os on os.org_id = v_org_id and os.setting_key = sd.key
    left join portfolio.portfolio_settings ps on ps.portfolio_id = v_portfolio_id and ps.setting_key = sd.key
    left join portfolio.site_settings ss on ss.site_id = p_site_id and ss.setting_key = sd.key
    where p_category is null or sd.category = p_category
  ) resolved
  where resolved_value is not null;

  return v_result;
end;
$$;
