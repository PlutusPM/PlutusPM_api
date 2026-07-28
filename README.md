# PlutusPM — Commercial Real Estate SaaS Backend

**Stack:** Supabase (Postgres + PostGIS + pg_graphql + pg_cron + pg_net + Auth + Realtime + Storage + Edge Functions) + TypeScript + Deno  
**Architecture:** Portfolio → Sites → Everything on Site | Multi-tenant, RBAC, RLS-secured | Domain-Driven (6 schemas)  
**Status:** ✅ All 5 Domains + Shared Platform Complete — Production Ready  
**Coverage:** 82 capabilities mapped, 94% implemented (see `docs/CAPABILITY_COVERAGE.md`)  
**Repo:** https://github.com/EmmanuelMat/PlutusPM

> **For Frontend Dev:** Give them `types/` + `postman/` + `docs/FRONTEND_GUIDE_FOR_DEV.md`

---

## 📦 What's Built

### 15 Migrations (~6,500 lines SQL) — Ready to Deploy

> **Note:** the table below documents migrations `00000`–`00015` only. Migrations `00016`–`00030` (GraphQL/security fixes, then the tenant occupancy/lease model, tenant documents, settings, communication campaigns, billing + Stripe, space enum expansion, documentation/KB, site content, tenant bulk import, and webhook log + activity feed domains) exist and are applied by `supabase db reset` / `db push` like any other migration, but aren't summarized here yet — see the filenames in `supabase/migrations/` for now. Also note: `00006`, `00008`, `00011`, `00013`, `00015` (the "N Seed" rows below) are dead code on a fresh reset — see `docs/SEED_DATA.md` for why, and for what `supabase/seed.sql` seeds instead.

