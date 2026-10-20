-- 00042_visitor_check_in_authorization.sql
-- check_in_visitor / check_out_visitor are security definer and were executable by
-- PUBLIC with no caller check. Restrict them to site managers (or the service role,
-- used by the visitor-kiosk Edge function) and stop trusting a caller-supplied
-- p_checked_in_by from end users. Signatures are unchanged.

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
  v_is_service boolean := coalesce(auth.role(), '') = 'service_role';
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

  if not v_is_service and not platform.is_site_manager(v_visit.site_id) then
    raise exception 'Not authorized to check in visitors at this property' using errcode = '42501';
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

  -- Device (must belong to the visit's site)
  if p_device_id is not null then
    select * into v_device from visitor.access_devices where id = p_device_id and site_id = v_visit.site_id;
    if not found then raise exception 'Access device not found at this property'; end if;
  end if;

  -- Update visit; only the service role may attribute the check-in to someone else
  update visitor.visits
  set status = 'checked_in',
      checked_in_at = now(),
      checked_in_by = case when v_is_service then p_checked_in_by else auth.uid() end,
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

  if coalesce(auth.role(), '') <> 'service_role' and not platform.is_site_manager(v_visit.site_id) then
    raise exception 'Not authorized to check out visitors at this property' using errcode = '42501';
  end if;

  if v_visit.status != 'checked_in' then raise exception 'Visitor not checked in'; end if;

  if p_device_id is not null and not exists (select 1 from visitor.access_devices where id = p_device_id and site_id = v_visit.site_id) then
    raise exception 'Access device not found at this property';
  end if;

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

revoke execute on function visitor.check_in_visitor(text, uuid, uuid) from public, anon;
revoke execute on function visitor.check_out_visitor(uuid, uuid) from public, anon;
grant execute on function visitor.check_in_visitor(text, uuid, uuid) to authenticated, service_role;
grant execute on function visitor.check_out_visitor(uuid, uuid) to authenticated, service_role;
