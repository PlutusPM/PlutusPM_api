-- Add stable, org-scoped slugs for portfolio URLs.
alter table portfolio.portfolios add column slug text;

-- Backfill deterministically and avoid collisions, including names that normalize
-- to the same slug (or collide with an existing suffixed slug).
do $$
declare
  portfolio_row record;
  base_slug text;
  candidate_slug text;
  suffix integer;
begin
  for portfolio_row in
    select id, org_id, name
    from portfolio.portfolios
    order by org_id, name, id
  loop
    base_slug := regexp_replace(
      regexp_replace(lower(trim(portfolio_row.name)), '[^a-z0-9]+', '-', 'g'),
      '(^-|-$)', '', 'g'
    );
    if base_slug = '' then
      base_slug := 'portfolio';
    end if;

    candidate_slug := base_slug;
    suffix := 1;
    while exists (
      select 1
      from portfolio.portfolios
      where org_id = portfolio_row.org_id
        and slug = candidate_slug
    ) loop
      suffix := suffix + 1;
      candidate_slug := base_slug || '-' || suffix;
    end loop;

    update portfolio.portfolios
    set slug = candidate_slug
    where id = portfolio_row.id;
  end loop;
end $$;

alter table portfolio.portfolios
  alter column slug set not null;

alter table portfolio.portfolios
  add constraint portfolios_slug_format_check
  check (slug ~ '^[a-z0-9-]+$');

alter table portfolio.portfolios
  add constraint portfolios_org_id_slug_key
  unique (org_id, slug);
