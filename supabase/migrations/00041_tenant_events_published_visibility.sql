-- 00041_tenant_events_published_visibility.sql

drop policy if exists "View events if can access site" on tenant.events;
create policy "View events if can access site"
on tenant.events for select
using (
  platform.is_site_manager(site_id)
  or platform.is_org_admin(org_id)
  or (is_public = true and platform.can_access_site(site_id))
);

drop policy if exists "Users manage own rsvps" on tenant.event_rsvps;
create policy "Users manage own rsvps"
on tenant.event_rsvps for all
using (profile_id = auth.uid() or platform.can_access_site(site_id))
with check (
  (profile_id = auth.uid() or platform.can_access_site(site_id))
  and (
    platform.is_site_manager(site_id)
    or platform.is_org_admin(org_id)
    or exists (
      select 1
      from tenant.events e
      where e.id = event_rsvps.event_id
        and e.site_id = event_rsvps.site_id
        and e.org_id = event_rsvps.org_id
        and e.is_public = true
    )
  )
);
