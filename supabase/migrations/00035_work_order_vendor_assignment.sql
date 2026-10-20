-- Add explicit vendor assignment to work orders.
-- A work order can still be unassigned while it is being triaged.
alter table ops.work_orders
  add column if not exists vendor_id uuid references vendor.vendors(id) on delete set null;

create index if not exists idx_wos_vendor on ops.work_orders(vendor_id);