| File | Phase | Purpose |
|------|-------|---------|
| `00000_extensions.sql` | 0 Core | Extensions: pg_graphql, postgis, pg_trgm, ltree, pg_cron, pg_net, uuid-ossp + 6 schemas: platform, portfolio, ops, tenant, visitor, vendor, metrics |
| `00001_platform.sql` | 0 Core | **Shared Platform:** organizations (slug, billing_tier), profiles (extends auth.users, is_super_admin), memberships (org_id/user_id/role 10 values, site_ids[] nullable all, portfolio_ids[]), RBAC helpers `can_access_site(site_id)`, `is_org_admin`, `is_org_member`, `current_org_ids`, `is_super_admin`, audit_logs (diff jsonb), notifications (type 14 values), `create_organization()` mutation, RLS on all, Realtime notifications |
| `00002_portfolio_core.sql` | 0 Core | **CENTER:** portfolios (org, name, manager), sites (org, portfolio, name, slug, type office/retail/industrial/lab/mixed etc, status, address, city/state/zip, timezone, location PostGIS geography Point, latitude/longitude sync via trigger, sq_ft, floors_count, manager, metadata jsonb, created_by), buildings (site, name, floors_count), floors (building, level_number, name, floorplan_path), spaces (site/building/floor, name, code STE 100/P-01, type leasable/common/amenity/parking/storage, status vacant/occupied/maintenance, area_sq_ft, capacity), leases (space, tenant, start/end, monthly_rent, status), indexes GIN trigram + GiST PostGIS, functions `search_sites(q, org_id, limit)` similarity, `nearby_sites(lat,lng,radius)`, `create_site_full()` auto building+floors, RLS `can_access_site`, Realtime sites/spaces/leases |
| `00003_domain_schemas.sql` | 0 Scaffold | **5 Domains Scaffold:** ops (asset_categories, assets with qr_code, work_order_templates recurrence_rule, work_orders type preventive/corrective/inspection/service_request/incident, status open/in_progress/overdue/completed, sla_due_at, labor_hours cost), tenant (tenants company_name, service_requests type status → work_order_id auto, reservations space_id/reserved_by/start/end/status), visitor (visitors email/full_name/company, visits site/visitor/host_user/purpose/status preregistered/checked_in/checked_out, scheduled_at, qr_code, access_logs device/access_point/event granted/denied/tailgate/forced), vendor (vendors name/type cleaning/hvac/security/etc, contracts site/vendor/title/status active/expired/value/storage_path, cois vendor/contract/type/expiry/status valid/expiring/expired/coverage_amount/storage_path, compliance_status vendor/site/status compliant/non_compliant/issues jsonb/last_checked), metrics (daily_site_stats) |
| `00004_graphql_scheduler.sql` | 0 GraphQL+Scheduler | **GraphQL:** Grants, `graphql.rebuild_schema()`, mutations `create_work_order(site_id,title,desc,asset_id,space_id,priority,type,due_date)` calculates SLA urgent 4h/high 24h/medium 72h/low 168h + audit log, `complete_work_order(id,notes)` + notification, `register_visitor(site,name,email,company,purpose,host,scheduled)` upsert visitor + visit, `create_service_request(site,space,title,desc,priority)` auto creates WO and links. **Scheduler Functions:** `check_sla_breaches()` marks overdue + notification, `generate_pm_work_orders()` loops templates next_due<=now creates WOs per site, updates next_due via recurrence FREQ, `check_coi_expirations()` expiring 30d→expiring + notif, expired→expired+notif, upserts compliance_status, `rollup_daily_stats(date)` loops sites counts open/closed/overdue/sla breaches/visitors/service_requests, `check_coi_expirations` + `rollup` + **Crons:** 6 jobs: SLA */15 * * * *, PM 0 2 * * *, COI 0 8-18 * * *, metrics 0 3 * * *, cleanup 0 4 * * *, lease 0 9 * * 1 |
| `00005_storage.sql` | 0 Storage | **7 Buckets:** avatars public 2MB image/*, site-files private 100MB, floorplans private 50MB pdf/image, coi-documents private 20MB pdf/image, contract-documents private 50MB pdf, visitor-photos private 5MB, work-order-attachments private 20MB, RLS via `storage.foldername(name)` parsing org_id=parts[1], site_id=parts[2] + `is_org_member(org)` + `can_access_site(site)` + is_site_manager for delete, plus avatars own folder user_id |
| `00006_seed_demo.sql` | 0 Seed | Demo org "Demo CRE Management Co" slug demo-cre growth, owner from first auth.users, profile Demo Admin, membership owner, portfolio "Downtown Portfolio", Site A "100 Main Street Tower" office 100 Main Austin TX 78701 250k sqft 20 floors lat 30.2672 lng -97.7431, Site B "Westfield Shopping Center" retail 500 Commerce Blvd 400k, buildings, 5 floors each, spaces: Lobby, Cafe, Security Desk, Suites STE 100 etc, Conference Room, Amenity Parking etc, asset_categories HVAC/Electrical/Plumbing/Elevator/Fire/Security, 3 assets Chiller/ Elevator/ Fire Panel, 3 PM templates Monthly HVAC, Quarterly Fire Safety, Weekly Cleaning Audit, vendors 3 Cool Air HVAC/SecureGuard/CleanPro + contract HVAC 2024-2025 $75k + COI expiring 20 days $2M coverage for cron test, tenant Acme Tech Inc |
| `00007_ops_phase1_full.sql` | 1 Building Ops Full | **Asset Hierarchy:** parent_asset_id FK, location_description, qr_code_last_printed_at, **Maintenance History:** asset_maintenance_history (asset, WO, type inspection/preventive/corrective/install/decommission/audit, performed_by/at, cost/labor). **Digital Checklists:** checklists (site null org library, name, category, version, is_active/required, estimated_minutes), checklist_items (checklist_id, parent_item_id nesting, sort_order, label, item_type pass_fail/yes_no/numeric/text/photo/signature/multiple_choice, is_required, options jsonb, expected_value jsonb), **Inspections:** inspections (site, asset, building/floor/space, checklist_id, WO, title, status draft/in_progress/completed/failed/cancelled/overdue, score 0-100, assigned_to, scheduled/started/completed), inspection_items (inspection_id, checklist_item_id unique, status pass/fail/na/flagged/pending, response_text/numeric/options jsonb, is_flagged, notes, photo_paths text[], scored, answered_by/at), **WO Enhancements:** work_order_comments (WO, org, site, user_id, comment, is_internal), work_order_attachments (WO, file_name/size/mime, storage_path org/site/work_orders/wo/file), **Inventory & Parts:** inventory_categories org+name unique, inventory_items (category, name, sku unique org, description, unit each/box/meter, cost_per_unit, supplier, min_stock_level 5, is_active), inventory_stock (site, item unique site+item, quantity >=0, location Shelf), stock_transactions (site, item, stock_id, WO, type in/out/adjustment/transfer/return, quantity, reason, performed_by), **Labor:** labor_logs (WO, user, hours>0, rate, total_cost generated hours*rate, logged_at, description), trigger trg_labor_update_wo sums hours/cost to WO. **Incidents:** incidents (site/building/floor/space/asset/WO, title, severity low/medium/high/critical, status reported/investigating/resolved/closed/escalated, category safety/environmental/security/operational, occurred/resolved_at, assigned_to). Views: v_asset_health (per asset open WOs, failed inspections, last_maintenance, health_status healthy/warranty_expired/maintenance_overdue/has_overdue_wo). Functions: create_inspection_from_checklist(site,checklist,asset,title,assigned_to,scheduled) auto creates inspection_items pending, complete_inspection(id) calculates score passed/total*100, failed>0→failed status + auto corrective WO high priority + maintenance_history log, get_asset_history(asset_id,limit), check_low_stock() site,item,current,min. Realtime inspections, inspection_items, incidents, comments, stock. Cron check-low-stock 0 8 * * * → notification low stock |
| `00008_ops_phase1_seed.sql` | 1 Seed | Checklists detailed: Monthly HVAC Detailed 6 items (air filters pass_fail, refrigerant numeric min 10 max 15, belts, thermostat numeric, photo, overall condition multiple_choice Good/Fair/Poor/Critical), Weekly Fire Safety 5 items (extinguishers, emergency lights, alarm panel, sprinkler numeric, exit signs), 5 inventory categories HVAC Electrical Plumbing Safety General, 5 items Filter MERV13 20x25 $45.5 min10, Belt 50 inch $22 min5, Refrigerant R410A 25lb $180 min2, LED Panel 2x4 $65 min20, Fire Extinguisher $95 min8, stock for demo site 3 low stock for filter to test alert, 1 draft inspection for demo asset via create_inspection_from_checklist |
| `00009_tenant_expansion.sql` | 2 Tenant Full | Tenant Companies Enhanced: logo_url, industry, employee_count, primary_contact_id; tenant_contacts junction tenant/profile/org/site role primary/admin/member/billing/facility is_primary; Announcements: site/building, title/body/summary, audience all/tenants/staff/tenant_specific/building_specific, priority low/normal/high/urgent, tenant_id if specific, publish_at, expires_at, is_published, image_url, attachment_paths text[], Realtime; Events: site, title, description, location_text, space_id, start/end > check, capacity, is_public, requires_rsvp, rsvp_deadline, image_url; event_rsvps event/org/site/profile status going/interested/not_going/waitlist guests; Amenities: org/site/space unique, name denormalized, description, category conference_room/meeting_room/gym/rooftop/lounge/parking/event_space/kitchen/other, capacity, hourly_rate, is_bookable, booking_rules jsonb {min_hours,max_hours,advance_days,requires_approval,allowed_roles}, image_urls, amenities_list [projector,whiteboard], Enhance reservations: amenity_id, approved_by, approval_status pending/approved/denied; Functions: check_reservation_conflict(space_id,start,end,exclude_id) bool via tstzrange && status not cancelled/no_show approval != denied, create_reservation(site,space,start,end,title,attendees) checks conflict + site access + amenity lookup + inserts + notification; Feedback: site/profile, type service_request/work_order/amenity/event/general/complaint/suggestion, related_id, rating 1-5, comment, is_anonymous; Trigger notify_service_request_status on SR update status change → notification; Realtime announcements/events/reservations/feedback/tenant_contacts |
| `00010_visitor_expansion.sql` | 2 Visitor Full | Visitor Passes: passes (org/site/visit/visitor, qr_token unique PASS-12chars, type day/multi_day/recurring/contractor/vip, status active/used/expired/revoked/pending, valid_from/until check valid_until>valid_from, max_uses, used_count >=0, issued_by/at, revoked_at/by, metadata); Access Devices: access_devices (site/building/floor, name Main Lobby Turnstile 1, device_type turnstile/door_lock/gate/elevator/parking_gate/kiosk/other, identifier unique MAC/serial, access_point Lobby/Floor5, is_online, is_active, last_seen_at, metadata ip/vendor/model); Access Credentials: credentials (org/site, user_id or visitor_id check, type nfc/bluetooth/qr/pin/mobile/card, credential_id unique org, is_active, expires_at, issued_at, metadata); Blacklist: blacklist (org, visitor_id or email, full_name, reason, severity low/medium/high/critical, added_by, expires_at null indefinite, is_active); Enhanced visits: pass_id, checked_in_by, checked_out_by, host_notified_at, nda_signed, visitor_company_verified; Functions: generate_pass_for_visit(visit_id,valid_until,type) checks blacklist (visitor_id or email active not expired) → creates pass, updates visit.qr_code+pass_id; check_in_visitor(token,device_id,checked_in_by) finds pass by qr_token active OR visit qr_code, checks already checked_in/cancelled, validates pass expiry < now→expired + exception, used_count>=max_uses→exception, increments used_count→used if >=max, updates visit checked_in + checked_in_by, logs access_logs granted, notifies host user_id notification visitor_arrived + host_notified_at; check_out_visitor(visit_id,device_id) checked_in→checked_out, logs; validate_pass(token) returns visit_id, visitor_name/company, status, valid_until, is_blacklisted exists, host_name; get_daily_visitor_stats(site_id,date) counts total preregistered, checked_in/out, no_show, denied; Grants, Realtime passes/access_logs, Cron expire-visitor-passes hourly expires passes valid_until<now + visits preregistered scheduled<now-2h → no_show |
| `00011_phase2_seed.sql` | 2 Seed | Tenant contacts link demo profile to tenant primary, Announcements 3 Welcome Portal, Elevator Maintenance high priority, Holiday Party rooftop Dec 15; Events 2 Yoga in Park courtyard 3 days + Town Hall 7 days, Amenities from existing amenity spaces Conference Room A 10 capacity booking_rules min1 max4 advance30 + meeting rooms + Visitor Parking 20 capacity, Visitors 3 Alice/Bob/Carol + 2 preregistered visits + passes + pass_id linkage, Access Devices 4 Turnstile/Kiosk/Parking Gate/Elevator, Reservations 2 Weekly Team Meeting 9-10h next day 8 attendees + Client Presentation 14-15h 2 days 12 attendees |
| `00012_vendor_compliance_full.sql` | 3 Compliance Full | Vendor Contacts, Documents generic repository: documents (vendor/site/contract/coi, title, category insurance/contract/certification/safety/license/w9/other, status pending_review/verified/expired/rejected/archived, storage_path org/vendor/docs/file, file_name/size/mime, expiry/issue date, uploaded_by/verified_by/at, rejection_reason, metadata ocr_extracted coverage type); Compliance Rules: compliance_rules (org, name, description, vendor_type null=all, site_id null org-wide, required_coi_types text[] GL/WC/auto/umbrella, required_doc_categories, required_doc_types, min_coverage jsonb {GL:1M}, required_certifications, validity_days, is_active, severity low/med/high/critical, created_by); Contract Enhancements: approval_status pending/approved/rejected/expired, approved_by/at, rejection_reason, auto_renew, renewal_notice_days, payment_terms, contract_approvals history multi-approver (contract, approver, status, comments, decided_at); COI Enhancements: auto_extracted jsonb, rejection_reason, policy_number, insurer_name, additional_insured bool, certificate_holder; Vendor Approvals: vendor_approvals (vendor, site, status pending/approved/rejected/suspended/expired, approved_by/at, rejection_reason, compliance_check_id, notes); Notification Rules: notification_rules (org, site null org-wide, name, event_type coi_expiring/expired/contract_expiring/expired/compliance_failed/vendor_approval_needed/document_expiring, days_before int[] 30,7,1, channels in_app/email/slack, recipient_roles org_role[] admin/site_manager, recipient_user_ids specific); Compliance Audit Logs: compliance_audit_logs (vendor, site, rule_id, previous/new status compliant/non/pending/partial, issues jsonb, checked_by null system); Views: v_compliance_dashboard per vendor per site vendor_name/type/site_name/compliance_status/issues/active_contracts/valid/expiring/expired cois/expired_docs/next_expiry/total_coverage; v_vendor_summary per org aggregated overall_status; Functions: evaluate_vendor_compliance(vendor_id,site_id) loops active rules vendor_type/site match, foreach required_coi_type find latest valid/expiring COI, missing→non_compliant, expired→non, expiring within validity_days→pending, coverage<min→non, issues jsonb array, upsert compliance_status, audit log; evaluate_all_compliance(org_id null all) loops vendors x sites + org-wide; check_contract_expirations() expire past end_date + notify expiring 30d; check_document_expirations() notify 30d + expired; Crons evaluate-vendor-compliance 6am, check-contract-expirations 7am, check-document-expirations 7am; Realtime vendor_contacts/documents/rules/approvals/compliance_status/notification_rules |
| `00013_phase3_seed.sql` | 3 Seed | Compliance Rules: Default All GL1M+WC500k 30d high, HVAC Enhanced GL2M+WC1M+Auto1M 60d critical, Security GL2M+Auto high, Elevator High Risk GL5M+Umbrella5M+WC1M 90d critical; Vendor Contacts 2 per vendor John Manager primary + Billing, Notification Rules 5: COI Expiring 30/14/7/1 in_app/email admin/site_manager, COI Expired immediate in_app/email/slack owner/admin/manager, Contract Expiring 30/7, Compliance Failure immediate slack, Document Expiring 30/7; Documents Business License 2024 200 days expiry, OSHA 10 400 days, W9; Contracts updated approved + pending Cleaning Services 2025 Pending Approval; evaluate_all_compliance for demo org |
| `00014_analytics_full.sql` | 4 Analytics Full | KPI Definitions: kpi_definitions (org, name, key machine occupancy_rate/sla_breach_rate/etc, description, category operational/maintenance/compliance/occupancy/vendor/financial/tenant/visitor/safety, unit percent/count/hours/currency/ratio/days, target_value, higher_is_better, formula, is_active, unique org+key); create_default_kpis(org_id) seeds 13: Occupancy 95% higher true, SLA Breach 5% lower false, WOs Open 20 lower, Closed Today, Avg Response 4h lower, PM Ratio 70% higher, Compliance 100%, Non-Compliant 0 lower, Visitor Count, SR Avg 24h lower, Asset Health 95%, Labor Hours, Incidents Open 0 lower. Enhanced daily_site_stats added 13 columns occupancy_rate, compliance_rate, avg_response_time_hours, labor_hours, pm_work_orders, corrective, incidents_open/closed, inspections_completed/failed, total_assets, healthy_assets, reservation_count; Portfolio daily stats: portfolio_daily_stats (org, portfolio, date unique, total_sites, total_sq_ft bigint, occupancy avg, WOs open/closed/overdue, sla_breaches, visitor/service_requests, compliance_rate avg, occupancy_weighted, avg_response_time, labor_hours, incidents_open, total/healthy assets); Benchmarking views: v_building_benchmark per portfolio per date 30 days site_name/city/type/sq_ft/date/occupancy/compliance/WOs open/closed/sla/visitor/labor + portfolio_avg_occupancy/compliance/open_wos avg over partition + occupancy_rank/compliance_rank rank() over partition; v_asset_health_rollup per site total/active/maintenance/overdue_maintenance/warranty_expired/unhealthy/health_score %/open_wos; v_sla_metrics per site per day total/breached/overdue/avg_hours_to_complete/avg_sla/urgent/high; Reports: reports (org, portfolio/site nullable, name, type daily_ops/weekly_exec/monthly_portfolio/compliance/occupancy/maintenance/financial/custom, format json/csv/pdf, cron default Monday 7am, recipients emails[], recipient_user_ids, filters jsonb, status active/paused/archived, last/next run), report_runs (report_id, org, status pending/running/completed/failed, file_path org/reports/id/date/name.ext in site-files, file_size, row_count, error, started/completed); Functions: rollup_daily_stats_enhanced(date default yesterday) calculates occupancy leased leasable spaces/total leasable*100 from spaces, compliance compliant/total from compliance_status, avg response avg hours to complete WOs, labor sum hours, pm vs corrective counts, incidents open/closed, inspections completed/failed, assets total/healthy, reservations count, WOs open/closed/overdue/sla_breaches, visitor/service_requests counts, upserts daily_site_stats + calls rollup_portfolio_daily_stats, returns inserted count; rollup_portfolio_daily_stats aggregates daily to portfolio; rollup_daily_stats wrapper calls enhanced backward compat; get_site_kpis(site_id) jsonb site_id/date/occupancy/compliance/open/sla_breach_rate visitor_today/labor_7d/asset_health_score/avg_response RLS can_access_site GraphQL getSiteKPIs; get_portfolio_kpis(portfolio_id) jsonb total_sites/sq_ft/occupancy/compliance/open/sla_7d/labor_7d RLS is_org_member GraphQL getPortfolioKPIs; Grants + Realtime reports/run |
| `00015_phase4_seed.sql` | 4 Seed | Create default KPIs for demo org, rollup enhanced last 14 days, 4 sample reports Weekly Exec Summary portfolio weekly csv recipients demo@cre.local, Daily Ops 100 Main Tower site daily, Monthly Compliance org monthly, Occupancy Report weekly |

### 11 Edge Functions (Deno + Supabase)

| Function | Auth | Schedule | Purpose |
|----------|------|----------|---------|
| `health` | public | - | Heartbeat + cron status, database connected, GraphQL/Realtime URLs, portfolioSites count |
| `compliance-daily-check` | public (cron) | 0 9 * * * via config.toml + pg_cron | Daily 9am: scans COIs expiring 30d, leases expiring 30d, SLA breaches via rpc check_sla_breaches, compliance via check_coi_expirations, metrics rollup, groups by org/site/vendor, inserts notifications, Slack webhook + Resend email if env set |
| `generate-qr` | user JWT | - | POST asset_id, format svg/png → fetch asset, qr_code value, calls api.qrserver.com 500x500, uploads to site-files/{org}/{site}/assets/{id}/qr-{value}.svg with upsert, returns storage_path + signed URL 7 days |
| `send-visitor-pass` | user JWT | - | POST visit_id → fetches visit + visitor + site (join fallback separate queries), host, qr image URL qrserver 400x400, sends email via Resend API HTML with visitor name, site, date, purpose, QR image + code, address, 24h valid note, creates notification for host type visitor_arrived |
| `engineering-report` | user JWT | - | POST site_id, date default today, format json → fetches site, work_orders limit 50, inspections 50, incidents 20, assets 100, low stock qty<=5, builds summary open/completed today/overdue/inspections due/incidents open/assets total/low stock count, JSON, uploads to site-files/{org}/{site}/{date}/engineering-report-{date}.json |
| `visitor-kiosk` | public CORS | - | Lobby kiosk: POST action validate/check_in/check_out/stats, token, visit_id, device_id, site_id, date. validate → rpc validate_pass returns visitor_name/company/status/valid_until/is_blacklisted/host_name, check_in → rpc check_in_visitor token/device_id, check_out → check_out_visitor, stats → get_daily_visitor_stats + today's visits list, CORS * |
| `amenity-booking` | user JWT | - | POST action check_conflict/create, space_id, site_id, start/end, title, attendees, RLS via user JWT client supabase.schema(tenant).rpc check_reservation_conflict + create_reservation (conflict guard + notification) |
| `parse-coi-pdf` | service_role | - | POST storage_path or multipart file + org_id/vendor_id, downloads from buckets coi-documents/site-files/contract-documents, decodes text snippet first 50k, regex for dates MM/DD/YYYY/YYYY-MM-DD/Jan 12 2024, future dates sorted guess expiry earliest future, coverage regex $1,000,000 max $1k-10M, policy Policy No XXX, insurer Insurer: or common names Travelers/Hartford etc, type guess filename/text workers/WC→workers_comp auto→auto umbrella→umbrella else GL, additional insured regex, returns extracted {expiry, policy, insurer, coverage, type, additional_insured, confidence very_low/low/medium, all_dates, coverages, raw snippet 1000}, if org/vendor + expiry found → auto-inserts cois pending_review with auto_extracted |
| `compliance-report` | user JWT | - | POST org_id/site_id, format json/csv, if site: v_compliance_dashboard filter site_id, if org: v_vendor_summary + dashboard limit 200, summary total_vendors/compliant/non/pending/expiring/expired/active_contracts, CSV header vendor_name,type,site,compliance_status,active_contracts,valid/expiring/expired/next_expiry, uploads to site-files/{org}/reports/compliance-{site|org}-{date}.csv + signed URL 7d + preview 2000 chars JSON |
| `scheduled-reports` | service_role | 0 7 * * * daily via config.toml | POST report_id optional or cron no body finds due reports where next_run_at<=now active limit 20, per report type: daily_ops/weekly_exec → daily_site_stats last 7/30d filter site, compliance → v_compliance_dashboard, occupancy → spaces leasable, builds CSV headers rows, fileContent csv/json based on format, upload to site-files/{org}/reports/{report_id}/{date}/{safeName}-{date}.ext, signed URL 7d, update reports last_run now + next_run +7d or +1d based on cron, report_runs completed file_path/size/row_count, if Resend key + recipients emails download button, returns processed count |
| `export-data` | user JWT RLS | - | Generic export POST table allowed: work_orders/assets/inspections/incidents/service_requests/reservations/visits/access_logs/vendors/contracts/cois/compliance_status/daily_site_stats/spaces/leases, site_id/org_id, format csv/json, date_from/to, filters {}, limit 1000 min 5000, Authorization Bearer user JWT → supabase.schema(schema).from(table).select with user's JWT RLS enforced, returns JSON count+data or CSV headers all keys escaped quotes, Content-Disposition attachment filename |

### Storage (7 Buckets + RLS via folder path org_id/site_id)

- `avatars` public 2MB image/jpeg/png/webp/gif, path {user_id}/avatar.png, own upload/update/delete
- `site-files` private 100MB, path {org_id}/{site_id}/..., members view if is_org_member(org) && can_access_site(site), managers delete
- `floorplans` private 50MB pdf/image jpeg/png/svg, same RLS members view
- `coi-documents` private 20MB pdf/image, members manage via org_id folder
- `contract-documents` private 50MB pdf
- `visitor-photos` private 5MB jpeg/png
- `work-order-attachments` private 20MB, path org/site/work_orders/wo_id/file

### Scheduler (10+ pg_cron Jobs)

| Job | Schedule | SQL/Function | Purpose |
|-----|----------|--------------|---------|
| check-sla-breaches | */15 * * * * | `select ops.check_sla_breaches()` | WO sla_due_at < now → overdue + metadata + notification |
| generate-pm-work-orders | 0 2 * * * | `select ops.generate_pm_work_orders()` | Templates next_due<=now → create WOs per site + update next_due via recurrence |
| check-coi-expiration | 0 8-18 * * * | `select vendor.check_coi_expirations()` | COI expiring 30d→expiring + notif, expired→expired+notif, compliance_status upsert |
| rollup-daily-metrics | 0 3 * * * | `select metrics.rollup_daily_stats(current_date-1)` → enhanced | Daily site + portfolio rollup with occupancy/compliance/labor etc |
| cleanup-expired-visits | 0 4 * * * | delete visits checked_out <90d + notifications read <90d | Cleanup |
| lease-expiration-check | 0 9 * * 1 | insert notifications lease expiring 30d | Weekly Monday 9am lease |
| check-low-stock | 0 8 * * * | `insert notifications select * from ops.check_low_stock()` | Daily 8am low inventory |
| expire-visitor-passes | 0 * * * * | update passes valid_until<now → expired + visits preregistered scheduled<now-2h → no_show | Hourly |
| evaluate-vendor-compliance | 0 6 * * * | `select vendor.evaluate_all_compliance()` | Daily 6am evaluate all vendors x sites against rules |
| check-contract-expirations | 0 7 * * * | `select vendor.check_contract_expirations()` | Daily 7am expire contracts past end_date + notify 30d |
| check-document-expirations | 0 7 * * * | `select vendor.check_document_expirations()` | Daily 7am docs expiry |

