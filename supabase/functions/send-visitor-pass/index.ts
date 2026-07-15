// send-visitor-pass - Sends QR pass email to visitor
// POST { visit_id: uuid } - fetches visit + visitor, generates QR, emails via Resend

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405 })
  }

  try {
    const { visit_id } = await req.json()
    if (!visit_id) return new Response(JSON.stringify({ error: 'visit_id required' }), { status: 400 })

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const resendKey = Deno.env.get('RESEND_API_KEY')
    const supabase = createClient(supabaseUrl, serviceRole)

    // Fetch visit with visitor + site
    const { data: visit, error } = await supabase.schema('visitor').from('visits')
      .select(`
        id, org_id, site_id, qr_code, scheduled_at, purpose,
        visitors (id, full_name, email, company),
        sites:sites!inner(id, name, address_line1, city, state),
        host:host_user_id(full_name, email)
      `)
      .eq('id', visit_id)
      .single() as any

    // Try alternative query if join fails (different schemas)
    let visitData: any = visit
    if (error || !visit) {
      // Fallback: fetch separately
      const { data: v } = await supabase.schema('visitor').from('visits').select('*').eq('id', visit_id).single()
      if (!v) return new Response(JSON.stringify({ error: 'Visit not found' }), { status: 404 })
      const { data: visitor } = await supabase.schema('visitor').from('visitors').select('*').eq('id', v.visitor_id).single()
      const { data: site } = await supabase.schema('portfolio').from('sites').select('*').eq('id', v.site_id).single()
      visitData = { ...v, visitors: visitor, sites: site }
    }

    if (!visitData) return new Response(JSON.stringify({ error: 'Visit not found' }), { status: 404 })

    const visitorEmail = visitData.visitors?.email
    const visitorName = visitData.visitors?.full_name || 'Guest'
    const siteName = visitData.sites?.name || visitData.site_id
    const qrCode = visitData.qr_code
    const scheduledAt = new Date(visitData.scheduled_at).toLocaleString()

    // QR image URL
    const qrImageUrl = `https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=${encodeURIComponent(qrCode)}`

    // Send email via Resend if configured
    let emailResult: any = null
    if (resendKey && visitorEmail) {
      const emailPayload = {
        from: 'Visitor Management <visitors@your-domain.com>',
        to: [visitorEmail],
        subject: `Visitor Pass - ${siteName} - ${scheduledAt}`,
        html: `
          <div style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
            <h2 style="color: #0f172a;">Your Visitor Pass</h2>
            <p>Hello ${visitorName},</p>
            <p>You have been registered to visit <strong>${siteName}</strong></p>
            <p><strong>Date:</strong> ${scheduledAt}<br/>
            <strong>Purpose:</strong> ${visitData.purpose || 'General visit'}</p>
            <div style="text-align: center; margin: 30px 0; padding: 20px; background: #f8fafc; border-radius: 12px;">
              <img src="${qrImageUrl}" alt="QR Code" style="width: 300px; height: 300px;"/>
              <p style="font-family: monospace; font-size: 12px; color: #475569; margin-top: 10px;">${qrCode}</p>
            </div>
            <p>Please show this QR code at the lobby kiosk or to security upon arrival.</p>
            <p style="color: #64748b; font-size: 12px;">Address: ${visitData.sites?.address_line1 || ''} ${visitData.sites?.city || ''}<br/>This pass is valid for 24 hours from scheduled time.</p>
          </div>
        `
      }

      const resendRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${resendKey}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(emailPayload)
      })
      emailResult = await resendRes.json()
    }

    // Also create notification for host
    if (visitData.host_user_id) {
      await supabase.schema('platform').from('notifications').insert({
        org_id: visitData.org_id,
        site_id: visitData.site_id,
        user_id: visitData.host_user_id,
        type: 'visitor_arrived',
        title: `Visitor preregistered: ${visitorName}`,
        body: `${visitorName} scheduled to visit on ${scheduledAt}`,
        payload: { visit_id: visitData.id, visitor_name: visitorName, qr_code: qrCode }
      })
    }

    return new Response(JSON.stringify({
      ok: true,
      visit_id: visitData.id,
      visitor: { name: visitorName, email: visitorEmail },
      qr_code: qrCode,
      qr_image_url: qrImageUrl,
      email_sent: !!emailResult,
      email_result: emailResult
    }), { headers: { 'Content-Type': 'application/json' } })

  } catch (e: any) {
    console.error(e)
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
