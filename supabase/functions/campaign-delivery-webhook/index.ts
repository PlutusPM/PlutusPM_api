// campaign-delivery-webhook - Receives Resend delivery-status webhook events and updates
// tenant.campaign_deliveries. Correlates to a campaign via the `campaign_id` tag set on send
// in send-campaign/index.ts.
//
// NOTE: this does not verify the Resend webhook signature (svix-id/svix-timestamp/svix-signature
// headers + RESEND_WEBHOOK_SECRET via the svix library) - unlike stripe-webhook, which is
// security/payment-critical, an unverified event here only affects delivery-status display, not
// money or access control. Add svix verification before relying on this for anything sensitive.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

const STATUS_BY_EVENT: Record<string, string> = {
  'email.sent': 'sent',
  'email.delivered': 'delivered',
  'email.opened': 'opened',
  'email.clicked': 'clicked',
  'email.bounced': 'bounced',
  'email.delivery_delayed': 'pending',
  'email.complained': 'bounced'
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405 })
  }

  try {
    const event = await req.json()
    const status = STATUS_BY_EVENT[event.type]
    if (!status) {
      return new Response(JSON.stringify({ ok: true, ignored: event.type }), { headers: { 'Content-Type': 'application/json' } })
    }

    const recipientEmail: string | undefined = event.data?.to?.[0]
    const campaignId: string | undefined = event.data?.tags?.find((t: any) => t.name === 'campaign_id')?.value

    if (!recipientEmail || !campaignId) {
      return new Response(JSON.stringify({ ok: true, skipped: 'missing recipient or campaign_id tag' }), { headers: { 'Content-Type': 'application/json' } })
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, serviceRole)

    const timestampField =
      status === 'delivered' ? 'delivered_at'
      : status === 'opened' ? 'opened_at'
      : status === 'clicked' ? 'clicked_at'
      : status === 'bounced' ? 'bounced_at'
      : null

    const update: Record<string, unknown> = { status }
    if (timestampField) update[timestampField] = new Date().toISOString()

    await supabase.schema('tenant').from('campaign_deliveries')
      .update(update)
      .eq('campaign_id', campaignId)
      .eq('recipient_email', recipientEmail);

    await supabase.schema('tenant').from('campaign_recipients')
      .update({ status })
      .eq('campaign_id', campaignId)
      .eq('recipient_email', recipientEmail);

    return new Response(JSON.stringify({ ok: true }), { headers: { 'Content-Type': 'application/json' } })

  } catch (e: any) {
    console.error(e)
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
