// Server-only helpers for the /api/* route handlers. API_INTERNAL_URL is read per
// request so one image runs unchanged in compose, kind and EKS.
const UPSTREAM_TIMEOUT_MS = 10000

export function apiUrl(path) {
  const base = process.env.API_INTERNAL_URL || 'http://qr-api:8000'
  return `${base.replace(/\/+$/, '')}${path}`
}

export function upstreamFetch(path, init = {}) {
  return fetch(apiUrl(path), {
    ...init,
    cache: 'no-store',
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  })
}

export function apiUnavailable() {
  return Response.json({ detail: 'api unavailable' }, { status: 502 })
}
