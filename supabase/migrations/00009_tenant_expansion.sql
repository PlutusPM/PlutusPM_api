-- 00009_tenant_expansion.sql
-- Phase 2A: Full Tenant Experience - Announcements, Events, Amenities, Feedback, Enhanced Reservations

-----------------------------
-- TENANT COMPANIES ENHANCED
-----------------------------
-- tenants table exists, add more fields
do $$ begin
  alter table tenant.tenants add column logo_url text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenants add column industry text;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenants add column employee_count integer;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.tenants add column primary_contact_id uuid references platform.profiles(id);
exception when duplicate_column then null;
end $$;

-- Tenant contacts junction (many profiles can belong to a tenant company)
create table tenant.tenant_contacts (
  id uuid primary key default uuid_generate_v4(),
  tenant_id uuid not null references tenant.tenants(id) on delete cascade,
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  role text not null default 'member' check (role in ('primary','admin','member','billing','facility')),
  is_primary boolean default false,
  created_at timestamptz default now() not null,
  unique(tenant_id, profile_id)
);

create index idx_tenant_contacts_tenant on tenant.tenant_contacts(tenant_id);
create index idx_tenant_contacts_profile on tenant.tenant_contacts(profile_id);
create index idx_tenant_contacts_site on tenant.tenant_contacts(site_id);

alter table tenant.tenant_contacts enable row level security;
create policy "View tenant contacts if can access site" on tenant.tenant_contacts for select using (platform.can_access_site(site_id));
create policy "Managers manage tenant contacts" on tenant.tenant_contacts for all using (platform.can_access_site(site_id));

-----------------------------
-- ANNOUNCEMENTS & NEWS
-----------------------------
do $$ begin
  create type tenant.announcement_audience as enum ('all','tenants','staff','tenant_specific','building_specific');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type tenant.announcement_priority as enum ('low','normal','high','urgent');
exception when duplicate_object then null;
end $$;

create table tenant.announcements (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  building_id uuid references portfolio.buildings(id) on delete set null,
  title text not null,
  body text not null,
  summary text,
  audience tenant.announcement_audience not null default 'all',
  priority tenant.announcement_priority not null default 'normal',
  tenant_id uuid references tenant.tenants(id) on delete set null, -- if audience tenant_specific
  publish_at timestamptz not null default now(),
  expires_at timestamptz,
  is_published boolean default true not null,
  image_url text,
  attachment_paths text[],
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_announcements_site_publish on tenant.announcements(site_id, publish_at desc);
create index idx_announcements_audience on tenant.announcements(audience);
create index idx_announcements_tenant on tenant.announcements(tenant_id);

create trigger set_announcements_updated_at before update on tenant.announcements for each row execute function public.handle_updated_at();

alter table tenant.announcements enable row level security;
-- Tenants can view announcements for their site + audience filtering in app logic, RLS: can_access_site
create policy "View announcements if can access site" on tenant.announcements for select using (platform.can_access_site(site_id) or platform.is_org_member(org_id));
-- Only managers can create
create policy "Managers manage announcements" on tenant.announcements for all using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id));

-----------------------------
-- EVENTS (Community, Building Events)
-----------------------------
create table tenant.events (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  title text not null,
  description text,
  location_text text,
  space_id uuid references portfolio.spaces(id) on delete set null, -- if in specific amenity/room
  start_at timestamptz not null,
  end_at timestamptz not null,
  capacity integer,
  is_public boolean default true,
  requires_rsvp boolean default false,
  rsvp_deadline timestamptz,
  image_url text,
  created_by uuid references platform.profiles(id) on delete set null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  check (end_at > start_at)
);

create index idx_events_site_start on tenant.events(site_id, start_at);

create trigger set_events_updated_at before update on tenant.events for each row execute function public.handle_updated_at();

alter table tenant.events enable row level security;
create policy "View events if can access site" on tenant.events for select using (platform.can_access_site(site_id) or platform.is_org_member(org_id));
create policy "Managers manage events" on tenant.events for all using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id));

