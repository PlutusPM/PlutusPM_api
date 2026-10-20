-- Property lookup for the signed-out tenant sign-in screen.
-- Sites RLS hides every row from anon, so expose only name/address matches
-- for a typed search (never the full list). Whether the tenant really belongs
-- to the chosen property is checked against tenant_contacts after sign-in.
create or replace function tenant.search_portal_properties(p_query text)
returns table (
  id uuid,
  name text,
  address_line1 text,
  city text,
  state text,
  zip_code text
)
language sql
stable
security definer
set search_path = tenant, portfolio, public
as $$
  select s.id, s.name, s.address_line1, s.city, s.state, s.zip_code
  from portfolio.sites s
  where length(trim(coalesce(p_query, ''))) >= 2
    and s.status in ('active', 'onboarding')
    and concat_ws(' ', s.name, s.address_line1, s.city, s.state, s.zip_code)
      ilike '%' || replace(replace(replace(trim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%'
  order by (s.name ilike trim(p_query) || '%') desc, s.name
  limit 8;
$$;

revoke all on function tenant.search_portal_properties(text) from public;
grant execute on function tenant.search_portal_properties(text) to anon, authenticated;
