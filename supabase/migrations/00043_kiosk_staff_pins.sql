-- 00043_kiosk_staff_pins.sql
-- Front-desk kiosk staff PINs and server-side visitor attribution.

-----------------------------
-- 1. KIOSK STAFF PIN STORAGE
-----------------------------
create table platform.kiosk_staff_pins (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.tenants(id) on delete cascade,
  user_id uuid not null references platform.profiles(id) on delete cascade,
  pin_hash text not null,
  failed_attempts integer not null default 0 check (failed_attempts >= 0),
  locked_until timestamptz,
  last_failed_at timestamptz,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  unique (org_id, user_id)
);

create index idx_kiosk_staff_pins_user_org on platform.kiosk_staff_pins(user_id, org_id);

create trigger set_kiosk_staff_pins_updated_at
  before update on platform.kiosk_staff_pins
  for each row execute function public.handle_updated_at();

alter table platform.kiosk_staff_pins enable row level security;

-- PIN hashes are never directly readable or writable through PostgREST.
revoke all on platform.kiosk_staff_pins from public, anon, authenticated;
grant all on platform.kiosk_staff_pins to service_role;

create table platform.kiosk_staff_pin_attempts (
  id uuid primary key default uuid_generate_v4(),
  org_id uuid not null references platform.tenants(id) on delete cascade,
  site_id uuid references portfolio.sites(id) on delete set null,
  user_id uuid not null references platform.profiles(id) on delete cascade,
  attempted_by uuid references platform.profiles(id) on delete set null,
  succeeded boolean not null default false,
  reason text,
  attempted_at timestamptz default now() not null
);

create index idx_kiosk_staff_pin_attempts_user_time
  on platform.kiosk_staff_pin_attempts(user_id, attempted_at desc);

alter table platform.kiosk_staff_pin_attempts enable row level security;
revoke all on platform.kiosk_staff_pin_attempts from public, anon, authenticated;
grant all on platform.kiosk_staff_pin_attempts to service_role;

-----------------------------
-- 2. OWN-PIN SETTER
-----------------------------
create or replace function platform.set_kiosk_staff_pin(
  p_org_id uuid,
  p_pin text
)
returns boolean
language plpgsql
security definer
set search_path = platform, public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from platform.memberships m
    where m.org_id = p_org_id
      and m.user_id = v_user_id
      and m.role in ('owner','admin','portfolio_manager','site_manager','security')
  ) then
    raise exception 'Only property staff can set a kiosk PIN' using errcode = '42501';
  end if;

  if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'Kiosk PIN must contain 4 to 6 digits';
  end if;

  if p_pin ~ '^(0{4,6}|1{4,6}|2{4,6}|3{4,6}|4{4,6}|5{4,6}|6{4,6}|7{4,6}|8{4,6}|9{4,6})$'
     or p_pin in ('0123','1234','2345','3456','4567','5678','6789','9876','8765','7654','6543','5432','4321',
                  '01234','12345','23456','34567','45678','56789','98765','87654','76543','65432','54321',
                  '012345','123456','234567','345678','456789','987654','876543','765432','654321','543210') then
    raise exception 'Choose a less predictable kiosk PIN';
  end if;

  insert into platform.kiosk_staff_pins (org_id, user_id, pin_hash, failed_attempts, locked_until, last_failed_at)
  values (p_org_id, v_user_id, public.crypt(p_pin, public.gen_salt('bf', 10)), 0, null, null)
  on conflict (org_id, user_id) do update set
    pin_hash = excluded.pin_hash,
    failed_attempts = 0,
    locked_until = null,
    last_failed_at = null,
    updated_at = now();

  return true;
end;
$$;

comment on function platform.set_kiosk_staff_pin(uuid, text)
  is '@graphql({"type": "mutation", "name": "setKioskStaffPin"})';

-----------------------------
-- 3. PIN VERIFICATION / LOCKOUT
-----------------------------
create or replace function platform.verify_kiosk_staff_pin(
  p_org_id uuid,
  p_site_id uuid,
  p_user_id uuid,
  p_pin text,
  p_manager_only boolean default false
)
returns table (
  success boolean,
  display_name text
)
language plpgsql
security definer
set search_path = platform, portfolio, public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_site_org_id uuid;
  v_pin platform.kiosk_staff_pins%rowtype;
  v_target_role text;
  v_display_name text;
  v_attempt_count integer;
