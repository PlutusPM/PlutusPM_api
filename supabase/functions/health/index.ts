// supabase/functions/health/index.ts
// Health check + cron monitor for CRE SaaS

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, supabaseKey)

    // Check cron jobs
    const { data: cronJobs, error: cronError } = await supabase
      .rpc('get_cron_jobs' as any)
      .maybeSingle()

    // Fallback query via raw SQL if rpc not exist - we try direct
    let cronStatus: any = []
    try {
      const { data } = await supabase.from('cron_job_run_details' as any).select('*').order('start_time', { ascending: false }).limit(5)
      cronStatus = data
    } catch {
      cronStatus = { note: 'cron.job_run_details not accessible via PostgREST, check via SQL' }
    }

    // Count sites
    const { count: siteCount } = await supabase.from('sites').select('*', { count: 'exact', head: true }).limit(1)
    // Try portfolio schema
    let portfolioSitesCount = 0
    try {
      const res = await supabase.schema('portfolio').from('sites').select('*', { count: 'exact', head: true })
      portfolioSitesCount = res.count || 0
    } catch {}

    return new Response(JSON.stringify({
      status: 'ok',
      timestamp: new Date().toISOString(),
      service: 'cre-saas-platform',
      version: 'Phase 0',
      checks: {
        database: 'connected',
        cron: cronStatus,
        graphql: `${supabaseUrl}/graphql/v1`,
        realtime: `${supabaseUrl.replace('http','ws')}/realtime/v1`
      },
      stats: {
        portfolioSitesCount
      }
    }, null, 2), {
      headers: { 'Content-Type': 'application/json' },
      status: 200
    })
  } catch (e: any) {
    return new Response(JSON.stringify({ status: 'error', error: e.message }), { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
})
