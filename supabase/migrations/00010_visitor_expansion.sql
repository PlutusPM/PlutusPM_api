-- 00010_visitor_expansion.sql
-- Phase 2B: Full Visitor Management + Access Control

-----------------------------
-- VISITOR PASSES (QR passes separate from visits)
-----------------------------
do $$ begin
  create type visitor.pass_type as enum ('day','multi_day','recurring','contractor','vip');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type visitor.pass_status as enum ('active','used','expired','revoked','pending');
exception when duplicate_object then null;
end $$;

create table visitor.passes (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  visit_id uuid not null references visitor.visits(id) on delete cascade,
  visitor_id uuid not null references visitor.visitors(id) on delete cascade,
  qr_token text not null unique default ('PASS-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))),
  type visitor.pass_type not null default 'day',
  status visitor.pass_status not null default 'active',
  valid_from timestamptz not null default now(),
  valid_until timestamptz not null default (now() + interval '1 day'),
  max_uses integer default 1,
  used_count integer default 0,
  issued_by uuid references platform.profiles(id) on delete set null,
  issued_at timestamptz default now() not null,
  revoked_at timestamptz,
  revoked_by uuid references platform.profiles(id) on delete set null,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  check (valid_until > valid_from),
  check (used_count >=0)
);

create index idx_passes_token on visitor.passes(qr_token);
create index idx_passes_visit on visitor.passes(visit_id);
create index idx_passes_site_valid on visitor.passes(site_id, status, valid_until);
create index idx_passes_visitor on visitor.passes(visitor_id);

alter table visitor.passes enable row level security;
create policy "View passes if can access site" on visitor.passes for select using (platform.can_access_site(site_id));
create policy "Members manage passes" on visitor.passes for all using (platform.can_access_site(site_id));

-----------------------------
-- ACCESS DEVICES & POINTS (for smart locks, turnstiles)
-----------------------------
create table visitor.access_devices (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  building_id uuid references portfolio.buildings(id) on delete set null,
  floor_id uuid references portfolio.floors(id) on delete set null,
  name text not null, -- e.g., "Main Lobby Turnstile 1"
  device_type text not null check (device_type in ('turnstile','door_lock','gate','elevator','parking_gate','kiosk','other')),
  identifier text unique, -- MAC, serial, external id
  access_point text, -- e.g., "Lobby", "Floor 5"
  is_online boolean default false,
  is_active boolean default true,
  last_seen_at timestamptz,
  metadata jsonb default '{}'::jsonb, -- {"ip":"10.0.0.5","vendor":"HID","model":"..."}
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_access_devices_site on visitor.access_devices(site_id);

create trigger set_access_devices_updated_at before update on visitor.access_devices for each row execute function public.handle_updated_at();

alter table visitor.access_devices enable row level security;
create policy "View devices if can access site" on visitor.access_devices for select using (platform.can_access_site(site_id));
create policy "Managers manage devices" on visitor.access_devices for all using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id));

-- Access credentials (NFC, Bluetooth, mobile)
do $$ begin
  create type visitor.credential_type as enum ('nfc','bluetooth','qr','pin','mobile','card');
exception when duplicate_object then null;
end $$;

create table visitor.access_credentials (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete set null, -- null = org-wide
  user_id uuid references platform.profiles(id) on delete cascade, -- for tenants/staff
  visitor_id uuid references visitor.visitors(id) on delete cascade, -- for visitors
  type visitor.credential_type not null,
  credential_id text not null, -- card number, nfc uid, etc
  is_active boolean default true,
  expires_at timestamptz,
  issued_at timestamptz default now() not null,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  check ((user_id is not null) or (visitor_id is not null)),
  unique(org_id, credential_id)
);

create index idx_access_creds_user on visitor.access_credentials(user_id);
create index idx_access_creds_visitor on visitor.access_credentials(visitor_id);
create index idx_access_creds_site on visitor.access_credentials(site_id);

alter table visitor.access_credentials enable row level security;
create policy "View creds if org member or can access site" on visitor.access_credentials for select using (
  platform.is_org_member(org_id) or (site_id is not null and platform.can_access_site(site_id))
);
create policy "Managers manage creds" on visitor.access_credentials for all using (platform.is_org_member(org_id));

-----------------------------
-- VISITOR BLACKLIST / WATCHLIST
-----------------------------
create table visitor.blacklist (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  visitor_id uuid references visitor.visitors(id) on delete cascade,
  email text, -- allow blacklist by email without visitor record
  full_name text,
  reason text not null,
  severity text default 'medium' check (severity in ('low','medium','high','critical')),
  added_by uuid references platform.profiles(id) on delete set null,
  expires_at timestamptz, -- null = indefinite
  is_active boolean default true,
  created_at timestamptz default now() not null
);

create index idx_blacklist_org_email on visitor.blacklist(org_id, email);
create index idx_blacklist_visitor on visitor.blacklist(visitor_id);

