# syntax=docker/dockerfile:1
# Stages: deps (npm ci) -> test (lint) / builder (next build) -> runtime (default).
# Debian slim, not Alpine: musl fails lookups when a resolver returns an empty AAAA
# answer (seen on Colima), which hangs npm ci. glibc handles it.
FROM node:24.22.3-trixie-slim AS deps
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM deps AS test
COPY . .
RUN npm run lint

FROM deps AS builder
COPY . .
RUN npm run build

FROM node:24.22.3-trixie-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1
# App files stay root-owned (read-only at runtime); only the cache dir belongs to the app user.
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
RUN mkdir -p .next/cache && chown 1001:1001 .next/cache
USER 1001:1001
EXPOSE 3000
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:3000/api/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
CMD ["node", "server.js"]
