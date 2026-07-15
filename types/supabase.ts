// types/supabase.ts - Main export for Supabase client
// Usage:
// import { createClient } from '@supabase/supabase-js'
// import type { Database } from './types/database'
// const supabase = createClient<Database>(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!)

export * from './database'

// Helper types
import type { Database } from './database'

export type Tables<T extends keyof Database[keyof Database]['Tables']> = Database[keyof Database]['Tables'][T] extends { Row: infer R } ? R : never

// Specific table helpers
export type Organization = Database['platform']['Tables']['organizations']['Row']
export type Profile = Database['platform']['Tables']['profiles']['Row']
export type Membership = Database['platform']['Tables']['memberships']['Row']
export type Site = Database['portfolio']['Tables']['sites']['Row']
export type Portfolio = Database['portfolio']['Tables']['portfolios']['Row']
export type Building = Database['portfolio']['Tables']['buildings']['Row']
export type Floor = Database['portfolio']['Tables']['floors']['Row']
export type Space = Database['portfolio']['Tables']['spaces']['Row']
export type Asset = Database['ops']['Tables']['assets']['Row']
export type WorkOrder = Database['ops']['Tables']['work_orders']['Row']
export type Checklist = Database['ops']['Tables']['checklists']['Row']
export type Inspection = Database['ops']['Tables']['inspections']['Row']
export type Tenant = Database['tenant']['Tables']['tenants']['Row']
export type Announcement = Database['tenant']['Tables']['announcements']['Row']
export type Reservation = Database['tenant']['Tables']['reservations']['Row']
export type Visitor = Database['visitor']['Tables']['visitors']['Row']
export type Visit = Database['visitor']['Tables']['visits']['Row']
export type Vendor = Database['vendor']['Tables']['vendors']['Row']
export type COI = Database['vendor']['Tables']['cois']['Row']
export type ComplianceStatus = Database['vendor']['Tables']['compliance_status']['Row']
export type DailySiteStats = Database['metrics']['Tables']['daily_site_stats']['Row']

// Enums
export type OrgRole = Database['platform']['Tables']['memberships']['Row']['role']
export type SiteType = Database['portfolio']['Tables']['sites']['Row']['type']
export type WorkOrderStatus = Database['ops']['Tables']['work_orders']['Row']['status']
export type WorkOrderPriority = Database['ops']['Tables']['work_orders']['Row']['priority']
export type VisitStatus = Database['visitor']['Tables']['visits']['Row']['status']
export type VendorType = Database['vendor']['Tables']['vendors']['Row']['type']

// GraphQL helpers
export type GraphQLResponse<T> = {
  data?: T
  errors?: Array<{ message: string; path?: string[] }>
}

// Utility for site-scoped queries
export type SiteScoped = {
  site_id: string
  org_id: string
}

// For frontend: User with memberships
export type UserWithMemberships = {
  id: string
  email: string
  profile: Profile | null
  memberships: (Membership & { organization: Organization })[]
  currentOrgId?: string
  currentSiteIds?: string[]
}