alter table visitor.blacklist enable row level security;
create policy "View blacklist if org member" on visitor.blacklist for select using (platform.is_org_member(org_id));
create policy "Security can manage blacklist" on visitor.blacklist for all using (
  platform.is_org_member(org_id) and (
    exists (select 1 from platform.memberships where org_id = blacklist.org_id and user_id = auth.uid() and role in ('owner','admin','site_manager','security'))
  )
);

-----------------------------
-- ENHANCE VISITS TABLE
-----------------------------
do $$ begin
  alter table visitor.visits add column pass_id uuid references visitor.passes(id) on delete set null;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table visitor.visits add column checked_in_by uuid references platform.profiles(id);
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table visitor.visits add column checked_out_by uuid references platform.profiles(id);
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table visitor.visits add column host_notified_at timestamptz;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table visitor.visits add column nda_signed boolean default false;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table visitor.visits add column visitor_company_verified boolean default false;
exception when duplicate_column then null;
end $$;

-----------------------------
-- VISITOR FUNCTIONS
-----------------------------

-- Generate pass for visit
create or replace function visitor.generate_pass_for_visit(
  p_visit_id uuid,
  p_valid_until timestamptz default null,
  p_type visitor.pass_type default 'day'
)
returns visitor.passes
language plpgsql
security definer
set search_path = visitor, platform, portfolio, public
as $$
declare
  v_visit visitor.visits%rowtype;
  new_pass visitor.passes;
begin
  select * into v_visit from visitor.visits where id = p_visit_id;
  if not found then raise exception 'Visit not found'; end if;
  if not platform.can_access_site(v_visit.site_id) then raise exception 'Access denied'; end if;

  -- Check blacklist
  if exists (
    select 1 from visitor.blacklist b
    where b.org_id = v_visit.org_id
    and b.is_active = true
    and (b.visitor_id = v_visit.visitor_id or b.email = (select email from visitor.visitors where id = v_visit.visitor_id))
    and (b.expires_at is null or b.expires_at > now())
  ) then
    raise exception 'Visitor is blacklisted, cannot generate pass';
  end if;

  insert into visitor.passes (org_id, site_id, visit_id, visitor_id, type, valid_from, valid_until, issued_by)
  values (
    v_visit.org_id, v_visit.site_id, v_visit.id, v_visit.visitor_id,
    p_type,
    now(),
    coalesce(p_valid_until, now() + interval '1 day'),
    auth.uid()
  ) returning * into new_pass;

  -- Update visit with pass_id and qr
  update visitor.visits set pass_id = new_pass.id, qr_code = new_pass.qr_token where id = p_visit_id;

  return new_pass;
end;
$$;

comment on function visitor.generate_pass_for_visit(uuid, timestamptz, visitor.pass_type) is '@graphql({"type": "mutation", "name": "generatePassForVisit"})';

-- Check-in visitor (kiosk / security)
create or replace function visitor.check_in_visitor(
  p_token text, -- qr_token or visit qr_code
  p_device_id uuid default null,
  p_checked_in_by uuid default null
)
returns visitor.visits
language plpgsql
security definer
set search_path = visitor, platform, public
as $$
declare
  v_pass visitor.passes%rowtype;
  v_visit visitor.visits%rowtype;
  v_device visitor.access_devices%rowtype;
begin
  -- Find pass by token OR visit qr_code
  select * into v_pass from visitor.passes where qr_token = p_token and status = 'active' limit 1;
  if found then
    select * into v_visit from visitor.visits where id = v_pass.visit_id;
  else
    -- Try visit QR
    select * into v_visit from visitor.visits where qr_code = p_token limit 1;
    if not found then raise exception 'Invalid pass token'; end if;
    -- Try find active pass for this visit
    select * into v_pass from visitor.passes where visit_id = v_visit.id and status = 'active' order by valid_until desc limit 1;
  end if;

  if v_visit.status = 'checked_in' then raise exception 'Visitor already checked in'; end if;
  if v_visit.status in ('checked_out','cancelled') then raise exception 'Visit is %', v_visit.status; end if;

  -- If pass exists, validate
  if v_pass.id is not null then
    if v_pass.valid_until < now() then
      update visitor.passes set status='expired' where id=v_pass.id;
      raise exception 'Pass expired';
    end if;
    if v_pass.used_count >= v_pass.max_uses then
      raise exception 'Pass max uses reached';
    end if;
    update visitor.passes set used_count = used_count + 1, status = case when used_count+1 >= max_uses then 'used'::visitor.pass_status else status end where id=v_pass.id;
  end if;

  -- Device
  if p_device_id is not null then
    select * into v_device from visitor.access_devices where id = p_device_id;
  end if;

  -- Update visit
  update visitor.visits
  set status = 'checked_in',
      checked_in_at = now(),
      checked_in_by = coalesce(p_checked_in_by, auth.uid()),
      updated_at = now()
  where id = v_visit.id
  returning * into v_visit;

  -- Log access
  insert into visitor.access_logs (org_id, site_id, visit_id, device_id, access_point, event)
  values (
    v_visit.org_id, v_visit.site_id, v_visit.id,
    coalesce(p_device_id::text, 'kiosk'),
    coalesce(v_device.access_point, 'Main Lobby'),
    'granted'
  );

  -- Notify host
  if v_visit.host_user_id is not null then
    insert into platform.notifications (org_id, site_id, user_id, type, title, body, payload)
    values (
      v_visit.org_id, v_visit.site_id, v_visit.host_user_id,
      'visitor_arrived',
      'Visitor arrived: ' || (select full_name from visitor.visitors where id = v_visit.visitor_id),
      'Visitor checked in at ' || now()::text,
      jsonb_build_object('visit_id', v_visit.id, 'visitor_id', v_visit.visitor_id)
    );
    update visitor.visits set host_notified_at = now() where id = v_visit.id;
  end if;

  return v_visit;
