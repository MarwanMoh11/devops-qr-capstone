import { apiUnavailable, upstreamFetch } from '../../upstream'

export const dynamic = 'force-dynamic'

const PASSTHROUGH_HEADERS = ['content-type', 'cache-control']

export async function GET(_request, { params }) {
  const { id } = await params
  let upstream
  try {
    upstream = await upstreamFetch(`/v1/qr/${encodeURIComponent(id)}`)
  } catch {
    return apiUnavailable()
  }

  const headers = new Headers()
  for (const name of PASSTHROUGH_HEADERS) {
    const value = upstream.headers.get(name)
    if (value) headers.set(name, value)
  }
  return new Response(upstream.body, { status: upstream.status, headers })
}