begin
  select s.org_id into v_site_org_id
  from portfolio.sites s
  where s.id = p_site_id;

  if v_site_org_id is null or v_site_org_id <> p_org_id then
    return query select false, null::text;
    return;
  end if;

  -- The signed-in account that launched the kiosk must itself manage this site.
  if v_caller_id is null or not exists (
    select 1
    from platform.memberships m
    where m.org_id = p_org_id
      and m.user_id = v_caller_id
      and m.role in ('owner','admin','portfolio_manager','site_manager')
      and (m.site_ids is null or p_site_id = any(m.site_ids))
  ) then
    return query select false, null::text;
    return;
  end if;

  select m.role::text into v_target_role
  from platform.memberships m
  where m.org_id = p_org_id
    and m.user_id = p_user_id
    and m.role in ('owner','admin','portfolio_manager','site_manager','security')
    and (m.site_ids is null or p_site_id = any(m.site_ids))
  limit 1;

  if v_target_role is null or (p_manager_only and v_target_role not in ('owner','admin','portfolio_manager','site_manager')) then
    return query select false, null::text;
    return;
  end if;

  select * into v_pin
  from platform.kiosk_staff_pins
  where org_id = p_org_id and user_id = p_user_id
  for update;

  if not found then
    insert into platform.kiosk_staff_pin_attempts (org_id, site_id, user_id, attempted_by, succeeded, reason)
    values (p_org_id, p_site_id, p_user_id, v_caller_id, false, 'pin_not_configured');
    return query select false, null::text;
    return;
  end if;

  if v_pin.locked_until is not null and v_pin.locked_until > now() then
    insert into platform.kiosk_staff_pin_attempts (org_id, site_id, user_id, attempted_by, succeeded, reason)
    values (p_org_id, p_site_id, p_user_id, v_caller_id, false, 'locked');
    return query select false, null::text;
    return;
  end if;

  if p_pin is not null and p_pin ~ '^[0-9]{4,6}$' and public.crypt(p_pin, v_pin.pin_hash) = v_pin.pin_hash then
    select coalesce(nullif(trim(p.full_name), ''), p.email, 'Staff member')
      into v_display_name
    from platform.profiles p
    where p.id = p_user_id;

    update platform.kiosk_staff_pins
    set failed_attempts = 0, locked_until = null, last_failed_at = null, updated_at = now()
    where id = v_pin.id;

    insert into platform.kiosk_staff_pin_attempts (org_id, site_id, user_id, attempted_by, succeeded, reason)
    values (p_org_id, p_site_id, p_user_id, v_caller_id, true, 'verified');
    return query select true, coalesce(v_display_name, 'Staff member');
    return;
  end if;

  v_attempt_count := v_pin.failed_attempts + 1;
  update platform.kiosk_staff_pins
  set failed_attempts = v_attempt_count,
      locked_until = case when v_attempt_count >= 5 then now() + interval '5 minutes' else null end,
      last_failed_at = now(),
      updated_at = now()
  where id = v_pin.id;

  insert into platform.kiosk_staff_pin_attempts (org_id, site_id, user_id, attempted_by, succeeded, reason)
  values (
    p_org_id,
    p_site_id,
    p_user_id,
    v_caller_id,
    false,
    case when v_attempt_count >= 5 then 'lockout' else 'invalid_pin' end
  );

  return query select false, null::text;
end;
$$;

comment on function platform.verify_kiosk_staff_pin(uuid, uuid, uuid, text, boolean)
  is '@graphql({"type": "mutation", "name": "verifyKioskStaffPin"})';

revoke execute on function platform.set_kiosk_staff_pin(uuid, text) from public, anon;
revoke execute on function platform.verify_kiosk_staff_pin(uuid, uuid, uuid, text, boolean) from public, anon;
grant execute on function platform.set_kiosk_staff_pin(uuid, text) to authenticated, service_role;
grant execute on function platform.verify_kiosk_staff_pin(uuid, uuid, uuid, text, boolean) to authenticated, service_role;

-----------------------------
-- 4. VISITOR RPC HARDENING / ATTRIBUTION
-----------------------------
create or replace function visitor.check_in_visitor(
  p_token text,
  p_device_id uuid default null,
  p_checked_in_by uuid default null
)
returns visitor.visits
language plpgsql
security definer
set search_path = visitor, platform, portfolio, public
as $$
declare
  v_pass visitor.passes%rowtype;
  v_visit visitor.visits%rowtype;
  v_device visitor.access_devices%rowtype;
  v_is_service boolean := coalesce(auth.role(), '') = 'service_role';
