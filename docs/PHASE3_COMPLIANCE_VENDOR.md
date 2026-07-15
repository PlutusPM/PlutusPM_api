# Phase 3 - Compliance & Vendor Management - Complete

**Status:** Built, migrations 00012 + 00013 + 2 new Edge Functions  
**Domain:** Compliance & Vendor Management (full)

## Overview

You already had basic vendor tables from Phase 0. Phase 3 adds **enterprise-grade compliance engine**.

### Before vs Now

| Before (Phase 0) | Now (Phase 3 Full) |
|------------------|-------------------|
| vendors basic | + vendor_contacts, approval workflow vendor_approvals |
| contracts basic | + approval_status, contract_approvals history, auto_renew, renewal_notice_days, rejection_reason |
| cois basic expiry | + policy_number, insurer_name, additional_insured, certificate_holder, auto_extracted jsonb (OCR), rejection_reason, verification workflow |
| compliance_status simple | + Full rules engine, audit logs, dashboard views, notification_rules |

### New Tables:

**vendor.vendor_contacts**
- Multiple contacts per vendor: `name, email, phone, role: Account Manager|Field Supervisor|Billing, is_primary, is_billing`

**vendor.documents** - Generic Document Repository
- `vendor_id, site_id, contract_id, coi_id, title, category: insurance|contract|certification|safety|license|w9|other, status: pending_review|verified|expired|rejected|archived, storage_path (org/vendor/docs/file), file_name, expiry_date, uploaded_by, verified_by, rejection_reason, metadata: {ocr_extracted: {}}`
- Covers safety certs, licenses, W9s beyond COIs/contracts
- RLS org member, storage buckets: `coi-documents`, `contract-documents`, `site-files`

**vendor.compliance_rules** - Rules Engine
- `name, description, vendor_type nullable (null=all, hvac, electrical, etc), site_id nullable (null=org-wide), required_coi_types text[] (general_liability, workers_comp, auto, umbrella, professional_liability), required_doc_categories, min_coverage jsonb {"general_liability":1000000}, validity_days (COI must be valid N days), is_active, severity low|medium|high|critical`
- Example rules seeded:
  - Default All Vendors: GL $1M + WC $500k, 30 days validity, high severity
  - HVAC Enhanced: GL $2M + WC $1M + Auto $1M, 60 days, critical
  - Security: GL $2M + Auto $1M
  - Elevator High Risk: GL $5M + Umbrella $5M + WC $1M, 90 days

**Contract Enhancements:**
- `approval_status: pending|approved|rejected|expired, approved_by, approved_at, rejection_reason, auto_renew bool, renewal_notice_days, payment_terms`
- `vendor.contract_approvals` - Multi-approver workflow history: `contract_id, approver_id, status, comments, decided_at`

**COI Enhancements:**
- `policy_number, insurer_name, additional_insured bool, certificate_holder, auto_extracted jsonb (from OCR), rejection_reason`

**vendor.vendor_approvals** - Vendor onboarding approval
- `vendor_id, site_id, status: pending|approved|rejected|suspended|expired, approved_by, approved_at, rejection_reason, compliance_check_id, notes`

**vendor.notification_rules** - Who gets notified for what
- `event_type: coi_expiring|coi_expired|contract_expiring|contract_expired|compliance_failed|vendor_approval_needed|document_expiring, days_before int[] (30,14,7,1), channels: in_app|email|slack, recipient_roles: org_role[] (admin, site_manager...), recipient_user_ids uuid[] specific, is_active`
- Seeded: 5 rules (COI expiring 30/14/7/1, COI expired immediate with slack, contract expiring 30/7, compliance failure, doc expiring)

**vendor.compliance_audit_logs**
- Audit trail: `vendor_id, site_id, rule_id, previous_status, new_status, issues jsonb, checked_by (null=system cron), created_at`
- Every time `evaluate_vendor_compliance()` runs, logs status change

### Dashboard Views:

**vendor.v_compliance_dashboard** - Per vendor per site detailed:
- vendor_name, type, site_name, compliance_status, issues, active_contracts count, valid_cois, expiring, expired, expired_docs, next_expiry_date, total_coverage
- Frontend: table with filters, sortable by next_expiry, status chip color

**vendor.v_vendor_summary** - Per org aggregated:
- sites_covered, active_contracts, valid/expiring/expired cois, last_compliance_check, overall_status (compliant if all sites compliant, else non_compliant/pending)

