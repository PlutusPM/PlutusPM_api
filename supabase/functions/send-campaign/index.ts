// send-campaign - Resolves campaign recipients and sends via Resend
// POST { campaign_id: uuid } - calls tenant.send_campaign() for DB-side recipient resolution,
// then emails each recipient and writes tenant.campaign_deliveries rows.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405 })
  }

  try {
    const { campaign_id } = await req.json()
    if (!campaign_id) return new Response(JSON.stringify({ error: 'campaign_id required' }), { status: 400 })

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const resendKey = Deno.env.get('RESEND_API_KEY')
    const authHeader = req.headers.get('Authorization')

    // RLS-scoped client (caller's JWT) to run the access-checked RPC
    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader ?? '' } }
    })

    const { data: result, error: rpcError } = await userClient
      .schema('tenant')
      .rpc('send_campaign', { p_campaign_id: campaign_id })

    if (rpcError) return new Response(JSON.stringify({ error: rpcError.message }), { status: 400 })

    // Service-role client for the actual send + delivery bookkeeping
    const supabase = createClient(supabaseUrl, serviceRole)

    const { data: campaign } = await supabase.schema('tenant').from('communication_campaigns')
      .select('id, subject, body').eq('id', campaign_id).single()

    const { data: recipients } = await supabase.schema('tenant').from('campaign_recipients')
      .select('id, recipient_email, recipient_name').eq('campaign_id', campaign_id)

    let sentCount = 0
    if (resendKey && campaign && recipients) {
      for (const recipient of recipients) {
        try {
          const resendRes = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${resendKey}`,
              'Content-Type': 'application/json'
            },
            body: JSON.stringify({
              from: 'PlutusPM <notifications@your-domain.com>',
              to: [recipient.recipient_email],
              subject: campaign.subject,
              html: campaign.body,
              // Tag echoed back on delivery-status webhooks so campaign-delivery-webhook can
              // correlate the event to this campaign without parsing email content.
              tags: [{ name: 'campaign_id', value: campaign_id }]
            })
          })

          const ok = resendRes.ok
          await supabase.schema('tenant').from('campaign_recipients')
            .update({ status: ok ? 'sent' : 'failed' })
            .eq('id', recipient.id)

          await supabase.schema('tenant').from('campaign_deliveries').insert({
            campaign_id,
            recipient_email: recipient.recipient_email,
            status: ok ? 'sent' : 'failed',
            delivered_at: ok ? new Date().toISOString() : null
          })

          if (ok) sentCount++
        } catch (sendError) {
          console.error(`Failed to send to ${recipient.recipient_email}:`, sendError)
          await supabase.schema('tenant').from('campaign_recipients')
            .update({ status: 'failed' }).eq('id', recipient.id)
        }
      }
    }

    return new Response(JSON.stringify({
      ok: true,
      campaign_id,
      recipient_count: result?.recipient_count ?? 0,
      sent_count: sentCount,
      email_provider_configured: !!resendKey
    }), { headers: { 'Content-Type': 'application/json' } })

  } catch (e: any) {
    console.error(e)
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
