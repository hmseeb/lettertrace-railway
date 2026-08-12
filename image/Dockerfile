# Lettertrace, packaged as a self-contained appliance for a one-click deploy.
#
# WHY THIS IMAGE EXISTS AT ALL. Upstream publishes ghcr.io/letterstory/lettertrace,
# but (a) that package is not anonymously pullable, and (b) it deliberately keeps
# Supabase outside the container, so a deployer has to go create a Supabase
# project and paste 1,100 lines of SQL into it before the app does anything.
# That is a fine shape for `docker run`; it is a broken shape for a template
# whose entire promise is that clicking the button gives you a working app.
#
# So this image carries the two Supabase pieces Lettertrace actually uses -
# GoTrue (accounts and sessions) and PostgREST (the data API behind
# supabase-js's .from()) - plus nginx to put all three behind one origin, which
# is what supabase-js expects. Storage and Realtime are omitted because the app
# never calls them (verified: no .storage.from, no .channel, no realtime import).
#
# Postgres is NOT in here. Railway has a first-class Postgres service and the
# data must outlive the app container.

ARG LETTERTRACE_REF=061bb2d8a027f76e4b51a0969f4c9ca8628bad84
ARG GOTRUE_VERSION=v2.177.0
ARG POSTGREST_VERSION=v12.2.12

# ---------------------------------------------------------------- base runtime
# Ubuntu 24.04 rather than the alpine base upstream uses, because PostgREST's
# published binary is linked against Ubuntu 24.04's glibc. Copying it onto musl
# or onto Debian bookworm's older glibc fails at exec time, not at build time,
# which is the worst place to find out.
FROM ubuntu:24.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------ app build
FROM base AS builder
ARG LETTERTRACE_REF
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && git init . \
 && git remote add origin https://github.com/letterstory/lettertrace.git \
 && git fetch --depth 1 origin "$LETTERTRACE_REF" \
 && git checkout FETCH_HEAD \
 && rm -rf /var/lib/apt/lists/*

RUN npm ci
# No NEXT_PUBLIC_* build args, same reason upstream refuses them: they would be
# inlined into the browser bundle and silently override what we set at boot.
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ------------------------------------------------------------- binary sources
FROM supabase/gotrue:${GOTRUE_VERSION} AS gotrue
FROM postgrest/postgrest:${POSTGREST_VERSION} AS postgrest

# ---------------------------------------------------------------- final image
FROM base AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx postgresql-client libpq5 libgmp10 libnuma1 tini \
 && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default

# GoTrue is a static Go binary, so the alpine origin does not matter. Its
# migrations are plain files it reads at startup and are not embedded.
COPY --from=gotrue /usr/local/bin/auth /usr/local/bin/gotrue
COPY --from=gotrue /usr/local/etc/auth/migrations /usr/local/etc/auth/migrations
COPY --from=postgrest /usr/bin/postgrest /usr/local/bin/postgrest

WORKDIR /app
# `standalone` ships its own trimmed node_modules; static/ and public/ are not
# part of it and have to be copied separately.
COPY --from=builder /src/.next/standalone ./
COPY --from=builder /src/.next/static ./.next/static
COPY --from=builder /src/public ./public
# Applied on every boot. Upstream guarantees it is safe to re-run, which is what
# makes an image upgrade also a schema upgrade.
COPY --from=builder /src/supabase/schema.sql /app/sql/schema.sql

COPY bootstrap.sql /app/sql/bootstrap.sql
COPY auth-helpers.sql /app/sql/auth-helpers.sql
COPY mint-keys.mjs /app/bin/mint-keys.mjs
COPY entrypoint.sh /app/bin/entrypoint.sh
RUN chmod +x /app/bin/entrypoint.sh

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8080 \
    APP_PORT=3001 \
    AUTH_PORT=9999 \
    REST_PORT=3002 \
    GOTRUE_DB_MIGRATIONS_PATH=/usr/local/etc/auth/migrations

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/entrypoint.sh"]