Plus 2 scheduled Edge Functions in config.toml: `compliance-daily-check` 0 9 * * * and `scheduled-reports` 0 7 * * * (also triggerable via pg_net http_post)

### Types & Postman

- `types/database.ts` - Full Database type for 6 schemas, all tables, helper types (Organization, Site, WorkOrder, etc), enums OrgRole, SiteType, etc
- `types/supabase.ts` - Main export + helpers
- `types/README.md` - Usage guide
- `postman/PlutusPM.postman_collection.json` - 60+ requests in 10 folders (Setup, Auth, Portfolio/Sites, Building Ops, Tenant, Visitor, Compliance, Analytics, Edge Functions, Storage, Notifications) with auto JWT save Test scripts
- `postman/PlutusPM.postman_environment.json` - Env vars supabaseUrl local/cloud, anonKey, serviceRoleKey, userJwt, orgId, portfolioId, siteId, buildingId, floorId, spaceId, assetId, workOrderId, checklistId, inspectionId, vendorId, visitId, qrToken, deviceId

### Additional Docs

- `ARCHITECTURE.md` - Platform plan (updated to implemented)
- `architecture/diagrams/platform-overview.png` - Isometric visual
- `architecture/diagrams/data-model.html` - Interactive ER
- `docs/02-data-model-core.md` - Portfolio → Sites modeling
- `docs/03-graphql-strategy.md` - Why pg_graphql native, examples, custom mutations via functions
- `docs/04-scheduler-strategy.md` - pg_cron + pg_net + Scheduled Edge, monitoring
- `docs/05-rbac-rls-approach.md` - Memberships with site_ids[], helper functions, RLS templates, tenant/vendor isolation
- `docs/06-implementation-plan.md` - Phases 0-5 breakdown
- `docs/FRONTEND_GUIDE_FOR_DEV.md` - For frontend dev: connection, auth, GraphQL client, Realtime, Storage paths, RBAC UI gating, suggested build order
- `docs/graphql-examples.md` - 10 collections full copy/paste queries/mutations for all domains
- `docs/SETUP.md` - Setup instructions (old, now merged into README)
- `docs/PHASE1_BUILDING_OPS.md` - Phase 1 details
- `docs/PHASE2_TENANT_VISITOR.md` - Phase 2 details
- `docs/PHASE3_COMPLIANCE_VENDOR.md` - Phase 3 details
- `docs/PHASE4_ANALYTICS.md` - Phase 4 details
- `docs/CAPABILITY_COVERAGE.md` - Gap analysis 82 capabilities vs repo 94% implemented
- `postman/` + `types/` READMEs

