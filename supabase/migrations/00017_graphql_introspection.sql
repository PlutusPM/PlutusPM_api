-- 00017_graphql_introspection.sql
-- Fix Unknown field "__schema" on type Query and Unknown field "portfolioPortfoliosCollection"
-- Root cause: Starting from pg_graphql 1.6.0, introspection is DISABLED by default and must be opted in per schema
-- When no schema has introspection enabled, __schema query returns Unknown field "_schema"
-- Also need inflect_names true for camelCase field names
-- See: https://supabase.com/docs/guides/graphql/configuration#introspection

-- Enable introspection + inflect_names for all custom schemas and public
comment on schema public is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema platform is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema portfolio is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema ops is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema tenant is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema visitor is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema vendor is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema metrics is '@graphql({"inflect_names": true, "introspection": true})';
comment on schema graphql_public is '@graphql({"inflect_names": true, "introspection": true})';

-- Also ensure storage schema has introspection if needed (optional)
comment on schema storage is '@graphql({"inflect_names": true, "introspection": true})';

-- Rebuild GraphQL schema and reload PostgREST cache (wrapped in exception handling for older pg_graphql versions)
do $$
begin
  -- Try new way: notify to reload
  perform graphql.rebuild_schema() where exists (select 1 from pg_proc where proname = 'rebuild_schema' and pronamespace = (select oid from pg_namespace where nspname = 'graphql'));
exception when others then
  raise notice 'graphql.rebuild_schema() not available or failed: %, skipping - newer pg_graphql auto-rebuilds', SQLERRM;
end;
$$;

do $$
begin
  notify pgrst, 'reload config';
  notify pgrst, 'reload schema';
  raise notice 'Notified pgrst to reload config and schema for GraphQL';
exception when others then
  raise notice 'Failed to notify pgrst: %', SQLERRM;
end;
$$;

-- Verify grants again (in case 00016 didn't apply or was before this)
grant usage on schema platform to anon, authenticated, service_role;
grant usage on schema portfolio to anon, authenticated, service_role;
grant usage on schema ops to anon, authenticated, service_role;
grant usage on schema tenant to anon, authenticated, service_role;
grant usage on schema visitor to anon, authenticated, service_role;
grant usage on schema vendor to anon, authenticated, service_role;
grant usage on schema metrics to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

grant select on all tables in schema platform to anon, authenticated, service_role;
grant select on all tables in schema portfolio to anon, authenticated, service_role;
grant select on all tables in schema ops to anon, authenticated, service_role;
grant select on all tables in schema tenant to anon, authenticated, service_role;
grant select on all tables in schema visitor to anon, authenticated, service_role;
grant select on all tables in schema vendor to anon, authenticated, service_role;
grant select on all tables in schema metrics to anon, authenticated, service_role;
grant select on all tables in schema public to anon, authenticated, service_role;

-- For debugging: create view to check GraphQL exposed tables
create or replace view public.graphql_tables_debug as
select 
  n.nspname as schema_name,
  c.relname as table_name,
  has_schema_privilege('anon', n.nspname, 'usage') as anon_schema_usage,
  has_schema_privilege('authenticated', n.nspname, 'usage') as auth_schema_usage,
  has_table_privilege('anon', n.nspname||'.'||c.relname, 'select') as anon_select,
  has_table_privilege('authenticated', n.nspname||'.'||c.relname, 'select') as auth_select,
  obj_description(c.oid) as comment
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('platform','portfolio','ops','tenant','visitor','vendor','metrics','public')
and c.relkind = 'r'
and c.relname not like 'pg_%'
order by n.nspname, c.relname;

grant select on public.graphql_tables_debug to anon, authenticated, service_role;
