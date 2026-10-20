-- Keep the demo work order aligned with its linked service request.
update ops.work_orders
set
  space_id = '3ae6d94c-a3f7-5f12-9b57-267434960da0',
  title = 'AC not cooling in conference room',
  description = 'Tenants report that the conference room AC is not cooling properly.',
  priority = 'urgent',
  status = 'in_progress',
  updated_at = now()
where id = '2a6c5f81-9ac5-5601-b713-6b9f4551d79c';

update tenant.service_requests
set
  space_id = '3ae6d94c-a3f7-5f12-9b57-267434960da0',
  description = 'The conference room AC is not cooling properly; see linked work order.',
  updated_at = now()
where work_order_id = '2a6c5f81-9ac5-5601-b713-6b9f4551d79c';
