-- Persist tenant-facing move-in checklist progress without duplicating lease or document data.

create table if not exists tenant.move_in_task_progress (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.tenants(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  tenant_id uuid not null references tenant.tenants(id) on delete cascade,
  occupancy_id uuid not null references tenant.occupancies(id) on delete cascade,
  task_key text not null check (task_key in ('guide', 'coi', 'dock', 'access', 'walkthrough')),
  completed boolean not null default false,
  completed_by uuid references platform.profiles(id) on delete set null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (occupancy_id, task_key)
);

create index if not exists idx_move_in_progress_tenant on tenant.move_in_task_progress(tenant_id);
create index if not exists idx_move_in_progress_occupancy on tenant.move_in_task_progress(occupancy_id);

drop trigger if exists set_move_in_task_progress_updated_at on tenant.move_in_task_progress;
create trigger set_move_in_task_progress_updated_at
  before update on tenant.move_in_task_progress
  for each row execute function public.handle_updated_at();

alter table tenant.move_in_task_progress enable row level security;

drop policy if exists "Tenant contacts view move-in progress" on tenant.move_in_task_progress;
create policy "Tenant contacts view move-in progress"
on tenant.move_in_task_progress for select
using (tenant.is_tenant_contact(tenant_id));

drop policy if exists "Tenant contacts manage move-in progress" on tenant.move_in_task_progress;
create policy "Tenant contacts manage move-in progress"
on tenant.move_in_task_progress for all
using (tenant.is_tenant_contact(tenant_id))
with check (tenant.is_tenant_contact(tenant_id));

create or replace function tenant.update_move_in_task(
  p_occupancy_id uuid,
  p_task_key text,
  p_completed boolean
)
returns tenant.move_in_task_progress
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
declare
  v_occupancy tenant.occupancies%rowtype;
  v_progress tenant.move_in_task_progress;
begin
  select * into v_occupancy
  from tenant.occupancies
  where id = p_occupancy_id;

  if not found then
    raise exception 'Unknown occupancy %', p_occupancy_id;
  end if;

  if not tenant.is_tenant_contact(v_occupancy.tenant_id) then
    raise exception 'Access denied to occupancy %', p_occupancy_id;
  end if;

  insert into tenant.move_in_task_progress (
    org_id, site_id, tenant_id, occupancy_id, task_key,
    completed, completed_by, completed_at
  )
  values (
    v_occupancy.org_id, v_occupancy.site_id, v_occupancy.tenant_id, v_occupancy.id, p_task_key,
    p_completed, auth.uid(), case when p_completed then now() else null end
  )
  on conflict (occupancy_id, task_key) do update set
    completed = excluded.completed,
    completed_by = excluded.completed_by,
    completed_at = excluded.completed_at,
    updated_at = now()
  returning * into v_progress;

  return v_progress;
end;
$$;

grant execute on function tenant.update_move_in_task(uuid, text, boolean) to authenticated;
