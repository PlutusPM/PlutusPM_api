// Manager-only vendor portal invitation.
// The function deliberately uses a generic failure response for account lookups;
// managers only receive the stable invited status on success.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

const jsonHeaders = { 'Content-Type': 'application/json' }

function response(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders })
}

function normalizeEmail(value: unknown) {
  const email = String(value ?? '').trim().toLowerCase()
  return /^\S+@\S+\.\S+$/.test(email) ? email : null
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return response({ error: 'POST only' }, 405)

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return response({ error: 'Authorization required' }, 401)

    const { vendor_id, email: requestedEmail } = await req.json()
    const email = normalizeEmail(requestedEmail)
    if (!vendor_id || !email) return response({ error: 'vendor_id and a valid email are required' }, 400)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const webOrigin = (Deno.env.get('WEB_ORIGIN') || Deno.env.get('PUBLIC_WEB_ORIGIN') || '').replace(/\/$/, '')
    if (!webOrigin) return response({ error: 'Invitation service is not configured' }, 503)

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } }
    })
    const { data: callerData, error: callerError } = await callerClient.auth.getUser()
    if (callerError || !callerData.user) return response({ error: 'Authorization required' }, 401)

    const { data: memberships, error: membershipsError } = await callerClient
      .schema('platform')
      .from('memberships')
      .select('org_id,role')
      .eq('user_id', callerData.user.id)
    if (membershipsError) return response({ error: 'Unable to verify manager access' }, 403)

    const managerOrgIds = new Set(
      (memberships ?? [])
        .filter((membership) => !['vendor', 'tenant_admin', 'tenant_user'].includes(membership.role))
        .map((membership) => membership.org_id)
    )

    const { data: vendorRow, error: vendorError } = await callerClient
      .schema('vendor')
      .from('vendors')
      .select('id,org_id,status')
      .eq('id', vendor_id)
      .maybeSingle()
    if (vendorError || !vendorRow || !managerOrgIds.has(vendorRow.org_id)) {
      return response({ error: 'Vendor invitation is not available' }, 403)
    }
    if (vendorRow.status === 'blocked' || vendorRow.status === 'inactive') {
      return response({ error: 'Vendor invitation is not available' }, 400)
    }

    const adminClient = createClient(supabaseUrl, serviceRole)
    const { data: existingProfile, error: profileError } = await adminClient
      .schema('platform')
      .from('profiles')
      .select('id,email')
      .ilike('email', email)
      .maybeSingle()
    if (profileError) throw profileError

    let userId = existingProfile?.id ?? null
    const redirectTo = `${webOrigin}/vendor/accept-invite`

    if (userId) {
      const recoveryResponse = await fetch(`${supabaseUrl}/auth/v1/recover`, {
        method: 'POST',
        headers: {
          apikey: serviceRole,
          Authorization: `Bearer ${serviceRole}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ email, redirect_to: redirectTo })
      })
      if (!recoveryResponse.ok) throw new Error('Recovery email could not be requested')
    } else {
      const inviteResponse = await fetch(`${supabaseUrl}/auth/v1/invite`, {
        method: 'POST',
        headers: {
          apikey: serviceRole,
          Authorization: `Bearer ${serviceRole}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ email, redirect_to: redirectTo })
      })
      const invitePayload = await inviteResponse.json().catch(() => null)
      if (inviteResponse.ok) {
        userId = invitePayload?.user?.id ?? null
      } else {
        // A concurrent invite may have created the profile between the first lookup
        // and GoTrue's response. Treat that case as an existing account and send recovery.
        const { data: racedProfile } = await adminClient
          .schema('platform')
          .from('profiles')
          .select('id')
          .ilike('email', email)
          .maybeSingle()
        if (!racedProfile?.id) throw new Error('Invitation could not be requested')
        userId = racedProfile.id
        const recoveryResponse = await fetch(`${supabaseUrl}/auth/v1/recover`, {
          method: 'POST',
          headers: {
            apikey: serviceRole,
            Authorization: `Bearer ${serviceRole}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({ email, redirect_to: redirectTo })
        })
        if (!recoveryResponse.ok) throw new Error('Recovery email could not be requested')
      }
    }

    // The profile trigger normally runs before GoTrue returns. If it is still
    // propagating, leave the link pending and let activation create the membership
    // after the invitee establishes the session.
    if (userId) {
      const { data: linkedProfile } = await adminClient
        .schema('platform')
        .from('profiles')
        .select('id')
        .eq('id', userId)
        .maybeSingle()
      if (!linkedProfile?.id) userId = null
    }

    if (userId) {
      const { data: conflictingMembership } = await adminClient
        .schema('platform')
        .from('memberships')
        .select('id,role')
        .eq('org_id', vendorRow.org_id)
        .eq('user_id', userId)
        .maybeSingle()
      if (conflictingMembership && conflictingMembership.role !== 'vendor') {
        return response({ error: 'That account cannot be invited to the vendor portal' }, 409)
      }

      const { error: membershipError } = await adminClient
        .schema('platform')
        .from('memberships')
        .upsert({ org_id: vendorRow.org_id, user_id: userId, role: 'vendor', created_by: callerData.user.id }, { onConflict: 'org_id,user_id' })
      if (membershipError) throw membershipError
    }

    const { data: existingVendorUser, error: vendorUserLookupError } = await adminClient
      .schema('vendor')
      .from('vendor_users')
      .select('id')
      .eq('vendor_id', vendorRow.id)
      .ilike('email', email)
      .maybeSingle()
    if (vendorUserLookupError) throw vendorUserLookupError

    const vendorUserPayload = {
      org_id: vendorRow.org_id,
      vendor_id: vendorRow.id,
      user_id: userId,
      email,
      status: 'invited',
      invited_at: new Date().toISOString(),
      created_by: callerData.user.id
    }
    const vendorUserQuery = existingVendorUser
      ? adminClient.schema('vendor').from('vendor_users').update(vendorUserPayload).eq('id', existingVendorUser.id)
      : adminClient.schema('vendor').from('vendor_users').insert(vendorUserPayload)
    const { error: vendorUserError } = await vendorUserQuery
    if (vendorUserError) throw vendorUserError

    return response({ status: 'invited' })
  } catch (error) {
    console.error('vendor invitation failed', error instanceof Error ? error.message : 'unknown error')
    return response({ error: 'Vendor invitation could not be completed' }, 500)
  }
})

