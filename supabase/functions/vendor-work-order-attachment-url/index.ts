// Returns a short-lived signed URL after the vendor-scoped attachment RPC approves access.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'POST only' }), { status: 405 })

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return new Response(JSON.stringify({ error: 'Authorization required' }), { status: 401 })
    const { attachment_id } = await req.json()
    if (!attachment_id) return new Response(JSON.stringify({ error: 'attachment_id required' }), { status: 400 })

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } })
    const { data: attachment, error: attachmentError } = await userClient
      .schema('vendor')
      .rpc('get_vendor_work_order_attachment', { p_attachment_id: attachment_id })
    if (attachmentError || !attachment?.storage_path) {
      return new Response(JSON.stringify({ error: 'Attachment is not available' }), { status: 404 })
    }

    const adminClient = createClient(supabaseUrl, serviceRole)
    const { data: signed, error: signedError } = await adminClient.storage
      .from('work-order-attachments')
      .createSignedUrl(attachment.storage_path, 300)
    if (signedError || !signed?.signedUrl) {
      return new Response(JSON.stringify({ error: 'Attachment URL could not be created' }), { status: 500 })
    }

    return new Response(JSON.stringify({ url: signed.signedUrl, expires_in: 300 }), {
      headers: { 'Content-Type': 'application/json' }
    })
  } catch (error) {
    console.error('vendor attachment URL failed', error instanceof Error ? error.message : 'unknown error')
    return new Response(JSON.stringify({ error: 'Attachment URL could not be created' }), { status: 500 })
  }
})

