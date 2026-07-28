-- 00026_documentation_kb.sql
-- Part A2 of the frontend-wiring gap closure: an internal SOP/policy/playbook knowledge base.
-- Distinct from tenant.tenant_documents (00020, lease/COI/compliance files) - this is narrative
-- content (articles), not uploaded files with versions-as-binaries.

-----------------------------
-- ENUMS
-----------------------------
do $$ begin
  create type platform.kb_category_enum as enum (
    'sop', 'policy', 'onboarding', 'compliance', 'emergency', 'communication', 'billing', 'operations'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type platform.kb_status_enum as enum ('published', 'draft', 'needs_review', 'archived');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type platform.kb_visibility_enum as enum ('admin_only', 'management', 'tenant_admin', 'vendors');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type platform.kb_entity_type_enum as enum ('property', 'tenant', 'space', 'lease');
exception when duplicate_object then null;
end $$;

-----------------------------
-- PLATFORM.KB_ARTICLES
-----------------------------
create table platform.kb_articles (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete cascade, -- nullable: org-wide or site-specific
  title text not null,
  slug text not null,
  category platform.kb_category_enum not null default 'sop',
  status platform.kb_status_enum not null default 'draft',
  visibility platform.kb_visibility_enum not null default 'management',
  owner_id uuid references platform.profiles(id) on delete set null,
  summary text,
  content text not null default '',
  tags text[] default array[]::text[],
  review_date date,
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique (org_id, slug)
);

create index idx_kb_articles_org on platform.kb_articles(org_id);
create index idx_kb_articles_site on platform.kb_articles(site_id);
create index idx_kb_articles_category on platform.kb_articles(category);
create index idx_kb_articles_tags on platform.kb_articles using gin (tags);

create trigger set_kb_articles_updated_at
  before update on platform.kb_articles
  for each row execute function public.handle_updated_at();

-----------------------------
-- PLATFORM.KB_ARTICLE_VERSIONS
-----------------------------
create table platform.kb_article_versions (
  id uuid primary key default uuid_generate_v4(),
  article_id uuid not null references platform.kb_articles(id) on delete cascade,
  label text not null,
  note text,
  author_id uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null
);

create index idx_kb_article_versions_article on platform.kb_article_versions(article_id, created_at desc);

-----------------------------
-- PLATFORM.KB_ARTICLE_LINKS
-- label/href are a frontend rendering concern - resolved by looking up entity_id against the
-- right table for entity_type, not stored here.
-----------------------------
create table platform.kb_article_links (
  id uuid primary key default uuid_generate_v4(),
  article_id uuid not null references platform.kb_articles(id) on delete cascade,
  entity_type platform.kb_entity_type_enum not null,
  entity_id uuid not null,
  created_at timestamptz default now() not null,
  unique (article_id, entity_type, entity_id)
);

create index idx_kb_article_links_article on platform.kb_article_links(article_id);
create index idx_kb_article_links_entity on platform.kb_article_links(entity_type, entity_id);

-----------------------------
-- RLS: visibility-tier check
-- 'admin_only' -> org admins only. 'management' -> any staff membership role (excludes the
-- external-facing tenant_admin/tenant_user/vendor roles). 'tenant_admin'/'vendors' -> staff
-- (broad internal visibility) plus the matching external role. Grounded in the actual
-- platform.org_role enum (00001_platform.sql) rather than a separate ad hoc permission model.
-----------------------------
create or replace function platform.can_view_kb_article(p_article_id uuid)
returns boolean
language plpgsql
security definer
set search_path = platform, public
as $$
declare
  a platform.kb_articles%rowtype;
  v_role platform.org_role;
begin
  select * into a from platform.kb_articles where id = p_article_id;
  if not found then return false; end if;
  if platform.is_org_admin(a.org_id) then return true; end if;

  select role into v_role from platform.memberships where user_id = auth.uid() and org_id = a.org_id limit 1;
  if v_role is null then return false; end if;

  return case a.visibility
    when 'management' then v_role not in ('tenant_admin', 'tenant_user', 'vendor')
    when 'tenant_admin' then v_role = 'tenant_admin' or v_role not in ('tenant_user', 'vendor')
    when 'vendors' then v_role = 'vendor' or v_role not in ('tenant_admin', 'tenant_user')
    else false -- admin_only already handled above
  end;
end;
$$;

comment on function platform.can_view_kb_article(uuid) is '@graphql({"type": "query", "name": "canViewKbArticle"})';

alter table platform.kb_articles enable row level security;

create policy "View kb articles per visibility"
on platform.kb_articles for select
using (platform.can_view_kb_article(id));

create policy "Org admins manage kb articles"
on platform.kb_articles for all
using (platform.is_org_admin(org_id));

select platform.attach_audit_trigger('platform', 'kb_articles');

alter table platform.kb_article_versions enable row level security;

create policy "View kb article versions per visibility"
on platform.kb_article_versions for select
using (exists (
  select 1 from platform.kb_articles a
  where a.id = kb_article_versions.article_id and platform.can_view_kb_article(a.id)
));

create policy "Org admins manage kb article versions"
on platform.kb_article_versions for all
using (exists (
  select 1 from platform.kb_articles a
  where a.id = kb_article_versions.article_id and platform.is_org_admin(a.org_id)
));

alter table platform.kb_article_links enable row level security;

create policy "View kb article links per visibility"
on platform.kb_article_links for select
using (exists (
  select 1 from platform.kb_articles a
  where a.id = kb_article_links.article_id and platform.can_view_kb_article(a.id)
));

create policy "Org admins manage kb article links"
on platform.kb_article_links for all
using (exists (
  select 1 from platform.kb_articles a
  where a.id = kb_article_links.article_id and platform.is_org_admin(a.org_id)
));

-----------------------------
-- REALTIME
-----------------------------
do $$ begin
  alter publication supabase_realtime add table platform.kb_articles;
exception when duplicate_object then null;
end $$;

-----------------------------
-- GRANTS
-----------------------------
grant select on all tables in schema platform to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema platform to authenticated, service_role;
grant usage on all sequences in schema platform to anon, authenticated, service_role;