-- RSVPs
create table tenant.event_rsvps (
  id uuid primary key default uuid_generate_v4(),
  event_id uuid not null references tenant.events(id) on delete cascade,
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  status text not null default 'going' check (status in ('going','interested','not_going','waitlist')),
  guests integer default 0,
  created_at timestamptz default now() not null,
  unique(event_id, profile_id)
);

alter table tenant.event_rsvps enable row level security;
create policy "View rsvps if can access site" on tenant.event_rsvps for select using (platform.can_access_site(site_id));
create policy "Users manage own rsvps" on tenant.event_rsvps for all using (profile_id = auth.uid() or platform.can_access_site(site_id));

-----------------------------
-- AMENITIES & RESERVATIONS (Enhanced)
-----------------------------
-- Amenities are spaces of type amenity with extra booking rules
-- We enhance spaces metadata and create amenities view + amenities table for rules

create table tenant.amenities (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  space_id uuid not null references portfolio.spaces(id) on delete cascade unique, -- one amenity per space
  name text not null, -- denormalized from space for query speed, but keep sync
  description text,
  category text not null check (category in ('conference_room','meeting_room','gym','rooftop','lounge','parking','event_space','kitchen','other')),
  capacity integer,
  hourly_rate numeric(10,2) default 0,
  is_bookable boolean default true not null,
  booking_rules jsonb default '{}'::jsonb, -- {"min_hours":1,"max_hours":4,"advance_days":30,"requires_approval":false,"allowed_roles":["tenant","staff"]}
  image_urls text[],
  amenities_list text[], -- ["projector","whiteboard","catering"]
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create index idx_amenities_site on tenant.amenities(site_id);
create index idx_amenities_category on tenant.amenities(category);

create trigger set_amenities_updated_at before update on tenant.amenities for each row execute function public.handle_updated_at();

alter table tenant.amenities enable row level security;
create policy "View amenities if can access site" on tenant.amenities for select using (platform.can_access_site(site_id));
create policy "Managers manage amenities" on tenant.amenities for all using (platform.is_site_manager(site_id) or platform.is_org_admin(org_id));

-- Enhance reservations table with amenity link and conflict handling
do $$ begin
  alter table tenant.reservations add column amenity_id uuid references tenant.amenities(id) on delete set null;
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.reservations add column approved_by uuid references platform.profiles(id);
exception when duplicate_column then null;
end $$;

do $$ begin
  alter table tenant.reservations add column approval_status text default 'approved' check (approval_status in ('pending','approved','denied'));
exception when duplicate_column then null;
end $$;

-- Function: Check reservation conflict
create or replace function tenant.check_reservation_conflict(
  p_space_id uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_exclude_reservation_id uuid default null
)
returns boolean -- true if conflict exists
language sql
security definer
set search_path = tenant, public
as $$
  select exists (
    select 1 from tenant.reservations r
    where r.space_id = p_space_id
    and r.status not in ('cancelled','no_show')
    and r.approval_status != 'denied'
    and (p_exclude_reservation_id is null or r.id != p_exclude_reservation_id)
    and tstzrange(r.start_time, r.end_time, '[)') && tstzrange(p_start, p_end, '[)')
  );
$$;

comment on function tenant.check_reservation_conflict(uuid, timestamptz, timestamptz, uuid) is '@graphql({"type": "query", "name": "checkReservationConflict"})';

-- Function: Create reservation with conflict check + rules
create or replace function tenant.create_reservation(
  p_site_id uuid,
  p_space_id uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_title text default null,
  p_attendees integer default 1
)
returns tenant.reservations
language plpgsql
security definer
set search_path = tenant, platform, portfolio, public
as $$
declare
  v_org_id uuid;
  v_amenity_id uuid;
  new_res tenant.reservations;
  has_conflict boolean;
begin
  if not platform.can_access_site(p_site_id) then raise exception 'Access denied to site'; end if;
  select org_id into v_org_id from portfolio.sites where id = p_site_id;

  -- Check if space is amenity
  select id into v_amenity_id from tenant.amenities where space_id = p_space_id limit 1;

  -- Conflict check
  select tenant.check_reservation_conflict(p_space_id, p_start, p_end) into has_conflict;
  if has_conflict then raise exception 'Reservation conflict: space already booked for that time'; end if;

  -- Check advance booking rules if amenity
  -- (simplified, could parse booking_rules jsonb)

  insert into tenant.reservations (org_id, site_id, space_id, amenity_id, reserved_by, title, start_time, end_time, attendees, status, approval_status)
  values (v_org_id, p_site_id, p_space_id, v_amenity_id, auth.uid(), coalesce(p_title, 'Reservation'), p_start, p_end, p_attendees, 'confirmed', 'approved')
  returning * into new_res;

  -- Notifications to site managers?
  insert into platform.notifications (org_id, site_id, type, title, body, payload)
  values (v_org_id, p_site_id, 'reservation_reminder', 'New reservation: ' || new_res.title, 'Space booked ' || p_start::text, jsonb_build_object('reservation_id', new_res.id, 'space_id', p_space_id));

  return new_res;
end;
$$;

comment on function tenant.create_reservation(uuid, uuid, timestamptz, timestamptz, text, integer) is '@graphql({"type": "mutation", "name": "createReservation"})';

-----------------------------
-- FEEDBACK & SERVICE RATINGS
-----------------------------
create table tenant.feedback (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.organizations(id) on delete cascade,
  site_id uuid not null references portfolio.sites(id) on delete cascade,
  profile_id uuid not null references platform.profiles(id) on delete cascade,
  type text not null check (type in ('service_request','work_order','amenity','event','general','complaint','suggestion')),
  related_id uuid, -- e.g., service_request_id, work_order_id, amenity_id
  rating integer check (rating between 1 and 5),
  comment text,
  is_anonymous boolean default false,
  created_at timestamptz default now() not null
);

create index idx_feedback_site_type on tenant.feedback(site_id, type, created_at desc);

alter table tenant.feedback enable row level security;
create policy "View feedback if can access site" on tenant.feedback for select using (platform.can_access_site(site_id));
create policy "Users create feedback" on tenant.feedback for insert with check (profile_id = auth.uid() and platform.can_access_site(site_id));
create policy "Managers manage feedback" on tenant.feedback for all using (platform.is_site_manager(site_id) or profile_id = auth.uid());

-----------------------------
-- SERVICE REQUEST ENHANCEMENT triggers
-----------------------------
-- When service request created, auto-create audit + notification already done in Phase 0 function
-- Add trigger to notify managers when service request completed

create or replace function tenant.notify_service_request_status()
returns trigger
language plpgsql
security definer set search_path = tenant, platform, public
as $$
begin
  if TG_OP = 'UPDATE' and new.status != old.status then
    insert into platform.notifications (org_id, site_id, user_id, type, title, body, payload)
    values (
      new.org_id, new.site_id, new.created_by,
      'service_request_created',
      'Service request ' || new.status || ': ' || new.title,
      new.status,
      jsonb_build_object('service_request_id', new.id, 'status', new.status, 'old_status', old.status)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sr_notify on tenant.service_requests;
create trigger trg_sr_notify
  after update on tenant.service_requests
  for each row execute function tenant.notify_service_request_status();

-- Grants
grant all on all tables in schema tenant to service_role;
grant select, insert, update, delete on all tables in schema tenant to authenticated;
grant usage on all sequences in schema tenant to authenticated, service_role;

-- Realtime
alter publication supabase_realtime add table tenant.announcements;
alter publication supabase_realtime add table tenant.events;
alter publication supabase_realtime add table tenant.reservations;
alter publication supabase_realtime add table tenant.feedback;
alter publication supabase_realtime add table tenant.tenant_contacts;
