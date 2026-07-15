-- 00000_extensions.sql
-- Enable all required extensions for CRE SaaS Platform

-- Core - install critical ones in PUBLIC so functions uuid_generate_v4(), gen_random_uuid() are in public search_path without needing schema qualification
-- This fixes ERROR: function uuid_generate_v4() does not exist, gen_random_uuid() does not exist
drop extension if exists "uuid-ossp" cascade;
drop extension if exists "pgcrypto" cascade;
create extension "uuid-ossp" with schema public;
create extension "pgcrypto" with schema public;
create extension if not exists "pg_graphql" with schema graphql;
create extension if not exists "pg_stat_statements" with schema extensions;

-- Search & Geo - install in PUBLIC so types (geography, ltree) and functions (similarity, st_distance) are in public search_path
-- This fixes ERROR: type "geography" does not exist (SQLSTATE 42704) when search_path doesn't include extensions
-- Drop first if exists in wrong schema (e.g., extensions) to ensure it ends up in public for fresh and existing DBs
drop extension if exists "postgis" cascade;
drop extension if exists "pg_trgm" cascade;
drop extension if exists "ltree" cascade;
create extension "postgis" with schema public;
create extension "pg_trgm" with schema public;
create extension "ltree" with schema public;

-- Scheduler (pg_cron + pg_net as per scheduler strategy)
-- pg_cron must be in pg_catalog, pg_net in public (creates net schema for http calls)
create extension if not exists "pg_cron" with schema pg_catalog;
drop extension if exists "pg_net" cascade;
create extension "pg_net" with schema public;

-- Supabase vault for secrets (optional but useful)
-- create extension if not exists "supabase_vault" with schema vault;

-- Comment for GraphQL to include public
-- We will expose multiple schemas via graphql config
-- Pg_graphql auto introspects schemas with usage grants

-- Create schemas for domains (as per ARCHITECTURE.md)
create schema if not exists platform;
create schema if not exists portfolio;
create schema if not exists ops;
create schema if not exists tenant;
create schema if not exists visitor;
create schema if not exists vendor;
create schema if not exists metrics;

-- Grant usage on schemas to anon, authenticated, service_role (required for GraphQL + PostgREST)
grant usage on schema platform to anon, authenticated, service_role;
grant usage on schema portfolio to anon, authenticated, service_role;
grant usage on schema ops to anon, authenticated, service_role;
grant usage on schema tenant to anon, authenticated, service_role;
grant usage on schema visitor to anon, authenticated, service_role;
grant usage on schema vendor to anon, authenticated, service_role;
grant usage on schema metrics to anon, authenticated, service_role;
grant usage on schema graphql to anon, authenticated, service_role;
grant usage on schema graphql_public to anon, authenticated, service_role;

-- Ensure authenticated can use pg_net and pg_cron (for checking)
grant usage on schema extensions to postgres, anon, authenticated, service_role;

-- For pg_cron management
-- In Supabase cloud, you need to be postgres role to create cron jobs
-- Locally supabase CLI handles this

-- Updated_at helper (shared)
create or replace function public.handle_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.handle_updated_at is 'Shared trigger to auto-update updated_at column';