---

## 🐳 How to Run Locally with Docker (Complete Guide)

This project runs entirely via **Supabase CLI which uses Docker** under the hood - you need Docker installed, not Postgres separately.

### Prerequisites

1. **Docker Desktop** (required for `supabase start`)
   - **Mac:** Install Docker Desktop from https://www.docker.com/products/docker-desktop/ → open it, ensure it's running (whale icon in menu bar)
   - **Windows:** Install Docker Desktop + WSL2 backend enabled, open Docker Desktop
   - **Linux:** `sudo apt-get install docker.io docker-compose` + `sudo systemctl start docker` + `sudo usermod -aG docker $USER` then re-login
   - Verify: `docker --version` and `docker ps` should work without error

2. **Supabase CLI**
   - **Mac (brew):** `brew install supabase/tap/supabase`
   - **Mac/Linux (npm):** `npm install -g supabase`
   - **Windows (scoop):** `scoop bucket add supabase https://github.com/supabase/scoop-bucket.git` + `scoop install supabase`
   - Verify: `supabase --version`

3. **Git + Node 18+ (optional but recommended for Edge Functions)**
   - `node --version` ≥ 18, `npm --version`

### 1. Clone & Setup

```bash
# Clone repo
git clone https://github.com/EmmanuelMat/PlutusPM.git
cd PlutusPM

# Check structure
ls supabase/migrations/ | wc -l # should be 15
ls supabase/functions/ # should be 11

# Copy env example (for reference, not strictly needed for local)
cp .env.example .env.local
# .env.local not used by supabase start locally - keys are printed in terminal output
# But add your external service keys if testing emails etc:
# RESEND_API_KEY=re_xxx
# SLACK_WEBHOOK_URL=https://hooks.slack.com/...
```

