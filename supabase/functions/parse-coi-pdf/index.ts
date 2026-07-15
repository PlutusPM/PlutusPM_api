// parse-coi-pdf - OCR / extraction for COI documents
// POST { storage_path: "org_id/vendor_id/coi.pdf" } or multipart file upload
// Extracts expiry_date, policy_number, insurer, coverage, type, additional insured
// Uses regex heuristics - in production replace with AWS Textract / Google Vision or LLM

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

Deno.serve(async (req) => {
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const supabase = createClient(supabaseUrl, serviceRole)

    let fileBuffer: ArrayBuffer | null = null
    let fileName = 'coi.pdf'
    let storagePath: string | null = null
    let vendorId: string | null = null
    let orgId: string | null = null

    const contentType = req.headers.get('content-type') || ''

    if (contentType.includes('application/json')) {
      const body = await req.json()
      storagePath = body.storage_path
      vendorId = body.vendor_id || null
      orgId = body.org_id || null

      if (!storagePath) {
        return new Response(JSON.stringify({ error: 'storage_path required or upload file' }), { status: 400, headers: corsHeaders })
      }

      // Download file from storage
      // Try each bucket that might contain COI
      const buckets = ['coi-documents', 'site-files', 'contract-documents']
      for (const bucket of buckets) {
        const { data, error } = await supabase.storage.from(bucket).download(storagePath)
        if (!error && data) {
          fileBuffer = await data.arrayBuffer()
          fileName = storagePath.split('/').pop() || 'coi.pdf'
          break
        }
      }

      if (!fileBuffer) {
        // Try direct path as full URL? For demo, allow external URL fetch?
        return new Response(JSON.stringify({ error: `File not found at storage_path ${storagePath} in tried buckets` }), { status: 404, headers: corsHeaders })
      }
    } else if (contentType.includes('multipart/form-data')) {
      const form = await req.formData()
      const file = form.get('file') as File
      if (!file) return new Response(JSON.stringify({ error: 'file field required' }), { status: 400, headers: corsHeaders })
      fileBuffer = await file.arrayBuffer()
      fileName = file.name
      vendorId = form.get('vendor_id') as string
      orgId = form.get('org_id') as string
    } else {
      return new Response(JSON.stringify({ error: 'Send JSON with storage_path or multipart file' }), { status: 400, headers: corsHeaders })
    }

    // ---- Extraction heuristics ----
    // For MVP, we try to extract text from PDF if it's text-based, or use filename heuristics
    // In production, you'd call AWS Textract, Google Document AI, or an LLM via API

    // Try to decode buffer as text to find dates/coverage (works for some PDFs that have text)
    let textContent = ''
    try {
      const decoder = new TextDecoder('utf-8', { fatal: false })
      textContent = decoder.decode(fileBuffer.slice(0, Math.min(fileBuffer.byteLength, 50000)))
      // Clean
      textContent = textContent.replace(/[^\x20-\x7E\n\r]/g, ' ').substring(0, 20000)
    } catch {
      textContent = fileName + ' ' // fallback
    }

    // Regex patterns
    const datePatterns = [
      /(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})/g,
      /(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})/g,
      /(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{4}/gi
    ]

    const dates: string[] = []
    for (const pat of datePatterns) {
      const matches = textContent.match(pat)
      if (matches) dates.push(...matches)
    }

    // Try to guess expiry: latest date in future within 1 year? Heuristic: max date
    let expiryDate: string | null = null
    const now = new Date()
    const futureDates = dates.map(d => new Date(d)).filter(d => !isNaN(d.getTime()) && d > now).sort((a,b) => a.getTime() - b.getTime())
    if (futureDates.length > 0) {
      expiryDate = futureDates[0].toISOString().split('T')[0]
    } else {
      // If no future date found, guess filename contains date?
      const fileDateMatch = fileName.match(/(\d{4})[-_]?(\d{2})[-_]?(\d{2})/)
      if (fileDateMatch) expiryDate = `${fileDateMatch[1]}-${fileDateMatch[2]}-${fileDateMatch[3]}`
    }

    // Coverage amounts: look for $ and numbers
    const coverageMatches = textContent.match(/\$?\s?(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*(?:USD)?/g) || []
    const coverages = coverageMatches.map(s => parseFloat(s.replace(/[$,]/g, ''))).filter(n => n >= 1000 && n <= 10000000).sort((a,b) => b-a)
    const maxCoverage = coverages[0] || null

    // Policy number: look for "Policy" near alphanumeric
    const policyMatch = textContent.match(/Policy\s*(?:No|Number|#)?\s*[:\-]?\s*([A-Z0-9\-]+)/i)
    const policyNumber = policyMatch ? policyMatch[1] : null

    // Insurer: look for common insurer names or "Insurer" label
    const insurerMatch = textContent.match(/Insurer\s*[:\-]?\s*([A-Za-z\s&]+)/i) || textContent.match(/(Travelers|Hartford|Liberty|Chubb|AIG|Zurich|CNA|Progressive|State Farm)/i)
    const insurerName = insurerMatch ? insurerMatch[1].trim() : null

    // COI type guess from text and filename
    let coiType = 'general_liability'
    const lower = (fileName + ' ' + textContent).toLowerCase()
    if (lower.includes('workers') || lower.includes('comp') || lower.includes('wc')) coiType = 'workers_comp'
    else if (lower.includes('auto') || lower.includes('automobile')) coiType = 'auto'
    else if (lower.includes('umbrella') || lower.includes('excess')) coiType = 'umbrella'
    else if (lower.includes('professional') || lower.includes('e&o')) coiType = 'professional_liability'

    // Additional insured?
    const additionalInsured = /additional\s+insured/i.test(textContent)

    const extracted = {
      expiry_date: expiryDate,
      policy_number: policyNumber,
      insurer_name: insurerName,
      coverage_amount: maxCoverage,
      type: coiType,
      additional_insured: additionalInsured,
      certificate_holder: null,
      file_name: fileName,
      file_size: fileBuffer.byteLength,
      all_dates_found: dates.slice(0,10),
      coverages_found: coverages.slice(0,5),
      confidence: expiryDate ? (policyNumber ? 'medium' : 'low') : 'very_low',
      raw_text_snippet: textContent.substring(0,1000)
    }

    // If org_id and vendor_id provided, try to auto-create or update COI record with extracted data
    let createdCoi: any = null
    if (orgId && vendorId && expiryDate) {
      try {
        const { data, error } = await supabase.schema('vendor').from('cois').insert({
          org_id: orgId,
          vendor_id: vendorId,
          type: coiType,
          expiry_date: expiryDate,
          policy_number: policyNumber,
          insurer_name: insurerName,
          coverage_amount: maxCoverage || 1000000,
          additional_insured: additionalInsured,
          auto_extracted: extracted,
          status: 'pending_review',
          storage_path: storagePath || fileName
        }).select().single()

        if (!error) createdCoi = data
      } catch (e) {
        console.error('Failed to create COI record', e)
      }
    }

    return new Response(JSON.stringify({
      ok: true,
      extracted,
      coi_record: createdCoi,
      message: 'Extraction completed. Confidence: ' + extracted.confidence + '. Please verify extracted data.',
      next_steps: [
        'User should verify expiry_date, policy_number, coverage',
        'If ok, set status to valid via dashboard or GraphQL mutation',
        'System will then evaluate compliance via evaluate_vendor_compliance()'
      ]
    }, null, 2), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

  } catch (e: any) {
    console.error(e)
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' } })
  }
})
