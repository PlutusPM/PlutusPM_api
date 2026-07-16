// graphql-gateway - Secure GraphQL Gateway with Rate Limiting, Depth/Complexity Checks, Logging, Persisted Queries
// Implements OWASP A05 Security Misconfiguration, A07 Auth, A09 Logging, GraphQL best practices
// This function sits in front of /graphql/v1 and adds WAF-like protections

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

type GraphQLRequest = {
  query: string
  variables?: Record<string, unknown>
  operationName?: string
  extensions?: {
    persistedQuery?: {
      version: number
      sha256Hash: string
    }
  }
}

// Simple in-memory rate limit store (for local dev) - in production use Upstash Redis or platform.rate_limits table
const rateLimitMap = new Map<string, { count: number, resetAt: number }>()

function getClientIP(req: Request): string {
  return req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
         req.headers.get('x-real-ip') ||
         req.headers.get('cf-connecting-ip') ||
         'unknown-ip'
}

function calculateDepth(query: string): number {
  // Simple depth calculation: count max nesting of { }
  let maxDepth = 0
  let currentDepth = 0
  for (const char of query) {
    if (char === '{') {
      currentDepth++
      maxDepth = Math.max(maxDepth, currentDepth)
    } else if (char === '}') {
      currentDepth--
    }
  }
  return maxDepth
}