begin
  if p_token is null or length(trim(p_token)) = 0 or length(p_token) > 512 then
    raise exception 'Invalid pass token';
  end if;

  -- A pass token must belong to an active pass. Do not fall through to the
  -- visit QR path for revoked or expired pass tokens.
  select * into v_pass from visitor.passes where qr_token = p_token limit 1;
  if found then
    if v_pass.status <> 'active' then
      if v_pass.valid_until < now() then
        update visitor.passes set status = 'expired' where id = v_pass.id;
        raise exception 'Pass expired';
      end if;
      raise exception 'Visitor pass is no longer active';
    end if;
    select * into v_visit from visitor.visits where id = v_pass.visit_id;
  else
    select * into v_visit from visitor.visits where qr_code = p_token limit 1;
    if not found then raise exception 'Invalid pass token'; end if;
    select * into v_pass from visitor.passes where visit_id = v_visit.id and status = 'active' order by valid_until desc limit 1;
  end if;

  if not v_is_service and not platform.is_site_manager(v_visit.site_id) then
    raise exception 'Not authorized to check in visitors at this property' using errcode = '42501';
  end if;

  if p_checked_in_by is not null and not v_is_service and not exists (
    select 1
    from platform.memberships m
    where m.org_id = v_visit.org_id
      and m.user_id = p_checked_in_by
      and m.role in ('owner','admin','portfolio_manager','site_manager','security')
      and (m.site_ids is null or v_visit.site_id = any(m.site_ids))
  ) then
    raise exception 'The selected kiosk staff member is not assigned to this property' using errcode = '42501';
  end if;

  -- Attributing to someone other than the caller requires that this caller
  -- verified that staff member's PIN at this site within the kiosk session window.
  if p_checked_in_by is not null and not v_is_service and p_checked_in_by <> auth.uid() and not exists (
    select 1
    from platform.kiosk_staff_pin_attempts a
    where a.user_id = p_checked_in_by
      and a.attempted_by = auth.uid()
      and a.site_id = v_visit.site_id
      and a.succeeded = true
      and a.attempted_at > now() - interval '15 minutes'
  ) then
    raise exception 'Kiosk staff PIN verification is required' using errcode = '42501';
  end if;

  if exists (
    select 1
    from visitor.blacklist b
    where b.org_id = v_visit.org_id
      and b.is_active = true
      and (b.visitor_id = v_visit.visitor_id or b.email = (select email from visitor.visitors where id = v_visit.visitor_id))
      and (b.expires_at is null or b.expires_at > now())
  ) then
    raise exception 'Visitor is on the active blacklist';
  end if;

  if v_visit.status = 'checked_in' then raise exception 'Visitor already checked in'; end if;
  if v_visit.status in ('checked_out','cancelled') then raise exception 'Visit is %', v_visit.status; end if;

  if v_pass.id is not null then
    if v_pass.valid_until < now() then
      update visitor.passes set status = 'expired' where id = v_pass.id;
      raise exception 'Pass expired';
    end if;
    if v_pass.used_count >= v_pass.max_uses then raise exception 'Pass max uses reached'; end if;
    update visitor.passes
    set used_count = used_count + 1,
        status = case when used_count + 1 >= max_uses then 'used'::visitor.pass_status else status end
    where id = v_pass.id;
  end if;

  if p_device_id is not null then
    select * into v_device from visitor.access_devices where id = p_device_id and site_id = v_visit.site_id;
    if not found then raise exception 'Access device not found at this property'; end if;
  end if;

  -- A kiosk self check-in passes null; staff-mode check-ins pass the verified
  -- staff profile id. The server action, not the browser, supplies this value.
  update visitor.visits
  set status = 'checked_in',
      checked_in_at = now(),
      checked_in_by = p_checked_in_by,
      updated_at = now()
  where id = v_visit.id
  returning * into v_visit;

  insert into visitor.access_logs (org_id, site_id, visit_id, device_id, access_point, event)
  values (
    v_visit.org_id, v_visit.site_id, v_visit.id,
    coalesce(p_device_id::text, 'kiosk'),
    coalesce(v_device.access_point, 'Main Lobby'),
    'granted'
  );

  if v_visit.host_user_id is not null then
    insert into platform.notifications (org_id, site_id, user_id, type, title, body, payload)
    values (
      v_visit.org_id,
      v_visit.site_id,
      v_visit.host_user_id,
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

comment on function visitor.check_in_visitor(text, uuid, uuid)
  is '@graphql({"type": "mutation", "name": "checkInVisitor"})';

revoke execute on function visitor.validate_pass(text) from public, anon;
grant execute on function visitor.validate_pass(text) to authenticated, service_role;

revoke execute on function visitor.check_in_visitor(text, uuid, uuid) from public, anon;
revoke execute on function visitor.check_out_visitor(uuid, uuid) from public, anon;
grant execute on function visitor.check_in_visitor(text, uuid, uuid) to authenticated, service_role;
grant execute on function visitor.check_out_visitor(uuid, uuid) to authenticated, service_role;