### Compliance Engine Functions:

**evaluate_vendor_compliance(vendor_id, site_id)**
- Core engine: loops active rules where `vendor_type` matches or null && site_id matches or null
- For each required_coi_type in rule:
  - Find existing COI with status valid|expiring, latest expiry
  - If missing → non_compliant issue missing_coi
  - If expiry < now → non_compliant expired_coi
  - If expiry < now+validity_days → pending expiring_coi
  - Check min_coverage: if coverage_amount < required → non_compliant insufficient_coverage
- Upsert into `compliance_status` with status + issues jsonb array
- Insert audit log
- Returns compliance_status row
- GraphQL: `evaluateVendorCompliance` mutation

**evaluate_all_compliance(org_id null=all)**
- Loops all vendors x sites, calls evaluate_vendor_compliance for each combo + org-wide (site_id null)
- Called by cron daily 6am, also manually after COI upload
- Returns count evaluated

**check_contract_expirations()**
- Sets contracts end_date < now && status active → expired + notification
- Notifies contracts expiring within 30 days
- Cron daily 7am

**check_document_expirations()**
- Notifies documents expiring 30 days, sets expired if past
- Cron daily 7am

### Crons (New):

| Job | Schedule | Function |
|-----|----------|----------|
| evaluate-vendor-compliance | 0 6 * * * | evaluate_all_compliance() |
| check-contract-expirations | 0 7 * * * | check_contract_expirations() |
| check-document-expirations | 0 7 * * * | check_document_expirations() |

Existing crons still run: SLA 15m, PM 2am, metrics 3am, compliance-notif via edge 9am, etc.

### Edge Functions:

**parse-coi-pdf** - OCR Extraction

- **POST** either:
  - JSON `{storage_path: "org/vendor/coi.pdf", org_id, vendor_id}` → downloads from storage buckets (coi-documents, site-files, etc) + extracts
  - Multipart `file` upload + vendor_id, org_id
- **Extraction heuristics (MVP):**
  - Tries to decode PDF text (for text-based PDFs)
  - Regex for dates: `MM/DD/YYYY`, `YYYY-MM-DD`, `Jan 12, 2024`
  - Future dates sorted → guess expiry = earliest future date
  - Coverage: regex `\$?\s?1,000,000` → max value between $1k-$10M
  - Policy number: `Policy No: XXX`
  - Insurer: `Insurer: ` or common insurer names list (Travelers, Hartford...)
  - COI type guess from filename/text: workers/comp/wc → workers_comp, auto → auto, umbrella → umbrella, else general_liability
  - Additional insured: /additional insured/i
- Returns:
```json
{
  "extracted": {
    "expiry_date": "2025-12-31",
    "policy_number": "GL-123456",
    "insurer_name": "Travelers",
    "coverage_amount": 2000000,
    "type": "general_liability",
    "additional_insured": true,
    "confidence": "medium",
    "all_dates_found": [...],
    "coverages_found": [...]
  },
  "coi_record": { // if org_id+vendor_id provided and expiry found, auto-inserted as pending_review
    "id": "uuid",
    "status": "pending_review"
  }
}
```
- **Next steps:** Frontend shows extracted data for user verification → user confirms → set status to valid → triggers compliance re-evaluation
- **Production upgrade path:** Replace regex with AWS Textract / Google Document AI / OpenAI Vision via API call inside function (I left comments)

**compliance-report** - Dashboard Report Generator

- POST `{org_id?, site_id?, format: json|csv}`
- If site_id: queries `v_compliance_dashboard` filtered by site, evaluates fresh compliance, returns summary + complianceData
- If org_id: queries `v_vendor_summary` + dashboard view limit 200
- Summary: total_vendors, compliant, non_compliant, pending, expiring_cois, expired_cois, active_contracts
- **CSV mode:** Generates CSV header `vendor_name,vendor_type,site_name,compliance_status,active_contracts,valid_cois,expiring_cois,expired_cois,next_expiry_date` + uploads to `site-files/{org_id}/reports/compliance-{site|org}-{date}.csv` with signed URL 7 days + returns preview
- **JSON mode:** Stores JSON to `site-files/{org}/reports/compliance-report-{date}.json`
- For scheduled reports, cron can call this function via pg_net to auto-email?

