// compliance-report - Generates compliance dashboard report per site/org, optional CSV/PDF

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST { org_id?, site_id?, format: json|csv }' }), { status: 405 })
  }

  try {
    const { org_id, site_id, format = 'json' } = await req.json()

    if (!org_id && !site_id) {
      return new Response(JSON.stringify({ error: 'org_id or site_id required' }), { status: 400 })
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, serviceRole)

    let vendors: any[] = []
    let complianceData: any[] = []

    if (site_id) {
      // Site-specific report
      const { data: site } = await supabase.schema('portfolio').from('sites').select('id, name, org_id').eq('id', site_id).single()
      if (!site) return new Response(JSON.stringify({ error: 'Site not found' }), { status: 404 })

      // Get compliance dashboard view for this site
      const { data, error } = await supabase.schema('vendor').from('v_compliance_dashboard').select('*').eq('site_id', site_id)
      if (error) throw error
      complianceData = data || []

      // Evaluate fresh compliance for this site
      await supabase.schema('vendor').rpc('evaluate_all_compliance', { p_org_id: site.org_id }).catch(() => {})

    } else if (org_id) {
      const { data, error } = await supabase.schema('vendor').from('v_vendor_summary').select('*').eq('org_id', org_id)
      if (error) throw error
      vendors = data || []

      const { data: dashData } = await supabase.schema('vendor').from('v_compliance_dashboard').select('*').eq('org_id', org_id).limit(200)
      complianceData = dashData || []
    }

    const summary = {
      total_vendors: complianceData.length > 0 ? new Set(complianceData.map((d: any) => d.vendor_id)).size : vendors.length,
      compliant: complianceData.filter((d: any) => d.compliance_status === 'compliant').length,
      non_compliant: complianceData.filter((d: any) => d.compliance_status === 'non_compliant').length,
      pending: complianceData.filter((d: any) => d.compliance_status === 'pending').length,
      expiring_cois: complianceData.reduce((sum: number, d: any) => sum + (d.expiring_cois || 0), 0),
      expired_cois: complianceData.reduce((sum: number, d: any) => sum + (d.expired_cois || 0), 0),
      active_contracts: complianceData.reduce((sum: number, d: any) => sum + (d.active_contracts || 0), 0)
    }

    const report = {
      generated_at: new Date().toISOString(),
      org_id,
      site_id,
      summary,
      complianceData: complianceData.slice(0, 100), // limit for response size
      vendors: vendors.slice(0, 100)
    }

    if (format === 'csv') {
      // Simple CSV for compliance
      const headers = ['vendor_name','vendor_type','site_name','compliance_status','active_contracts','valid_cois','expiring_cois','expired_cois','next_expiry_date']
      const rows = complianceData.map((d: any) => [
        `"${(d.vendor_name||'').replace(/"/g,'""')}"`,
        d.vendor_type,
        `"${(d.site_name||'').replace(/"/g,'""')}"`,
        d.compliance_status,
        d.active_contracts,
        d.valid_cois,
        d.expiring_cois,
        d.expired_cois,
        d.next_expiry_date || ''
      ].join(','))

      const csv = [headers.join(','), ...rows].join('\n')

      // Upload to storage
      const orgForPath = org_id || complianceData[0]?.org_id || 'unknown'
      const path = `${orgForPath}/reports/compliance-${site_id || org_id}-${new Date().toISOString().split('T')[0]}.csv`

      // Try upload to site-files bucket (use org from first record)
      try {
        await supabase.storage.from('site-files').upload(path, csv, { contentType: 'text/csv', upsert: true })
        const { data: urlData } = await supabase.storage.from('site-files').createSignedUrl(path, 3600*24*7)
        return new Response(JSON.stringify({ ok: true, summary, csv_url: urlData?.signedUrl, csv_preview: csv.substring(0,2000) }), { headers: { 'Content-Type': 'application/json' } })
      } catch {}

      return new Response(csv, { headers: { 'Content-Type': 'text/csv', 'Content-Disposition': `attachment; filename=compliance-report.csv` } })
    }

    // Store JSON report to storage as well
    try {
      const orgForPath = org_id || complianceData[0]?.org_id || 'unknown'
      const siteForPath = site_id || 'org'
      const jsonPath = `${orgForPath}/${siteForPath}/reports/compliance-report-${new Date().toISOString().split('T')[0]}.json`
      await supabase.storage.from('site-files').upload(jsonPath, JSON.stringify(report, null, 2), { contentType: 'application/json', upsert: true })
    } catch {}

    return new Response(JSON.stringify(report, null, 2), { headers: { 'Content-Type': 'application/json' } })

  } catch (e: any) {
    console.error(e)
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
})
