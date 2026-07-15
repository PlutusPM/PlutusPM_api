// types/database.ts - Complete Supabase TypeScript Types for PlutusPM CRE SaaS
// Generated manually from migrations 00000-00015
// Use: import { Database } from './types/database'
// For Supabase JS: createClient<Database>(URL, KEY)

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  platform: {
    Tables: {
      organizations: {
        Row: {
          id: string
          name: string
          slug: string
          owner_id: string | null
          billing_tier: 'starter' | 'growth' | 'enterprise'
          settings: Json
          created_at: string
          updated_at: string
        }
        Insert: {
          id?: string
          name: string
          slug: string
          owner_id?: string | null
          billing_tier?: 'starter' | 'growth' | 'enterprise'
          settings?: Json
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?: string
          name?: string
          slug?: string
          owner_id?: string | null
          billing_tier?: 'starter' | 'growth' | 'enterprise'
          settings?: Json
          created_at?: string
          updated_at?: string
        }
      }
      profiles: {
        Row: {
          id: string
          email: string | null
          full_name: string | null
          avatar_url: string | null
          phone: string | null
          is_super_admin: boolean
          preferences: Json
          created_at: string
          updated_at: string
        }
        Insert: {
          id: string
          email?: string | null
          full_name?: string | null
          avatar_url?: string | null
          phone?: string | null
          is_super_admin?: boolean
          preferences?: Json
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?: string
          email?: string | null
          full_name?: string | null
          avatar_url?: string | null
          phone?: string | null
          is_super_admin?: boolean
          preferences?: Json
          created_at?: string
          updated_at?: string
        }
      }
      memberships: {
        Row: {
          id: string
          org_id: string
          user_id: string
          role: 'owner' | 'admin' | 'portfolio_manager' | 'site_manager' | 'building_engineer' | 'security' | 'tenant_admin' | 'tenant_user' | 'vendor' | 'auditor'
          portfolio_ids: string[] | null
          site_ids: string[] | null
          created_at: string
          created_by: string | null
        }
        Insert: {
          id?: string
          org_id: string
          user_id: string
          role?: 'owner' | 'admin' | 'portfolio_manager' | 'site_manager' | 'building_engineer' | 'security' | 'tenant_admin' | 'tenant_user' | 'vendor' | 'auditor'
          portfolio_ids?: string[] | null
          site_ids?: string[] | null
          created_at?: string
          created_by?: string | null
        }
        Update: {
          id?: string
          org_id?: string
          user_id?: string
          role?: 'owner' | 'admin' | 'portfolio_manager' | 'site_manager' | 'building_engineer' | 'security' | 'tenant_admin' | 'tenant_user' | 'vendor' | 'auditor'
          portfolio_ids?: string[] | null
          site_ids?: string[] | null
          created_at?: string
          created_by?: string | null
        }
      }
      audit_logs: {
        Row: {
          id: string
          org_id: string | null
          site_id: string | null
          user_id: string | null
          action: 'create' | 'update' | 'delete' | 'login' | 'export' | 'import'
          entity: string
          entity_id: string | null
          diff: Json | null
          ip_address: string | null
          user_agent: string | null
          created_at: string
        }
      }
      notifications: {
        Row: {
          id: string
          org_id: string
          site_id: string | null
          user_id: string | null
          type: 'sla_breach' | 'coi_expiring' | 'coi_expired' | 'work_order_assigned' | 'service_request_created' | 'visitor_arrived' | 'lease_expiring' | 'compliance_issue' | 'system' | 'report_ready' | 'reservation_reminder' | 'contract_expiring' | 'contract_expired' | 'document_expiring'
          title: string
          body: string | null
          payload: Json
          is_read: boolean
          read_at: string | null
          created_at: string
        }
      }
    }
  }
  portfolio: {
    Tables: {
      portfolios: {
        Row: {
          id: string
          org_id: string
          name: string
          description: string | null
          color: string
          manager_id: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      sites: {
        Row: {
          id: string
          org_id: string
          portfolio_id: string | null
          name: string
          slug: string
          type: 'office' | 'retail' | 'industrial' | 'lab' | 'hospitality' | 'multifamily' | 'mixed_use' | 'medical' | 'education' | 'datacenter' | 'other'
          status: 'active' | 'onboarding' | 'inactive' | 'disposed' | 'draft'
          address_line1: string | null
          address_line2: string | null
          city: string | null
          state: string | null
          zip_code: string | null
          country: string
          timezone: string
          location: unknown | null // PostGIS geography
          latitude: number | null
          longitude: number | null
          sq_ft: number | null
          year_built: number | null
          floors_count: number
          manager_id: string | null
          external_id: string | null
          metadata: Json
          created_at: string
          updated_at: string
          created_by: string | null
        }
      }
      buildings: {
        Row: {
          id: string
          org_id: string
          site_id: string
          name: string
          description: string | null
          floors_count: number
          sq_ft: number | null
          year_built: number | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      floors: {
        Row: {
          id: string
          org_id: string
          site_id: string
          building_id: string
          level_number: number
          name: string
          display_name: string | null
          sq_ft: number | null
          floorplan_path: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      spaces: {
        Row: {
          id: string
          org_id: string
          site_id: string
          building_id: string | null
          floor_id: string | null
          name: string
          code: string | null
          type: 'leasable' | 'common' | 'amenity' | 'parking' | 'storage' | 'external' | 'mechanical' | 'other'
          status: 'vacant' | 'occupied' | 'reserved' | 'maintenance' | 'out_of_service'
          area_sq_ft: number | null
          capacity: number | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      leases: {
        Row: {
          id: string
          org_id: string
          site_id: string
          space_id: string | null
          external_tenant_name: string | null
          tenant_id: string | null
          start_date: string
          end_date: string
          status: 'draft' | 'active' | 'expired' | 'terminated' | 'pending'
          monthly_rent: number | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
    }
  }
  ops: {
    Tables: {
      asset_categories: {
        Row: { id: string; org_id: string; name: string; icon: string | null; color: string; created_at: string }
      }
      assets: {
        Row: {
          id: string
          org_id: string
          site_id: string
          building_id: string | null
          floor_id: string | null
          space_id: string | null
          category_id: string | null
          parent_asset_id: string | null
          name: string
          description: string | null
          qr_code: string
          status: 'active' | 'inactive' | 'maintenance' | 'retired' | 'ordered'
          criticality: 'low' | 'medium' | 'high' | 'critical'
          manufacturer: string | null
          model: string | null
          serial_number: string | null
          install_date: string | null
          warranty_end: string | null
          last_maintenance_at: string | null
          next_maintenance_at: string | null
          location_description: string | null
          qr_code_last_printed_at: string | null
          metadata: Json
          created_at: string
          updated_at: string
          created_by: string | null
        }
      }
      asset_maintenance_history: {
        Row: {
          id: string
          org_id: string
          site_id: string
          asset_id: string
          work_order_id: string | null
          type: 'inspection' | 'preventive' | 'corrective' | 'installation' | 'decommission' | 'audit'
          title: string
          description: string | null
          performed_by: string | null
          performed_at: string
          cost: number
          labor_hours: number
          metadata: Json
          created_at: string
        }
      }
      work_order_templates: {
        Row: {
          id: string
          org_id: string
          site_id: string | null
          name: string
          description: string | null
          asset_category_id: string | null
          type: 'preventive' | 'corrective' | 'inspection' | 'service_request' | 'incident'
          priority: 'low' | 'medium' | 'high' | 'urgent'
          estimated_hours: number | null
          checklist: Json
          recurrence_rule: string | null
          next_due_at: string | null
          is_active: boolean
          created_at: string
          updated_at: string
        }
      }
      work_orders: {
        Row: {
          id: string
          org_id: string
          site_id: string
          building_id: string | null
          floor_id: string | null
          space_id: string | null
          asset_id: string | null
          template_id: string | null
          type: 'preventive' | 'corrective' | 'inspection' | 'service_request' | 'incident'
          title: string
          description: string | null
          priority: 'low' | 'medium' | 'high' | 'urgent'
          status: 'open' | 'in_progress' | 'on_hold' | 'completed' | 'cancelled' | 'overdue'
          assigned_to: string | null
          created_by: string | null
          due_date: string | null
          sla_due_at: string | null
          completed_at: string | null
          labor_hours: number
          cost: number
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      checklists: {
        Row: {
          id: string
          org_id: string
          site_id: string | null
          name: string
          description: string | null
          category: string | null
          version: number
          is_active: boolean
          is_required: boolean
          estimated_minutes: number | null
          metadata: Json
          created_by: string | null
          created_at: string
          updated_at: string
        }
      }
      checklist_items: {
        Row: {
          id: string
          checklist_id: string
          parent_item_id: string | null
          sort_order: number
          label: string
          description: string | null
          item_type: 'pass_fail' | 'yes_no' | 'numeric' | 'text' | 'photo' | 'signature' | 'multiple_choice'
          is_required: boolean
          options: Json
          expected_value: Json | null
          metadata: Json
          created_at: string
        }
      }
      inspections: {
        Row: {
          id: string
          org_id: string
          site_id: string
          asset_id: string | null
          building_id: string | null
          floor_id: string | null
          space_id: string | null
          checklist_id: string | null
          work_order_id: string | null
          title: string
          status: 'draft' | 'in_progress' | 'completed' | 'failed' | 'cancelled' | 'overdue'
          score: number | null
          assigned_to: string | null
          created_by: string | null
          scheduled_at: string | null
          started_at: string | null
          completed_at: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      inspection_items: {
        Row: {
          id: string
          inspection_id: string
          checklist_item_id: string
          status: 'pass' | 'fail' | 'na' | 'flagged' | 'pending' | null
          response_text: string | null
          response_numeric: number | null
          response_options: Json | null
          is_flagged: boolean
          notes: string | null
          photo_paths: string[] | null
          scored: number
          answered_by: string | null
          answered_at: string | null
          created_at: string
        }
      }
      work_order_comments: {
        Row: {
          id: string
          work_order_id: string
          org_id: string
          site_id: string
          user_id: string
          comment: string
          is_internal: boolean
          created_at: string
        }
      }
      work_order_attachments: {
        Row: {
          id: string
          work_order_id: string
          org_id: string
          site_id: string
          file_name: string
          file_size: number | null
          mime_type: string | null
          storage_path: string
          uploaded_by: string | null
          created_at: string
        }
      }
      inventory_categories: { Row: { id: string; org_id: string; name: string; description: string | null } }
      inventory_items: {
        Row: {
          id: string
          org_id: string
          category_id: string | null
          name: string
          sku: string | null
          description: string | null
          unit: string
          cost_per_unit: number | null
          supplier: string | null
          min_stock_level: number
          is_active: boolean
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      inventory_stock: {
        Row: {
          id: string
          org_id: string
          site_id: string
          inventory_item_id: string
          quantity: number
          location: string | null
          created_at: string
          updated_at: string
        }
      }
      stock_transactions: {
        Row: {
          id: string
          org_id: string
          site_id: string
          inventory_item_id: string
          stock_id: string | null
          work_order_id: string | null
          type: 'in' | 'out' | 'adjustment' | 'transfer' | 'return'
          quantity: number
          reason: string | null
          performed_by: string | null
          created_at: string
        }
      }
      labor_logs: {
        Row: {
          id: string
          org_id: string
          site_id: string
          work_order_id: string
          user_id: string
          hours: number
          rate: number | null
          total_cost: number
          description: string | null
          logged_at: string
          created_at: string
        }
      }
      incidents: {
        Row: {
          id: string
          org_id: string
          site_id: string
          building_id: string | null
          floor_id: string | null
          space_id: string | null
          asset_id: string | null
          work_order_id: string | null
          title: string
          description: string | null
          severity: 'low' | 'medium' | 'high' | 'critical'
          status: 'reported' | 'investigating' | 'resolved' | 'closed' | 'escalated'
          category: string | null
          reported_by: string | null
          assigned_to: string | null
          occurred_at: string
          resolved_at: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
    }
  }
  tenant: {
    Tables: {
      tenants: {
        Row: {
          id: string
          org_id: string
          site_id: string
          company_name: string
          legal_name: string | null
          contact_email: string | null
          contact_phone: string | null
          logo_url: string | null
          industry: string | null
          employee_count: number | null
          primary_contact_id: string | null
          status: string
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      tenant_contacts: {
        Row: {
          id: string
          tenant_id: string
          profile_id: string
          org_id: string
          site_id: string
          role: 'primary' | 'admin' | 'member' | 'billing' | 'facility'
          is_primary: boolean
          created_at: string
        }
      }
      service_requests: {
        Row: {
          id: string
          org_id: string
          site_id: string
          space_id: string | null
          tenant_id: string | null
          tenant_contact_id: string | null
          title: string
          description: string | null
          category: string | null
          priority: 'low' | 'medium' | 'high' | 'urgent'
          status: 'open' | 'in_progress' | 'completed' | 'cancelled' | 'on_hold'
          work_order_id: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
      }
      reservations: {
        Row: {
          id: string
          org_id: string
          site_id: string
          space_id: string
          amenity_id: string | null
          reserved_by: string
          title: string | null
          start_time: string
          end_time: string
          status: 'pending' | 'confirmed' | 'cancelled' | 'completed' | 'no_show'
          approval_status: 'pending' | 'approved' | 'denied'
          approved_by: string | null
          attendees: number | null
          metadata: Json
          created_at: string
        }
      }
      amenities: {
        Row: {
          id: string
          org_id: string
          site_id: string
          space_id: string
          name: string
          description: string | null
          category: 'conference_room' | 'meeting_room' | 'gym' | 'rooftop' | 'lounge' | 'parking' | 'event_space' | 'kitchen' | 'other'
          capacity: number | null
          hourly_rate: number
          is_bookable: boolean
          booking_rules: Json
          image_urls: string[] | null
          amenities_list: string[] | null
          created_at: string
          updated_at: string
        }
      }
      announcements: {
        Row: {
          id: string
          org_id: string
          site_id: string
          building_id: string | null
          title: string
          body: string
          summary: string | null
          audience: 'all' | 'tenants' | 'staff' | 'tenant_specific' | 'building_specific'
          priority: 'low' | 'normal' | 'high' | 'urgent'
          tenant_id: string | null
          publish_at: string
          expires_at: string | null
          is_published: boolean
          image_url: string | null
          attachment_paths: string[] | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
      }
      events: {
        Row: {
          id: string
          org_id: string
          site_id: string
          title: string
          description: string | null
          location_text: string | null
          space_id: string | null
          start_at: string
          end_at: string
          capacity: number | null
          is_public: boolean
          requires_rsvp: boolean
          rsvp_deadline: string | null
          image_url: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
      }
      event_rsvps: {
        Row: {
          id: string
          event_id: string
          org_id: string
          site_id: string
          profile_id: string
          status: 'going' | 'interested' | 'not_going' | 'waitlist'
          guests: number
          created_at: string
        }
      }
      feedback: {
        Row: {
          id: string
          org_id: string
          site_id: string
          profile_id: string
          type: 'service_request' | 'work_order' | 'amenity' | 'event' | 'general' | 'complaint' | 'suggestion'
          related_id: string | null
          rating: number | null
          comment: string | null
          is_anonymous: boolean
          created_at: string
        }
      }
    }
  }
  visitor: {
    Tables: {
      visitors: {
        Row: {
          id: string
          org_id: string
          email: string | null
          full_name: string
          company: string | null
          phone: string | null
          id_type: string | null
          id_last4: string | null
          photo_path: string | null
          metadata: Json
          created_at: string
        }
      }
      visits: {
        Row: {
          id: string
          org_id: string
          site_id: string
          visitor_id: string
          host_user_id: string | null
          host_space_id: string | null
          purpose: string | null
          status: 'preregistered' | 'checked_in' | 'checked_out' | 'cancelled' | 'denied' | 'no_show'
          scheduled_at: string
          checked_in_at: string | null
          checked_out_at: string | null
          checked_in_by: string | null
          checked_out_by: string | null
          host_notified_at: string | null
          qr_code: string | null
          pass_id: string | null
          nda_signed: boolean
          visitor_company_verified: boolean
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      passes: {
        Row: {
          id: string
          org_id: string
          site_id: string
          visit_id: string
          visitor_id: string
          qr_token: string
          type: 'day' | 'multi_day' | 'recurring' | 'contractor' | 'vip'
          status: 'active' | 'used' | 'expired' | 'revoked' | 'pending'
          valid_from: string
          valid_until: string
          max_uses: number
          used_count: number
          issued_by: string | null
          issued_at: string
          revoked_at: string | null
          revoked_by: string | null
          metadata: Json
          created_at: string
        }
      }
      access_devices: {
        Row: {
          id: string
          org_id: string
          site_id: string
          building_id: string | null
          floor_id: string | null
          name: string
          device_type: 'turnstile' | 'door_lock' | 'gate' | 'elevator' | 'parking_gate' | 'kiosk' | 'other'
          identifier: string | null
          access_point: string | null
          is_online: boolean
          is_active: boolean
          last_seen_at: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      access_credentials: {
        Row: {
          id: string
          org_id: string
          site_id: string | null
          user_id: string | null
          visitor_id: string | null
          type: 'nfc' | 'bluetooth' | 'qr' | 'pin' | 'mobile' | 'card'
          credential_id: string
          is_active: boolean
          expires_at: string | null
          issued_at: string
          metadata: Json
          created_at: string
        }
      }
      access_logs: {
        Row: {
          id: string
          org_id: string
          site_id: string
          visit_id: string | null
          device_id: string | null
          access_point: string | null
          event: 'granted' | 'denied' | 'tailgate' | 'forced'
          timestamp: string
          metadata: Json
        }
      }
      blacklist: {
        Row: {
          id: string
          org_id: string
          visitor_id: string | null
          email: string | null
          full_name: string | null
          reason: string
          severity: 'low' | 'medium' | 'high' | 'critical'
          added_by: string | null
          expires_at: string | null
          is_active: boolean
          created_at: string
        }
      }
    }
  }
  vendor: {
    Tables: {
      vendors: {
        Row: {
          id: string
          org_id: string
          name: string
          type: 'cleaning' | 'hvac' | 'electrical' | 'plumbing' | 'security' | 'landscaping' | 'elevator' | 'fire_safety' | 'general' | 'other'
          status: string
          website: string | null
          contact_email: string | null
          contact_phone: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      vendor_contacts: {
        Row: {
          id: string
          vendor_id: string
          org_id: string
          name: string
          email: string | null
          phone: string | null
          role: string | null
          is_primary: boolean
          is_billing: boolean
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      contracts: {
        Row: {
          id: string
          org_id: string
          vendor_id: string
          site_id: string | null
          title: string
          description: string | null
          status: 'draft' | 'active' | 'expired' | 'terminated' | 'pending_renewal'
          approval_status: 'pending' | 'approved' | 'rejected' | 'expired'
          approved_by: string | null
          approved_at: string | null
          rejection_reason: string | null
          auto_renew: boolean
          renewal_notice_days: number
          payment_terms: string | null
          start_date: string | null
          end_date: string | null
          value: number | null
          storage_path: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      cois: {
        Row: {
          id: string
          org_id: string
          vendor_id: string
          contract_id: string | null
          site_id: string | null
          type: string
          issue_date: string | null
          expiry_date: string
          status: 'valid' | 'expiring' | 'expired' | 'missing' | 'pending_review'
          coverage_amount: number | null
          policy_number: string | null
          insurer_name: string | null
          additional_insured: boolean
          certificate_holder: string | null
          auto_extracted: Json
          rejection_reason: string | null
          storage_path: string | null
          verified_at: string | null
          verified_by: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      documents: {
        Row: {
          id: string
          org_id: string
          vendor_id: string
          site_id: string | null
          contract_id: string | null
          coi_id: string | null
          title: string
          description: string | null
          category: 'insurance' | 'contract' | 'certification' | 'safety' | 'license' | 'w9' | 'other'
          status: 'pending_review' | 'verified' | 'expired' | 'rejected' | 'archived'
          storage_path: string
          file_name: string | null
          file_size: number | null
          mime_type: string | null
          expiry_date: string | null
          issue_date: string | null
          uploaded_by: string | null
          verified_by: string | null
          verified_at: string | null
          rejection_reason: string | null
          metadata: Json
          created_at: string
          updated_at: string
        }
      }
      compliance_rules: {
        Row: {
          id: string
          org_id: string
          name: string
          description: string | null
          vendor_type: 'cleaning' | 'hvac' | 'electrical' | 'plumbing' | 'security' | 'landscaping' | 'elevator' | 'fire_safety' | 'general' | 'other' | null
          site_id: string | null
          required_coi_types: string[]
          required_doc_categories: ('insurance' | 'contract' | 'certification' | 'safety' | 'license' | 'w9' | 'other')[] | null
          required_doc_types: string[] | null
          min_coverage: Json
          required_certifications: string[] | null
          validity_days: number | null
          is_active: boolean
          severity: string
          created_by: string | null
          created_at: string
          updated_at: string
        }
      }
      compliance_status: {
        Row: {
          id: string
          org_id: string
          vendor_id: string
          site_id: string | null
          status: 'compliant' | 'non_compliant' | 'pending' | 'partial'
          issues: Json
          last_checked: string
          created_at: string
          updated_at: string
        }
      }
    }
  }
  metrics: {
    Tables: {
      daily_site_stats: {
        Row: {
          id: string
          org_id: string
          site_id: string
          date: string
          work_orders_open: number
          work_orders_closed: number
          work_orders_overdue: number
          sla_breaches: number
          visitor_count: number
          service_requests_count: number
          occupancy_rate: number | null
          compliance_rate: number | null
          avg_response_time_hours: number | null
          labor_hours: number
          pm_work_orders: number
          corrective_work_orders: number
          incidents_open: number
          incidents_closed: number
          inspections_completed: number
          inspections_failed: number
          total_assets: number
          healthy_assets: number
          reservation_count: number
          created_at: string
        }
      }
      portfolio_daily_stats: {
        Row: {
          id: string
          org_id: string
          portfolio_id: string
          date: string
          total_sites: number
          total_sq_ft: number
          occupancy_rate: number | null
          work_orders_open: number
          work_orders_closed: number
          work_orders_overdue: number
          sla_breaches: number
          visitor_count: number
          service_requests_count: number
          compliance_rate: number | null
          occupancy_weighted: number | null
          avg_response_time_hours: number | null
          labor_hours: number
          incidents_open: number
          total_assets: number
          healthy_assets: number
          created_at: string
        }
      }
      kpi_definitions: {
        Row: {
          id: string
          org_id: string
          name: string
          key: string
          description: string | null
          category: 'operational' | 'maintenance' | 'compliance' | 'occupancy' | 'vendor' | 'financial' | 'tenant' | 'visitor' | 'safety'
          unit: 'percent' | 'count' | 'hours' | 'currency' | 'ratio' | 'days'
          target_value: number | null
          higher_is_better: boolean
          formula: string | null
          is_active: boolean
          created_at: string
        }
      }
      reports: {
        Row: {
          id: string
          org_id: string
          portfolio_id: string | null
          site_id: string | null
          name: string
          description: string | null
          type: 'daily_ops' | 'weekly_exec' | 'monthly_portfolio' | 'compliance' | 'occupancy' | 'maintenance' | 'financial' | 'custom'
          format: 'json' | 'csv' | 'pdf'
          schedule_cron: string
          recipients: string[]
          recipient_user_ids: string[] | null
          filters: Json
          status: 'active' | 'paused' | 'archived'
          last_run_at: string | null
          next_run_at: string | null
          created_by: string | null
          created_at: string
          updated_at: string
        }
      }
      report_runs: {
        Row: {
          id: string
          report_id: string
          org_id: string
          status: 'pending' | 'running' | 'completed' | 'failed'
          file_path: string | null
          file_size: number | null
          row_count: number | null
          error_message: string | null
          started_at: string
          completed_at: string | null
          created_at: string
        }
      }
    }
    Views: {
      v_building_benchmark: {
        Row: {
          org_id: string
          portfolio_id: string
          portfolio_name: string
          site_id: string
          site_name: string
          city: string | null
          site_type: string | null
          sq_ft: number | null
          date: string
          occupancy_rate: number | null
          work_orders_open: number | null
          work_orders_closed: number | null
          sla_breaches: number | null
          compliance_rate: number | null
          visitor_count: number | null
          avg_response_time_hours: number | null
          labor_hours: number | null
          portfolio_avg_occupancy: number | null
          portfolio_avg_compliance: number | null
          portfolio_avg_open_wos: number | null
          occupancy_rank: number | null
          compliance_rank: number | null
        }
      }
      v_asset_health_rollup: {
        Row: {
          org_id: string
          site_id: string
          site_name: string
          total_assets: number
          active_assets: number
          maintenance_assets: number
          overdue_maintenance: number
          warranty_expired: number
          unhealthy_assets: number
          health_score: number | null
          open_wos_for_assets: number
        }
      }
      v_sla_metrics: {
        Row: {
          org_id: string
          site_id: string
          site_name: string
          date: string
          total_wos: number
          breached: number
          overdue: number
          avg_hours_to_complete: number | null
          avg_sla_hours: number | null
          urgent_count: number
          high_count: number
        }
      }
    }
  }
}
