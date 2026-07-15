-- 00000_extensions.sql
-- Enable all required extensions for CRE SaaS Platform

-- Core
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists "pgcrypto" with schema extensions;
create extension if not exists "pg_graphql" with schema graphql;
create extension if not exists "pg_stat_statements" with schema extensions;

-- Search & Geo (as per architecture: portfolio sites need geo + search)
create extension if not exists "postgis" with schema extensions;
create extension if not exists "pg_trgm" with schema extensions;
-- ltree for hierarchical spaces/assets if needed later (optional)
create extension if not exists "ltree" with schema extensions;

-- Scheduler (pg_cron + pg_net as per scheduler strategy)
create extension if not exists "pg_cron" with schema pg_catalog;
create extension if not exists "pg_net" with schema extensions;

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