function calculateComplexity(query: string): number {
  // Simple complexity: count fields (words before { or inside selection)
  // More accurate would require parsing AST, but simple heuristic for MVP
  const fieldMatches = query.match(/\b\w+\b(?=\s*[\{\(])/g) || []
  return fieldMatches.length
}

function countAliases(query: string): number {
  // Count aliases: pattern "alias: field"
  const aliasMatches = query.match(/\b\w+\s*:\s*\w+/g) || []
  return aliasMatches.length
}

// Persisted queries whitelist (in production, load from storage or env)
const PERSISTED_QUERIES: Record<string, string> = {
  // Example: sha256 hash -> query string
  // These would be generated at build time from frontend queries
  // For now, empty - allows all queries in dev, but in prod you would enforce whitelist
}

Deno.serve(async (req) => {
  const startTime = Date.now()
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // For rate limiting via DB (optional, more persistent than in-memory)
    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey)

    // Parse body
    let body: GraphQLRequest
    try {
      body = await req.json()
    } catch {
      return new Response(JSON.stringify({ errors: [{ message: 'Invalid JSON body' }] }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    let { query, variables, operationName } = body

    // Handle persisted queries
    if (body.extensions?.persistedQuery?.sha256Hash) {
      const hash = body.extensions.persistedQuery.sha256Hash
      if (PERSISTED_QUERIES[hash]) {
        query = PERSISTED_QUERIES[hash]
      } else {
        // In production with whitelist enforced, reject unknown hashes
        // For dev, allow if query also provided
        if (!query) {
          return new Response(JSON.stringify({ errors: [{ message: `Persisted query not found for hash ${hash}` }] }), { status: 400, headers: corsHeaders })
        }
      }
    }

    if (!query || typeof query !== 'string') {
      return new Response(JSON.stringify({ errors: [{ message: 'Query is required' }] }), { status: 400, headers: corsHeaders })
    }

    // Security: Query depth limiting (OWASP - prevent deeply nested DoS)
    const depth = calculateDepth(query)
    const MAX_DEPTH = 10
    if (depth > MAX_DEPTH) {
      return new Response(JSON.stringify({ errors: [{ message: `Query depth ${depth} exceeds max ${MAX_DEPTH}` }] }), { status: 400, headers: corsHeaders })
    }

    // Security: Complexity limiting
    const complexity = calculateComplexity(query)
    const MAX_COMPLEXITY = 1000
    if (complexity > MAX_COMPLEXITY) {
      return new Response(JSON.stringify({ errors: [{ message: `Query complexity ${complexity} exceeds max ${MAX_COMPLEXITY}` }] }), { status: 400, headers: corsHeaders })
    }

    // Security: Alias overloading check (prevent batching DoS via many aliases)
    const aliasCount = countAliases(query)
    const MAX_ALIASES = 20
    if (aliasCount > MAX_ALIASES) {
      return new Response(JSON.stringify({ errors: [{ message: `Alias count ${aliasCount} exceeds max ${MAX_ALIASES} - possible batching DoS` }] }), { status: 400, headers: corsHeaders })
    }

    // Security: Disable introspection in production
    // In dev we allow __schema, in prod we can block if env var says so
    const disableIntrospection = Deno.env.get('DISABLE_GRAPHQL_INTROSPECTION') === 'true'
    if (disableIntrospection && (query.includes('__schema') || query.includes('__type'))) {
      return new Response(JSON.stringify({ errors: [{ message: 'Introspection is disabled in production' }] }), { status: 400, headers: corsHeaders })
    }

    // Rate limiting (OWASP A05 + A07)
    const clientIP = getClientIP(req)
    const authHeader = req.headers.get('Authorization') || ''
    let userId = 'anon'

    // Try to decode JWT to get user_id for per-user rate limiting (without verifying, just decode payload)
    if (authHeader.startsWith('Bearer ')) {
      try {
        const token = authHeader.replace('Bearer ', '')
        const payloadPart = token.split('.')[1]
        if (payloadPart) {
          const normalized = payloadPart.replace(/-/g, '+').replace(/_/g, '/')
          const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=')
          const payload = JSON.parse(atob(padded))
          if (payload.sub) userId = payload.sub
        }
      } catch {
        // Ignore decode errors, treat as anon
      }
    }

    // Check rate limits via platform.rate_limits table (persistent) + in-memory for speed
    // For MVP, use in-memory Map, but also try DB function check_rate_limit if available
    const now = Date.now()
    const windowMs = 60 * 1000 // 1 minute

    // In-memory check for IP: 60 req/min
    const ipKey = `graphql:ip:${clientIP}`
    const ipEntry = rateLimitMap.get(ipKey)
    if (ipEntry && ipEntry.resetAt > now) {
      if (ipEntry.count >= 60) {
        return new Response(JSON.stringify({ errors: [{ message: 'Rate limit exceeded for IP - 60 req/min' }] }), { status: 429, headers: { ...corsHeaders, 'Retry-After': '60' } })
      }
      ipEntry.count++
    } else {
      rateLimitMap.set(ipKey, { count: 1, resetAt: now + windowMs })
    }

    // In-memory check for user: 100 req/min
    if (userId !== 'anon') {
      const userKey = `graphql:user:${userId}`
      const userEntry = rateLimitMap.get(userKey)
      if (userEntry && userEntry.resetAt > now) {
        if (userEntry.count >= 100) {
          return new Response(JSON.stringify({ errors: [{ message: 'Rate limit exceeded for user - 100 req/min' }] }), { status: 429, headers: { ...corsHeaders, 'Retry-After': '60' } })
        }
        userEntry.count++
      } else {
        rateLimitMap.set(userKey, { count: 1, resetAt: now + windowMs })
      }
    }

    // Also try DB-based rate limiting via platform.check_rate_limit function (more persistent across instances)
    try {
      const { data: ipAllowed } = await supabaseAdmin.rpc('check_rate_limit' as any, {
        p_identifier: `ip:${clientIP}`,
        p_action: 'graphql_query',
        p_limit: 60,
        p_window_seconds: 60
      } as any)

      if (ipAllowed === false) {
        return new Response(JSON.stringify({ errors: [{ message: 'Rate limit exceeded (DB) for IP' }] }), { status: 429, headers: corsHeaders })
      }

      if (userId !== 'anon') {
        const { data: userAllowed } = await supabaseAdmin.rpc('check_rate_limit' as any, {
          p_identifier: `user:${userId}`,
          p_action: 'graphql_query',
          p_limit: 100,
          p_window_seconds: 60
        } as any)

        if (userAllowed === false) {
          return new Response(JSON.stringify({ errors: [{ message: 'Rate limit exceeded (DB) for user' }] }), { status: 429, headers: corsHeaders })
        }
      }
    } catch (e) {
      // If DB rate limiting fails (table not exists yet, etc), log but don't block
      console.warn('DB rate limit check failed:', e)
    }

    // Forward to real GraphQL endpoint
    const graphqlUrl = `${supabaseUrl}/graphql/v1`
    
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'apikey': req.headers.get('apikey') || supabaseAnonKey,
    }

    // Forward Authorization if present
    if (authHeader) {
      headers['Authorization'] = authHeader
    }

    // Forward other relevant headers
    const contentProfile = req.headers.get('Content-Profile')
    if (contentProfile) headers['Content-Profile'] = contentProfile
    const acceptProfile = req.headers.get('Accept-Profile')
    if (acceptProfile) headers['Accept-Profile'] = acceptProfile

    const graphqlResponse = await fetch(graphqlUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify({ query, variables, operationName })
    })

    const result = await graphqlResponse.json()

    // Logging (OWASP A09) - log query without sensitive variables, with user_id, IP, duration, errors
    const duration = Date.now() - startTime
    const logEntry = {
      timestamp: new Date().toISOString(),
      ip: clientIP,
      userId,
      operationName,
      queryHash: query.length > 100 ? `${query.substring(0,100)}...` : query,
      variablesKeys: variables ? Object.keys(variables) : [],
      durationMs: duration,
      hasErrors: !!result.errors,
      errorCount: result.errors?.length || 0,
      status: graphqlResponse.status
    }

    console.log('GraphQL Gateway:', JSON.stringify(logEntry))

    // Try to insert audit log for sensitive operations (mutations) - optional
    if (query.trim().startsWith('mutation') && userId !== 'anon') {
      try {
        // Find org_id from user's memberships? For now, skip org_id, just log
        // In production, you'd want to log to platform.audit_logs with org_id, site_id, etc
      } catch {}
    }

    // Return result with same status, but sanitize errors in production (don't leak stack)
    const isProd = Deno.env.get('ENVIRONMENT') === 'production'
    let sanitizedResult = result

    if (isProd && result.errors) {
      // In prod, don't leak internal SQL or stack traces, return generic message but log details server-side
      sanitizedResult = {
        data: result.data,
        errors: result.errors.map((err: any) => ({
          message: err.message.includes('permission') || err.message.includes('access') || err.message.includes('denied')
            ? err.message // Keep authz errors
            : 'An error occurred while processing your request', // Generic for others
          path: err.path
        }))
      }
    }

    return new Response(JSON.stringify(sanitizedResult), {
      status: graphqlResponse.status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })

  } catch (e: any) {
    console.error('GraphQL Gateway error:', e)
    return new Response(JSON.stringify({ errors: [{ message: 'Internal server error in GraphQL gateway' }] }), { status: 500, headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' } })
  }
})