end;
$$;

comment on function visitor.check_in_visitor(text, uuid, uuid) is '@graphql({"type": "mutation", "name": "checkInVisitor"})';

-- Check-out visitor
create or replace function visitor.check_out_visitor(
  p_visit_id uuid,
  p_device_id uuid default null
)
returns visitor.visits
language plpgsql
security definer
set search_path = visitor, platform, public
as $$
declare
  v_visit visitor.visits%rowtype;
begin
  select * into v_visit from visitor.visits where id = p_visit_id;
  if not found then raise exception 'Visit not found'; end if;
  if v_visit.status != 'checked_in' then raise exception 'Visitor not checked in'; end if;

  update visitor.visits
  set status = 'checked_out', checked_out_at = now(), checked_out_by = auth.uid(), updated_at = now()
  where id = p_visit_id
  returning * into v_visit;

  insert into visitor.access_logs (org_id, site_id, visit_id, device_id, access_point, event)
  values (v_visit.org_id, v_visit.site_id, v_visit.id, coalesce(p_device_id::text, 'kiosk'), 'Main Lobby Exit', 'granted');

  return v_visit;
end;
$$;

comment on function visitor.check_out_visitor(uuid, uuid) is '@graphql({"type": "mutation", "name": "checkOutVisitor"})';

-- Validate QR (for kiosk to show visitor details without check-in)
create or replace function visitor.validate_pass(p_token text)
returns table (
  visit_id uuid,
  visitor_name text,
  visitor_company text,
  status visitor.visit_status,
  valid_until timestamptz,
  is_blacklisted boolean,
  host_name text
)
language plpgsql
security definer
set search_path = visitor, platform, public
as $$
begin
  return query
  select
    v.id as visit_id,
    vis.full_name as visitor_name,
    vis.company as visitor_company,
    v.status,
    p.valid_until,
    exists (
      select 1 from visitor.blacklist b
      where b.org_id = v.org_id and b.is_active = true
      and (b.visitor_id = v.visitor_id or b.email = vis.email)
      and (b.expires_at is null or b.expires_at > now())
    ) as is_blacklisted,
    (select full_name from platform.profiles where id = v.host_user_id) as host_name
  from visitor.visits v
  join visitor.visitors vis on vis.id = v.visitor_id
  left join visitor.passes p on p.id = v.pass_id or p.visit_id = v.id
  where v.qr_code = p_token or p.qr_token = p_token
  limit 1;
end;
$$;

comment on function visitor.validate_pass(text) is '@graphql({"type": "query", "name": "validatePass"})';

-- Daily visitor stats function for dashboard
create or replace function visitor.get_daily_visitor_stats(p_site_id uuid, p_date date default current_date)
returns table (
  total_preregistered integer,
  checked_in integer,
  checked_out integer,
  no_show integer,
  denied integer
)
language sql
security definer
set search_path = visitor, platform, public
as $$
  select
    count(*) filter (where status in ('preregistered','checked_in','checked_out'))::int as total,
    count(*) filter (where status = 'checked_in')::int,
    count(*) filter (where status = 'checked_out')::int,
    count(*) filter (where status = 'no_show')::int,
    count(*) filter (where status = 'denied')::int
  from visitor.visits
  where site_id = p_site_id
  and scheduled_at::date = p_date
  and platform.can_access_site(site_id);
$$;

comment on function visitor.get_daily_visitor_stats(uuid, date) is '@graphql({"type": "query", "name": "getDailyVisitorStats"})';

-- Grants
grant all on all tables in schema visitor to service_role;
grant select, insert, update, delete on all tables in schema visitor to authenticated;
grant usage on all sequences in schema visitor to authenticated, service_role;

-- Realtime
alter publication supabase_realtime add table visitor.passes;
alter publication supabase_realtime add table visitor.access_logs;

-- Cron for expired passes cleanup hourly
select cron.schedule(
  'expire-visitor-passes',
  '0 * * * *',
  $$
  update visitor.passes set status='expired' where status='active' and valid_until < now();
  update visitor.visits set status='no_show' where status='preregistered' and scheduled_at < now() - interval '2 hours';
  $$
) where not exists (select 1 from cron.job where jobname='expire-visitor-passes');
