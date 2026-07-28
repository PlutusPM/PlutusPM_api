-- 00025_space_enum_expansion.sql
-- Part A1 of the frontend-wiring gap closure: the dashboard's Space model distinguishes finer
-- leasable-space categories and more granular statuses than the backend currently supports.
-- Existing seed data only ever uses the generic 'leasable' type (see 00006_seed_demo.sql) so no
-- backfill is needed - this is purely additive.

-----------------------------
-- PORTFOLIO.SPACE_TYPE: add finer leasable-space categories
-----------------------------
alter type portfolio.space_type add value if not exists 'residential';
alter type portfolio.space_type add value if not exists 'office';
alter type portfolio.space_type add value if not exists 'retail';
alter type portfolio.space_type add value if not exists 'conference';
alter type portfolio.space_type add value if not exists 'industrial';

-----------------------------
-- PORTFOLIO.SPACE_STATUS: add finer availability states
-----------------------------
alter type portfolio.space_status add value if not exists 'available_soon';
alter type portfolio.space_status add value if not exists 'under_construction';
alter type portfolio.space_status add value if not exists 'unavailable';
alter type portfolio.space_status add value if not exists 'inactive';

-----------------------------
-- PORTFOLIO.BUILDINGS.CODE (frontend's Building.code has no backend source today)
-----------------------------
do $$ begin
  alter table portfolio.buildings add column code text;
exception when duplicate_column then null;
end $$;