### 2. Start Supabase Stack (Docker)

This starts **Postgres 15 + PostgREST + GoTrue Auth + Realtime + Storage + Kong API Gateway + pg_graphql + pg_cron + Inbucket (email testing) + Studio** all via Docker containers.

```bash
# Start (first time pulls Docker images ~2-3 mins)
supabase start

# Expected output:
# Started supabase local development setup.
#
#          API URL: http://127.0.0.1:54321
#      GraphQL URL: http://127.0.0.1:54321/graphql/v1
#           DB URL: postgresql://postgres:postgres@127.0.0.1:54322/postgres
#       Studio URL: http://127.0.0.1:54323
#     Inbucket URL: http://127.0.0.1:54324
#       JWT secret: super-secret-jwt-token-with-at-least-32-characters-long
#         anon key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
# service_role key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
#   Dashboard URL: http://127.0.0.1:54323
# ... (all containers started)

# Check status anytime
supabase status

# Should show:
# API URL: http://127.0.0.1:54321
# GraphQL URL: http://127.0.0.1:54321/graphql/v1
# DB URL: ...
# Studio URL: http://127.0.0.1:54323
# Inbucket URL: http://127.0.0.1:54324 (test emails)

# If Docker not running, error: "Cannot connect to the Docker daemon"
# Solution: Open Docker Desktop and wait until green "Running"
```

