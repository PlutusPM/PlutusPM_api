// stripe-webhook - Verifies and processes Stripe webhook events for billing.
// Signature verification and secret handling live here (Deno runtime), NOT in SQL - see
// platform.apply_stripe_webhook_event in 00024_billing_stripe_checkout.sql for why.
// Supported events (matches API_SPEC.md): payment_intent.succeeded, payment_intent.payment_failed,
// invoice.paid, invoice.payment_failed.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'
import Stripe from 'https://esm.sh/stripe@17.0.0?target=deno'

const SUPPORTED_EVENTS = new Set([
  'payment_intent.succeeded',
  'payment_intent.payment_failed',
  'invoice.paid',
  'invoice.payment_failed'
])

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405 })
  }

  const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')
  const signature = req.headers.get('Stripe-Signature')

  if (!stripeKey || !webhookSecret) {
    console.error('Stripe not configured: STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET missing')
    return new Response(JSON.stringify({ error: 'Stripe is not configured' }), { status: 503 })
  }
  if (!signature) {
    return new Response(JSON.stringify({ error: 'Missing Stripe-Signature header' }), { status: 400 })
  }

  // Signature verification MUST happen against the raw body - read as text, not JSON, before
  // any parsing, or the signature check will fail even for genuine events.
  const rawBody = await req.text()

  const stripe = new Stripe(stripeKey, {
    apiVersion: '2024-06-20',
    httpClient: Stripe.createFetchHttpClient()
  })
  const cryptoProvider = Stripe.createSubtleCryptoProvider()

  let event: Stripe.Event
  try {
    event = await stripe.webhooks.constructEventAsync(rawBody, signature, webhookSecret, undefined, cryptoProvider)
  } catch (verifyError: any) {
    console.error('Stripe signature verification failed:', verifyError.message)
    return new Response(JSON.stringify({ error: `Signature verification failed: ${verifyError.message}` }), { status: 400 })
  }

  if (!SUPPORTED_EVENTS.has(event.type)) {
    return new Response(JSON.stringify({ ok: true, ignored: event.type }), { headers: { 'Content-Type': 'application/json' } })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, serviceRole)

    // Only reachable with the service-role key (00024's REVOKE ... FROM PUBLIC), which this
    // function holds - not exposed to any user JWT.
    const { data: result, error } = await supabase
      .schema('platform')
      .rpc('apply_stripe_webhook_event', { p_event_type: event.type, p_payload: event as unknown as Record<string, unknown> })

    if (error) {
      console.error('apply_stripe_webhook_event failed:', error.message)
      return new Response(JSON.stringify({ error: error.message }), { status: 500 })
    }

    return new Response(JSON.stringify({ ok: true, result }), { headers: { 'Content-Type': 'application/json' } })

  } catch (e: any) {
    console.error(e)
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
