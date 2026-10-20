create table if not exists tenant.announcement_reads (
  id uuid primary key default uuid_generate_v4(),
  announcement_id uuid not null references tenant.announcements(id) on delete cascade,
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  tenant_id uuid not null references tenant.tenants(id) on delete cascade,
  read_at timestamptz not null default now(),
  unique (announcement_id, profile_id)
);

create index if not exists idx_announcement_reads_profile on tenant.announcement_reads(profile_id);

alter table tenant.announcement_reads enable row level security;

drop policy if exists "Tenant contacts view announcement reads" on tenant.announcement_reads;
create policy "Tenant contacts view announcement reads"
on tenant.announcement_reads for select
using (profile_id = auth.uid());

drop policy if exists "Tenant contacts manage announcement reads" on tenant.announcement_reads;
create policy "Tenant contacts manage announcement reads"
on tenant.announcement_reads for all
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

create or replace function tenant.mark_announcement_read(p_announcement_id uuid)
returns tenant.announcement_reads
language plpgsql
security definer
set search_path = tenant, platform, public
as $$
declare
  v_announcement tenant.announcements%rowtype;
  v_tenant_id uuid;
  v_read tenant.announcement_reads;
begin
  select * into v_announcement from tenant.announcements where id = p_announcement_id;
  if not found then raise exception 'Unknown announcement %', p_announcement_id; end if;

  select tc.tenant_id into v_tenant_id
  from tenant.tenant_contacts tc
  where tc.profile_id = auth.uid()
    and tc.site_id = v_announcement.site_id
  order by tc.is_primary desc
  limit 1;

  if v_tenant_id is null then raise exception 'Access denied to announcement %', p_announcement_id; end if;
  if v_announcement.audience = 'tenant_specific' and v_announcement.tenant_id is distinct from v_tenant_id then
    raise exception 'Access denied to announcement %', p_announcement_id;
  end if;

  insert into tenant.announcement_reads (announcement_id, profile_id, tenant_id)
  values (p_announcement_id, auth.uid(), v_tenant_id)
  on conflict (announcement_id, profile_id) do update set read_at = now()
  returning * into v_read;

  return v_read;
end;
$$;

grant execute on function tenant.mark_announcement_read(uuid) to authenticated;