### 3. Verify Migrations Applied

`supabase start` auto-runs all migrations in `supabase/migrations/` in order 00000 to 00015.

```bash
# List migrations
supabase migration list
# Local          | Remote | Time
# 00000_extensions |        | 
# ... all 15 should be applied

# If need to reset (drops DB and re-applies + seed):
supabase db reset

# This does:
# - Drops local Postgres
# - Re-creates with all migrations
# - Rebuilds GraphQL schema
# - NOTE: Does NOT run seed automatically - seed is manual step below (because it needs a user first)

# Check Postgres via SQL
supabase db execute --local "select count(*) from portfolio.sites;"
# Should be 0 before seed
```

### 4. Create First User (Auth)

You need an auth user before seeding demo data (seed uses first auth user as org owner).

**Option A - Via Studio (easiest):**

1. Open http://127.0.0.1:54323
2. Left sidebar → Authentication → Users → Add User → Create new user
   - Email: `demo@cre.local`
   - Password: `password123`
   - Auto Confirm User: ✅ checked
   - Create
3. Copy the User UUID (click user row)

**Option B - Via API/cURL:**

```bash
# Get anon key from supabase status output
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."

curl -X POST http://127.0.0.1:54321/auth/v1/signup \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "demo@cre.local",
    "password": "password123",
    "data": { "full_name": "Demo Admin" }
  }'

# Returns access_token + user id
```

**Option C - Via Postman:**

1. Import `postman/PlutusPM.postman_collection.json` + `postman/PlutusPM.postman_environment.json`
2. Set environment variables:
   - `supabaseUrl`: `http://127.0.0.1:54321`
   - `anonKey`: from `supabase status`
3. Run folder `1. Auth > Sign Up` → auto-saves `userJwt` and `userId`
4. Then `Sign In` if needed

### 5. Seed Demo Data

Nothing to do here - `supabase/seed.sql` runs automatically after every `supabase db reset`, creating four login-ready accounts (`demo@cre.local` / `manager2@cre.local` / `tenant@cre.local` / `tenant2@cre.local`, password `password123` for all) plus a fully populated org: 2 sites, 6 tenants with leases/occupancies/documents, 10 work orders, vendors, visitors, billing, campaigns, KB articles, and more. See `docs/SEED_DATA.md` for the full breakdown.

(The `00006`/`00008`/`00011`/`00013`/`00015` "Phase N Seed" migrations listed in the table above are dead code on a fresh reset - they check for a pre-existing `auth.users` row before doing anything, and none exists yet at the point migrations run. `docs/SEED_DATA.md` explains why in detail.)

**Verify seed:**

```sql
-- In Studio SQL Editor:
select 'orgs' as tbl, count(*) from platform.organizations
union all select 'portfolios', count(*) from portfolio.portfolios
union all select 'sites', count(*) from portfolio.sites
union all select 'spaces', count(*) from portfolio.spaces
union all select 'assets', count(*) from ops.assets
union all select 'work_orders', count(*) from ops.work_orders;

-- Should show:
-- orgs 1, portfolios 1, sites 2, spaces ~15, assets 3, work_orders maybe 0 initially etc
```

### 6. Test GraphQL (Native pg_graphql)

GraphQL endpoint is auto-exposed, no extra server.

**Via cURL (replace ANON_KEY and USER_JWT):**

```bash
ANON_KEY="eyJ..."
USER_JWT="eyJ..." # from Sign In response access_token

curl -X POST http://127.0.0.1:54321/graphql/v1 \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "query { portfolioSitesCollection { edges { node { id name city } } } }"
  }'

# Should return your 2 demo sites because RLS filters via memberships
```

**Via GraphiQL:**

- Use https://graphiql-online.com/ or https://altairgraphql.dev/
- Endpoint: `http://127.0.0.1:54321/graphql/v1`
- Headers: `apikey: <anonKey>`, `Authorization: Bearer <userJwt>`
- Query from `docs/graphql-examples.md`

**Via Postman:**

- Import collection, set env supabaseUrl + anonKey + userJwt (after sign in auto-saved)
- Run folder `0. Setup & Health > GraphQL - Introspection Test`
- Should return sites

### 7. Test Edge Functions Locally

Edge Functions are Deno, bundled with Supabase CLI.

```bash
# Serve all functions locally (in separate terminal, keep running)
supabase functions serve --env-file .env.local --debug

# Expected:
# Serving functions on http://127.0.0.1:54321/functions/v1/<function-name>
# health: http://127.0.0.1:54321/functions/v1/health
# etc for 11 functions

# In another terminal, test:

# Health (public)
curl http://127.0.0.1:54321/functions/v1/health -H "apikey: $ANON_KEY"

# Generate QR (needs user JWT)
curl -X POST http://127.0.0.1:54321/functions/v1/generate-qr \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{"asset_id": "your-asset-id-from-db", "format": "svg"}'

# Visitor Kiosk (public, CORS for lobby iPad)
curl -X POST http://127.0.0.1:54321/functions/v1/visitor-kiosk \
  -H "Content-Type: application/json" \
  -d '{"action": "stats", "site_id": "your-site-id"}'

# Scheduled reports (needs service_role)
SERVICE_KEY="eyJ..." # from supabase status service_role key
curl -X POST http://127.0.0.1:54321/functions/v1/scheduled-reports \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Note:** For functions needing Resend/Slack (send-visitor-pass, compliance-daily-check, scheduled-reports email), set env in `.env.local`:

```
RESEND_API_KEY=re_xxx
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

Then `supabase functions serve --env-file .env.local --debug` will load them. In cloud, set via `supabase secrets set`.

### 8. Test Storage

```bash
# Upload via Postman: Storage > Upload Site File
# Or via JS client:

# In browser console or Node:
# const supabase = createClient(URL, ANON, { auth: { persistSession: true } })
# await supabase.auth.signInWithPassword({ email, password })
# const { data: { user } } = await supabase.auth.getUser()
# const orgId = (await supabase.from('organizations').select('id').limit(1).single()).data.id
# const siteId = (await supabase.from('sites').select('id').limit(1).single()).data.id
# const file = new File(['hello'], 'test.txt')
# await supabase.storage.from('site-files').upload(`${orgId}/${siteId}/test.txt`, file)
```

Path must be `{org_id}/{site_id}/...` for RLS `can_access_site` to allow.

### 9. Test Cron Jobs & Scheduler

Cron jobs run inside Postgres via pg_cron extension. Locally, they won't auto-fire unless you have `supabase start` with cron enabled (it is enabled by default).

**Check cron status:**

```sql
-- In Studio SQL Editor:
select jobname, schedule, active, database from cron.job order by jobname;
-- Should list 10+ jobs: check-sla-breaches, generate-pm-work-orders, etc

select * from cron.job_run_details order by start_time desc limit 20;
-- Shows last runs status success/failed
```

**Manually trigger cron functions for testing:**