### GraphQL for Frontend:

```graphql
# Vendor with contacts & docs
query Vendors($orgId: UUID!) {
  vendorVendorsCollection(filter: {orgId: {eq: $orgId}}) {
    edges { node {
      id name type status
      vendorVendorContactsCollection { edges { node { name email role isPrimary } } }
      vendorContractsCollection { edges { node { title status approvalStatus endDate value } } }
      vendorCoisCollection { edges { node { type expiryDate status coverageAmount insurerName } } }
      vendorComplianceStatusCollection { edges { node { status issues lastChecked } } }
    } }
  }
}

# Evaluate compliance manually after COI upload
mutation Eval($vendorId: UUID!, $siteId: UUID) {
  vendorEvaluateVendorCompliance(input: {pVendorId: $vendorId, pSiteId: $siteId}) {
    vendorId siteId status issues lastChecked
  }
}

# Compliance dashboard
query Dashboard($siteId: UUID!) {
  vendorVComplianceDashboardCollection(filter: {siteId: {eq: $siteId}}) {
    edges { node {
      vendorId vendorName vendorType siteName complianceStatus activeContracts validCois expiringCois expiredCois nextExpiryDate totalCoverage issues
    } }
  }
}

query Summary($orgId: UUID!) {
  vendorVVendorSummaryCollection(filter: {orgId: {eq: $orgId}}) {
    edges { node { vendorId name type status sitesCovered activeContracts validCois expiringCois expiredCois overallStatus lastComplianceCheck } }
  }
}

# Compliance rules
query Rules($orgId: UUID!) {
  vendorComplianceRulesCollection(filter: {orgId: {eq: $orgId}, isActive: {eq: true}}) {
    edges { node { id name vendorType requiredCoiTypes minCoverage validityDays severity } }
  }
}

mutation CreateRule($orgId: UUID!, $name: String!, $types: [String!]!) {
  insertIntoVendorComplianceRulesCollection(objects: [{orgId: $orgId, name: $name, requiredCoiTypes: $types}]) {
    records { id }
  }
}
```

### Testing Phase 3:

```sql
-- Rules
select * from vendor.compliance_rules where org_id = (select id from platform.organizations where slug='demo-cre');

-- Evaluate vendor
select vendor.evaluate_vendor_compliance(
  (select id from vendor.vendors limit 1),
  (select id from portfolio.sites limit 1)
);

-- Evaluate all
select vendor.evaluate_all_compliance((select id from platform.organizations where slug='demo-cre'));

-- Dashboard views
select * from vendor.v_compliance_dashboard limit 5;
select * from vendor.v_vendor_summary limit 5;

-- Expirations
select vendor.check_contract_expirations();
select vendor.check_document_expirations();

-- Audit logs
select * from vendor.compliance_audit_logs order by created_at desc limit 5;
```

### Frontend Tasks Unlocked:

1. **Vendor Directory:** list + status chip (compliant/non_compliant/pending), overall_status from summary view
2. **Vendor Detail:** contacts, contracts (approval status workflow), COIs table with expiry countdown (30/7/1 day yellow/red), documents gallery, compliance issues list (missing COI, insufficient coverage) with action buttons
3. **Compliance Dashboard:** site selector → table v_compliance_dashboard with filters (non_compliant only), next_expiry date, coverage, quick action evaluate
4. **COI Upload + OCR:** upload file to `coi-documents/{org}/{vendor_id}/` → call `parse-coi-pdf` with storage_path → show extracted form for verification → user edits → confirm → insert/update coi record status valid → call evaluate_vendor_compliance → toast compliance result
5. **Contract Approval:** pending contracts list, approver can approve/reject with comments → updates contract_approvals + contracts approval_status
6. **Notification Rules:** admin UI to create rules (event_type, days_before, channels, recipient_roles)
7. **Reports:** Generate compliance-report CSV for site → download signed URL + email to managers (can add cron to auto-call compliance-report weekly Monday 9am)

---

## Next Phase 4: Portfolio & Analytics (final)

Will add:
- metrics rollup enhanced with compliance_rate, occupancy from leases
- KPI definitions table + exec dashboards views per portfolio (benchmarking)
- Scheduled reports edge function that generates PDF/CSV weekly and emails
- benchmarking: site vs portfolio average

Phase 3 completes 4 of 5 domains. Only Analytics left!
