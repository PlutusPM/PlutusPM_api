-- 00030_settings_seed_expansion.sql
-- Part of B6 (frontend wiring): 00021_settings_system.sql only seeded 3 billing-related
-- setting_definitions. The dashboard's Settings workspace UI expects a broader set spanning
-- communications, operations, tenant experience, and emergency response - seed those here so
-- the real settings system covers what the old mock displayed.

insert into platform.setting_definitions (key, label, description, type, default_value, validation_rules, category)
values
  ('announcement_delivery_channels', 'Announcement Delivery', 'Default delivery channels for portfolio-wide notices', 'enum', '"email_and_portal"'::jsonb, '{"options":["email_and_portal","email_only","portal_only"]}'::jsonb, 'communications'),
  ('standard_work_order_sla_hours', 'Standard Work Order SLA (Hours)', 'Default first-response target for standard-priority requests', 'number', '4'::jsonb, '{"min":1,"max":72}'::jsonb, 'operations'),
  ('building_access_protocol', 'Building Access Protocol', 'Entry and escort process for vendors and technicians', 'enum', '"front_desk_confirmation"'::jsonb, '{"options":["front_desk_confirmation","badge_only","escort_required"]}'::jsonb, 'operations'),
  ('amenity_reservation_window_days', 'Amenity Reservation Window (Days)', 'Booking lead time and availability rules for amenities', 'number', '30'::jsonb, '{"min":1,"max":180}'::jsonb, 'tenant_experience'),
  ('after_hours_escalation_route', 'After-Hours Escalation', 'The escalation route used outside business hours', 'enum', '"on_call_property_manager"'::jsonb, '{"options":["on_call_property_manager","answering_service","security_desk"]}'::jsonb, 'emergency_response')
on conflict (key) do nothing;
