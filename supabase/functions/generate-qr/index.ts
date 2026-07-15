// generate-qr - Generates QR code for assets
// POST { asset_id: uuid, site_id: uuid } -> returns SVG/PNG data URL + uploads to storage

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405 })
  }

  try {
    const { asset_id, site_id, org_id, format = 'svg' } = await req.json()

    if (!asset_id) {
      return new Response(JSON.stringify({ error: 'asset_id required' }), { status: 400 })
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, serviceRole)

    // Fetch asset
    const { data: asset, error } = await supabase.schema('ops').from('assets').select('id, org_id, site_id, qr_code, name').eq('id', asset_id).single()
    if (error || !asset) {
      return new Response(JSON.stringify({ error: 'Asset not found' }), { status: 404 })
    }

    const qrValue = asset.qr_code
    // Simple QR generation - using api.qrserver.com for MVP (no dependency)
    // In production, use npm:qrcode library
    const qrApiUrl = `https://api.qrserver.com/v1/create-qr-code/?size=500x500&data=${encodeURIComponent(qrValue)}&format=${format === 'png' ? 'png' : 'svg'}`

    const qrRes = await fetch(qrApiUrl)
    const qrBuffer = await qrRes.arrayBuffer()

    // Upload to storage: site-files/org_id/site_id/assets/asset_id/qr.svg
    const storagePath = `${asset.org_id}/${asset.site_id}/assets/${asset.id}/qr-${qrValue}.${format === 'png' ? 'png' : 'svg'}`
    const { data: uploadData, error: uploadError } = await supabase.storage.from('site-files').upload(storagePath, qrBuffer, {
      contentType: format === 'png' ? 'image/png' : 'image/svg+xml',
      upsert: true
    })

    if (uploadError) {
      console.error('Upload error', uploadError)
      // Still return QR
    }

    const { data: signedUrlData } = await supabase.storage.from('site-files').createSignedUrl(storagePath, 3600 * 24 * 7) // 7 days

    return new Response(JSON.stringify({
      ok: true,
      asset_id: asset.id,
      qr_code: qrValue,
      qr_text: qrValue,
      storage_path: storagePath,
      signed_url: signedUrlData?.signedUrl,
      qr_api_url: qrApiUrl
    }), { headers: { 'Content-Type': 'application/json' } })

  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500 })
  }
})
