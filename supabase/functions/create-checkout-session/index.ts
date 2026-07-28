// create-checkout-session - Creates a Stripe Checkout Session for a billing request
// POST { billing_request_id, success_url, cancel_url }
// Validates the billing request via the caller's JWT (RLS-scoped read), calls Stripe, writes
// tenant.checkout_sessions via service role, returns { session_id, checkout_url }.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405 })
  }

  try {
    const { billing_request_id, success_url, cancel_url } = await req.json()
    if (!billing_request_id) return new Response(JSON.stringify({ error: 'billing_request_id required' }), { status: 400 })

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    const authHeader = req.headers.get('Authorization')

    if (!stripeKey) {
      return new Response(JSON.stringify({ error: 'Stripe is not configured (STRIPE_SECRET_KEY missing)' }), { status: 503 })
    }

    // RLS-scoped read: only proceeds if the caller can actually see this billing request
    // (staff at the site, or a contact of the tenant it belongs to - see 00023's RLS policies).
    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader ?? '' } }
    })

    const { data: billingRequest, error: readError } = await userClient
      .schema('tenant').from('billing_requests')
      .select('id, title, total_amount_cents, payer_email, status')
      .eq('id', billing_request_id)
      .single()

    if (readError || !billingRequest) {
      return new Response(JSON.stringify({ error: 'Billing request not found or access denied' }), { status: 404 })
    }
    if (!billingRequest.payer_email) {
      return new Response(JSON.stringify({ error: 'Billing request has no payer_email' }), { status: 422 })
    }
    if (billingRequest.total_amount_cents <= 0) {
      return new Response(JSON.stringify({ error: 'Billing request has no payable amount' }), { status: 422 })
    }

    const stripeParams = new URLSearchParams({
      'mode': 'payment',
      'client_reference_id': billing_request_id,
      'customer_email': billingRequest.payer_email,
      'success_url': success_url ?? 'https://app.plutuspm.com/tenant/billing/success',
      'cancel_url': cancel_url ?? 'https://app.plutuspm.com/tenant/billing',
      'line_items[0][price_data][currency]': 'usd',
      'line_items[0][price_data][product_data][name]': billingRequest.title,
      'line_items[0][price_data][unit_amount]': String(billingRequest.total_amount_cents),
      'line_items[0][quantity]': '1',
      // Carries through to the resulting PaymentIntent so the webhook can correlate
      // payment_intent.succeeded/payment_intent.payment_failed back to this billing request.
      'payment_intent_data[metadata][billing_request_id]': billing_request_id
    })

    const stripeRes = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded'
      },
      body: stripeParams
    })

    const session = await stripeRes.json()
    if (!stripeRes.ok) {
      return new Response(JSON.stringify({ error: session.error?.message ?? 'Stripe checkout session creation failed' }), { status: 502 })
    }

    const supabase = createClient(supabaseUrl, serviceRole)

    await supabase.schema('tenant').from('checkout_sessions').insert({
      billing_request_id,
      stripe_session_id: session.id,
      status: 'ready',
      url: session.url,
      expires_at: session.expires_at ? new Date(session.expires_at * 1000).toISOString() : null
    })

    await supabase.schema('tenant').from('billing_requests')
      .update({ stripe_checkout_url: session.url })
      .eq('id', billing_request_id)

    return new Response(JSON.stringify({
      session_id: session.id,
      checkout_url: session.url
    }), { headers: { 'Content-Type': 'application/json' } })

  } catch (e: any) {
    console.error(e)
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