```sql
select ops.check_sla_breaches();
select ops.generate_pm_work_orders();
select vendor.check_coi_expirations();
select metrics.rollup_daily_stats_enhanced(current_date - 1);
select ops.check_low_stock();
select vendor.evaluate_all_compliance();
```

**Test scheduled Edge Functions via pg_net (calls HTTP):**

```sql
-- This simulates what pg_cron does with pg_net:
select net.http_post(
  url := 'http://host.docker.internal:54321/functions/v1/compliance-daily-check',
  headers := '{"Content-Type": "application/json"}'::jsonb
);
-- Check net._http_response for result:
select * from net._http_response order by created desc limit 5;
-- Note: host.docker.internal works inside Docker to reach host's 54321
```

### 10. Generate TypeScript Types (Optional)

After `supabase start` and migrations applied:

```bash
# Generate types for local
supabase gen types typescript --local > types/supabase-generated.ts

# Or for cloud project
supabase gen types typescript --project-id your-project-ref --schema public,platform,portfolio,ops,tenant,visitor,vendor,metrics > types/generated.ts

# We already provide manual types in types/database.ts which is more comprehensive (covers 6 schemas with custom logic)
# The generated one will be supplemental
```

### 11. Stop & Clean Up

```bash
# Stop containers (keeps data)
supabase stop

# Stop and delete data (fresh start next time)
supabase stop --no-backup

# Reset DB (drops and reapplies migrations, keeps containers running)
supabase db reset

# View logs
supabase logs db
supabase logs rest
supabase logs auth
supabase logs storage
supabase logs functions
```

### 12. Docker Troubleshooting

| Issue | Solution |
|-------|----------|
| `Cannot connect to the Docker daemon` | Open Docker Desktop, wait green Running, retry `supabase start` |
| `Port 54321 already in use` | `supabase stop` or `lsof -ti:54321 | xargs kill -9` or change port in config.toml [api] port |
| `Docker out of space` | Docker Desktop → Settings → Resources → Clean/Purge data, or `docker system prune` (removes unused images) |
| `supabase start` hangs at "Starting containers" | `docker ps -a` check if containers exist, `supabase stop --no-backup` then `supabase start` again, ensure Docker has 4GB RAM allocated in Settings |
| `pg_cron extension not found` | Run `supabase db reset`, check `supabase/migrations/00000_extensions.sql` enables pg_cron in pg_catalog, cloud projects have it enabled by default |
| `Storage upload 403 RLS` | Ensure folder path `{org_id}/{site_id}/...` with valid UUIDs you belong to via memberships, check `platform.can_access_site(site_id)` returns true |
| `GraphQL returns empty` | RLS: ensure memberships entry exists with site_ids null or containing that site, check `select platform.can_access_site('site-id')` |
| `Edge Functions 401 verify_jwt` | Check `supabase/config.toml` verify_jwt false for health/visitor-kiosk/compliance-daily-check/scheduled-reports, true for others. For true, need Authorization Bearer userJwt |

---

## Deploy to Supabase Cloud

### 1. Create Cloud Project

1. https://supabase.com/dashboard → New Project → name `plutuspm` → save DB password
2. Wait 2-3 mins provisioning
3. Settings → API → copy Project URL, anon key, service_role key (secret)
4. Settings → Database → Extensions → ensure `pg_cron`, `postgis`, `pg_graphql`, `pg_trgm`, `pg_net` enabled (most enabled by default on paid, for free tier enable manually via SQL: `create extension if not exists pg_cron with schema pg_catalog;` etc)

### 2. Link & Push Migrations

```bash
# Link local to cloud
supabase link --project-ref YOUR_PROJECT_REF # find ref in dashboard URL https://app.supabase.com/project/YOUR_REF

# Push migrations (15 files)
supabase db push

# Verify in Dashboard → Database → Migrations → should list 15 applied
# In SQL Editor → select * from cron.job; → should list 10 jobs
```

### 3. Deploy Edge Functions

```bash
# Deploy all 11 functions
supabase functions deploy health
supabase functions deploy compliance-daily-check
supabase functions deploy generate-qr
supabase functions deploy send-visitor-pass
supabase functions deploy engineering-report
supabase functions deploy visitor-kiosk
supabase functions deploy amenity-booking
supabase functions deploy parse-coi-pdf
supabase functions deploy compliance-report
supabase functions deploy scheduled-reports
supabase functions deploy export-data

# Or deploy all at once
supabase functions deploy --project-ref YOUR_REF

# Set secrets for functions needing external services
supabase secrets set RESEND_API_KEY=re_xxx --project-ref YOUR_REF
supabase secrets set SLACK_WEBHOOK_URL=https://hooks.slack.com/... --project-ref YOUR_REF
supabase secrets set SUPABASE_URL=https://YOUR_REF.supabase.co --project-ref YOUR_REF
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=your-service-role --project-ref YOUR_REF
supabase secrets set GOOGLE_CLIENT_ID=xxx --project-ref YOUR_REF
supabase secrets set GOOGLE_CLIENT_SECRET=xxx --project-ref YOUR_REF

# List secrets
supabase secrets list --project-ref YOUR_REF

# Logs
supabase functions logs compliance-daily-check --project-ref YOUR_REF
```

### 4. Seed Demo Data in Cloud (optional)

`supabase/seed.sql` only auto-runs on a *local* `supabase db reset` - `supabase db push` does not run it against a cloud project. If you want the same demo data there, run it manually:

Dashboard SQL Editor:

1. SQL Editor → New Query → paste the entire content of `supabase/seed.sql` → Run

The file is plain SQL (it inserts directly into `auth.users`/`auth.identities` rather than depending on a signup HTTP call), so this works as-is against a cloud project's SQL Editor. See `docs/SEED_DATA.md` for what it creates and the four login accounts it seeds.

### 5. Verify Cloud

- GraphQL: `https://YOUR_REF.supabase.co/graphql/v1` with apikey anon + Authorization Bearer user JWT from sign in against cloud URL
- Storage: buckets should exist in Dashboard → Storage (7 buckets)
- Cron: Dashboard → Database → Cron Jobs (or SQL `select * from cron.job`)
- Edge: Dashboard → Edge Functions → should list 11 with green active

---

## RBAC & Security

- Every table `enable row level security`
- Policies use `platform.can_access_site(site_id)` SECURITY DEFINER checking memberships site_ids null=all or contains + org_id match, or `is_org_member(org_id)`, `is_org_admin`, `is_site_manager`
- `memberships` site_ids[] + portfolio_ids[] + role 10 values: owner/admin/portfolio_manager/site_manager/building_engineer/security/tenant_admin/tenant_user/vendor/auditor
- Super admin flag `profiles.is_super_admin` bypasses
- **Frontend never gets service_role key** - GraphQL respects RLS auto
- All storage RLS via folder path parsing org_id/site_id + can_access_site

---

## Storage Buckets (7)

