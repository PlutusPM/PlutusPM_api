// Uploads a vendor photo only after the vendor-scoped authorization RPC approves the work order.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

const BUCKET = 'work-order-attachments'
const MAX_FILE_SIZE = 20 * 1024 * 1024
const ALLOWED_MIME_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
const HEIC_BRANDS = new Set(['heic', 'heix', 'hevc', 'hevx'])
const HEIF_BRANDS = new Set(['heif', 'mif1', 'mif2', 'msf1', 'msf2'])

function ascii(bytes: Uint8Array, offset: number, length: number) {
  return String.fromCharCode(...bytes.slice(offset, offset + length))
}

function detectImageMime(bytes: Uint8Array) {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg'
  if (bytes.length >= 8 && ascii(bytes, 0, 8) === '\x89PNG\r\n\x1a\n') return 'image/png'
  if (bytes.length >= 12 && ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 4) === 'WEBP') return 'image/webp'
  if (bytes.length >= 12 && ascii(bytes, 4, 4) === 'ftyp') {
    const brands = [ascii(bytes, 8, 4)]
    for (let offset = 16; offset + 4 <= bytes.length; offset += 4) brands.push(ascii(bytes, offset, 4))
    if (brands.some((brand) => HEIC_BRANDS.has(brand))) return 'image/heic'
    if (brands.some((brand) => HEIF_BRANDS.has(brand))) return 'image/heif'
  }
  return null
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405)

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json({ error: 'Authorization required' }, 401)

    const form = await req.formData()
    const workOrderId = String(form.get('work_order_id') ?? '').trim()
    const file = form.get('file')
    if (!workOrderId || !(file instanceof File)) return json({ error: 'work_order_id and file are required' }, 400)
    const mimeType = file.type.trim().toLowerCase()
    if (!ALLOWED_MIME_TYPES.has(mimeType)) return json({ error: 'Only supported image attachments are allowed' }, 400)
    if (file.size < 1 || file.size > MAX_FILE_SIZE) return json({ error: 'Attachment exceeds the size limit' }, 400)
    const detectedMimeType = detectImageMime(new Uint8Array(await file.slice(0, 32).arrayBuffer()))
    if (detectedMimeType !== mimeType) return json({ error: 'Attachment contents do not match the file type' }, 400)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } })
    const attachmentId = crypto.randomUUID()
    const { data: authorization, error: authorizationError } = await userClient
      .schema('vendor')
      .rpc('authorize_vendor_work_order_attachment', { p_work_order_id: workOrderId, p_attachment_id: attachmentId })
    if (authorizationError || !authorization?.org_id || !authorization?.site_id) return json({ error: 'Work order is not available' }, 404)

    const safeFileName = file.name.trim().replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 120) || 'photo'
    const storagePath = `${authorization.org_id}/${authorization.site_id}/work_orders/${workOrderId}/${attachmentId}-${safeFileName}`
    const adminClient = createClient(supabaseUrl, serviceRole)
    const { error: uploadError } = await adminClient.storage.from(BUCKET).upload(storagePath, await file.arrayBuffer(), {
      contentType: mimeType,
      upsert: false
    })
    if (uploadError) return json({ error: 'Attachment upload failed' }, 500)

    const { data: attachment, error: registrationError } = await userClient
      .schema('vendor')
      .rpc('register_vendor_work_order_attachment', {
        p_attachment_id: attachmentId,
        p_storage_path: storagePath,
        p_file_name: safeFileName,
        p_file_size: file.size,
        p_mime_type: mimeType
      })
    if (registrationError) {
      await adminClient.storage.from(BUCKET).remove([storagePath])
      return json({ error: 'Attachment registration failed' }, 400)
    }

    return json({ attachment })
  } catch (error) {
    console.error('vendor attachment upload failed', error instanceof Error ? error.message : 'unknown error')
    return json({ error: 'Attachment upload failed' }, 500)
  }
})

