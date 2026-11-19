import { apiUnavailable, upstreamFetch } from '../upstream'

export const dynamic = 'force-dynamic'

export async function POST(request) {
  const body = await request.text()
  let upstream
  try {
    upstream = await upstreamFetch('/v1/qr', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
    })
  } catch {
    return apiUnavailable()
  }

  let data
  try {
    data = await upstream.json()
  } catch {
    data = { detail: 'invalid response from api' }
  }

  if (upstream.status === 201) {
    return Response.json({ id: data.id, image_url: `/api/qr/${data.id}` }, { status: 201 })
  }
  return Response.json(data, { status: upstream.status })
}