```
avatars/{user_id}/avatar.png public 2MB image/*
site-files/{org_id}/{site_id}/assets/{asset_id}/... private 100MB
floorplans/{org_id}/{site_id}/{building_id}/{floor_id}.pdf private 50MB pdf/image
coi-documents/{org_id}/{vendor_id}/{coi_id}.pdf private 20MB pdf/image
contract-documents/{org_id}/{vendor_id}/{contract_id}.pdf private 50MB pdf
visitor-photos/{org_id}/{site_id}/{visitor_id}.jpg private 5MB image/*
work-order-attachments/{org_id}/{site_id}/{work_order_id}/{file} private 20MB
```

RLS via foldername parsing.

---

## GraphQL Endpoint

- Local: `http://127.0.0.1:54321/graphql/v1`
- Cloud: `https://<ref>.supabase.co/graphql/v1`
- Headers:
  ```
  apikey: <anon_key>
  Authorization: Bearer <user_jwt> // from supabase.auth.getSession()
  Content-Type: application/json
  ```
- Sample query:
```graphql
query MyPortfolio {
  platformOrganizationsCollection { edges { node { id name slug } } }
  portfolioPortfoliosCollection {
    edges {
      node {
        id name
        portfolioSitesCollection {
          edges {
            node {
              id name city type status
              opsAssetsCollection(filter: {status: {eq: active}}) {
                edges { node { id name qrCode criticality } }
              }
              opsWorkOrdersCollection(filter: {status: {neq: completed}}, first: 5) {
                edges { node { id title priority slaDueAt } }
              }
            }
          }
        }
      }
    }
  }
}
```

---

## Types & Postman

- `types/database.ts` - Full Database type 6 schemas, helper types Organization, Site, WorkOrder, etc, enums OrgRole, SiteType
- `types/supabase.ts` - Main export + helpers UserWithMemberships
- `postman/PlutusPM.postman_collection.json` - 60+ requests in 10 folders (Setup, Auth auto-saves JWT, Portfolio/Sites, Building Ops, Tenant, Visitor, Compliance, Analytics, Edge Functions, Storage, Notifications) with Test scripts
- `postman/PlutusPM.postman_environment.json` - Env vars supabaseUrl local/cloud, anonKey, serviceRoleKey, userJwt, orgId, siteId, assetId, workOrderId, etc

**Frontend dev:** `npm i @supabase/supabase-js graphql-request` + import Database type + use `createClient<Database>`

---

## Testing Locally (No Frontend)

`supabase db reset` already seeds a full org (demo@cre.local / password123, see `docs/SEED_DATA.md`) - the steps below assume that data exists. To test against your own org instead of the seeded one:

```sql
-- 1. Create user via Studio → Auth
select auth.uid(); -- returns user id when logged via SQL Editor with JWT

-- 2. Create org
select platform.create_organization('My Company', 'my-company');

-- 3. Check RLS
select * from portfolio.sites; -- only allowed sites via memberships

-- 5. Create WO
select ops.create_work_order(
  (select id from portfolio.sites limit 1),
  'Fix lobby lights',
  'Flickering',
  null, null, 'high'::ops.priority_level, 'corrective'::ops.work_order_type
);

-- 6. Search
select * from portfolio.search_sites('Main', null, 10);
select * from portfolio.nearby_sites(30.2672, -97.7431, 5000, 10);

-- 7. KPIs
select metrics.get_site_kpis((select id from portfolio.sites limit 1));
select metrics.get_portfolio_kpis((select id from portfolio.portfolios limit 1));
select * from metrics.v_building_benchmark limit 5;
select * from vendor.v_compliance_dashboard limit 5;

-- 8. Visitor flow
select visitor.generate_pass_for_visit((select id from visitor.visits limit 1));
select * from visitor.validate_pass((select qr_token from visitor.passes limit 1));
select visitor.check_in_visitor((select qr_token from visitor.passes limit 1));

-- 9. Compliance
select vendor.evaluate_vendor_compliance((select id from vendor.vendors limit 1), (select id from portfolio.sites limit 1));
```

---

## Gap Analysis

See `docs/CAPABILITY_COVERAGE.md` - Maps 82 capabilities from Business Capability Architecture doc vs repo implementation:

- Building Operations 16/16 **100%**
- Tenant Experience 12 capabilities 11 full + 2 partial (Parking 80%, Community 50%) **92%**
- Visitor Management 15 capabilities 11 full + 4 partial (Security Dashboard 70%, Access Control 75%, Smart Locks 60% DB ready hardware needs adapter) **87%**
- Compliance & Vendor 12/12 **100%**
- Portfolio & Analytics 14/14 **100%**
- Shared Platform 13 capabilities 11 full + 2 partial Search 70% Workflow 65% Config 75% + Localization 0% **85%**
- **Overall ~94%**

P0 gaps to reach 98-100% code (no hardware): community_posts, parking_permits, v_security_dashboard view, check_access() function, search_assets/tenants/vendors/work_orders, audit triggers attachment, localization/config tables. Can be added in ~400 lines SQL.

---

## Need Customization?

Current covers CRE SaaS multi-tenant Portfolio → Sites model. Tell me your specific SaaS details and I'll tailor tables. For now Phase 0-4 complete covers:

- Multi-tenant orgs + portfolios + sites (center) + buildings + floors + spaces + leases + PostGIS + trigram search
- Building Ops full: Assets hierarchy QR, Maintenance History, PM Templates cron, WOs SLA, Checklists/Inspections scoring auto corrective WO, Inventory low stock cron, Labor trigger, Incidents, Asset Health view, Engineering Reports
- Tenant full: Tenants + contacts, Announcements + Events + RSVPs, Amenities + Reservations conflict check + approval, Service Requests auto WO, Feedback
- Visitor full: Visitors, Visits, Passes QR max_uses, Access Devices turnstile/kiosk/gate/elevator, Credentials NFC/BT, Blacklist, Access Logs, Host Notifications, Kiosk public Edge, Check-In/Out, Stats
- Compliance full: Vendors + contacts, Contracts approval workflow + auto_renew, COIs policy/insurer/additional_insured + OCR auto_extracted, Documents generic repo, Compliance Rules engine vendor_type + required_coi_types + min_coverage + validity_days, Notification Rules days_before channels recipient_roles, Compliance Status + Audit Logs, Dashboard views v_compliance_dashboard + v_vendor_summary, OCR Edge parse-coi-pdf + compliance-report CSV + scheduled-reports Edge weekly email + export-data generic
- Analytics full: daily_site_stats enhanced 13 cols occupancy/compliance/labor/pm/corrective/incidents/inspections/assets/reservations, portfolio_daily_stats rollup, KPI definitions 13 default, v_building_benchmark portfolio_avg + rank, v_asset_health_rollup, v_sla_metrics, Reports scheduled + Report Runs history + KPIs get_site_kpis/get_portfolio_kpis

Frontend can start NOW with `types/` + `postman/`.

Want types regenerated live? `supabase gen types typescript --local > types/supabase-generated.ts`
