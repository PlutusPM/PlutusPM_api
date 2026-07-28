-- 00027_site_content.sql
-- Part A3 of the frontend-wiring gap closure: building narrative content shown on the tenant
-- portal's building page (front desk info, FAQs, policies, emergency guidance, etc). Building
-- documents reuse tenant.tenant_documents (00020) with tenant_id = null rather than a parallel
-- document system - no new table for those.

-----------------------------
-- PORTFOLIO.SITE_CONTENT (one row per site - narrative sections)
-----------------------------
create table portfolio.site_content (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references portfolio.sites(id) on delete cascade unique,
  overview text,
  front_desk text,
  emergency_guidance text,
  parking text,
  loading_dock text,
  deliveries text,
  security_procedures text,
  access text,
  policies text,
  updated_at timestamptz default now() not null,
  updated_by uuid references platform.profiles(id) on delete set null
);

create trigger set_site_content_updated_at
  before update on portfolio.site_content
  for each row execute function public.handle_updated_at();

alter table portfolio.site_content enable row level security;

create policy "View site content if can access site"
on portfolio.site_content for select
using (platform.can_access_site(site_id));

create policy "Managers manage site content"
on portfolio.site_content for all
using (platform.is_site_manager(site_id) or platform.is_org_admin((select org_id from portfolio.sites where id = site_id)));

select platform.attach_audit_trigger('portfolio', 'site_content');

-----------------------------
-- PORTFOLIO.SITE_CONTACTS (front desk, security, leasing, etc - not tenant.tenant_contacts)
-----------------------------
create table portfolio.site_contacts (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  label text not null,
  person_name text,
  role text,
  phone text,
  email text,
  availability text,
  is_emergency boolean default false,
  sort_order integer default 0,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_site_contacts_site on portfolio.site_contacts(site_id, sort_order);

create trigger set_site_contacts_updated_at
  before update on portfolio.site_contacts
  for each row execute function public.handle_updated_at();

alter table portfolio.site_contacts enable row level security;

create policy "View site contacts if can access site"
on portfolio.site_contacts for select
using (platform.can_access_site(site_id));

create policy "Managers manage site contacts"
on portfolio.site_contacts for all
using (platform.is_site_manager(site_id) or platform.is_org_admin((select org_id from portfolio.sites where id = site_id)));

select platform.attach_audit_trigger('portfolio', 'site_contacts');

-----------------------------
-- PORTFOLIO.SITE_FAQS
-----------------------------
create table portfolio.site_faqs (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  question text not null,
  answer text not null,
  sort_order integer default 0,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_site_faqs_site on portfolio.site_faqs(site_id, sort_order);

create trigger set_site_faqs_updated_at
  before update on portfolio.site_faqs
  for each row execute function public.handle_updated_at();

alter table portfolio.site_faqs enable row level security;

create policy "View site faqs if can access site"
on portfolio.site_faqs for select
using (platform.can_access_site(site_id));

create policy "Managers manage site faqs"
on portfolio.site_faqs for all
using (platform.is_site_manager(site_id) or platform.is_org_admin((select org_id from portfolio.sites where id = site_id)));

select platform.attach_audit_trigger('portfolio', 'site_faqs');

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema portfolio to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema portfolio to authenticated, service_role;
grant usage on all sequences in schema portfolio to anon, authenticated, service_role;
