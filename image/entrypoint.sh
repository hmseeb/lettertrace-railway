#!/usr/bin/env bash
# Boots the appliance: signing keys, database roles, accounts service, data API,
# the app, and the router that puts them all on one origin.
#
# Order is not arbitrary and each step below says why it has to come where it
# does. The one that will bite anyone editing this: Lettertrace's schema.sql
# hangs a trigger off auth.users, so it cannot be applied until GoTrue has
# finished creating auth.users, which only happens once GoTrue is running.
set -euo pipefail

log() { echo "[lettertrace] $*"; }
die() { echo "[lettertrace] FATAL: $*" >&2; exit 1; }

# ------------------------------------------------------------------ inputs
[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set (attach the Postgres service)"
[ -n "${JWT_SECRET:-}" ]   || die "JWT_SECRET is not set"
[ "${#JWT_SECRET}" -ge 32 ] || die "JWT_SECRET must be at least 32 characters"

# The at-rest key for the deployer's own AI provider keys must decode to
# exactly 32 bytes, which is an awkward thing to ask a template variable for -
# a random string of the right length only decodes to 32 bytes by accident.
# Hashing any secret down to 32 bytes makes the requirement disappear. An
# explicit ENCRYPTION_KEY still wins, so a deployment migrated from upstream
# keeps reading its existing stored keys.
if [ -z "${ENCRYPTION_KEY:-}" ]; then
  [ -n "${ENCRYPTION_SECRET:-}" ] || die "set ENCRYPTION_SECRET (or ENCRYPTION_KEY)"
  ENCRYPTION_KEY="$(node -e '
    const { createHash } = require("node:crypto");
    process.stdout.write(createHash("sha256").update(process.env.ENCRYPTION_SECRET).digest("base64"));
  ')"
fi
export ENCRYPTION_KEY

PORT="${PORT:-8080}"
APP_PORT="${APP_PORT:-3001}"
AUTH_PORT="${AUTH_PORT:-9999}"
REST_PORT="${REST_PORT:-3002}"

# The origin the browser reaches. It has to be the public one: supabase-js runs
# in the page and calls the accounts and data APIs directly, so an internal
# hostname here produces an app that renders perfectly and cannot sign anyone in.
if [ -z "${PUBLIC_URL:-}" ]; then
  if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
  else
    die "PUBLIC_URL is not set and no Railway public domain was found"
  fi
fi
PUBLIC_URL="${PUBLIC_URL%/}"
log "public origin: $PUBLIC_URL"

# ------------------------------------------------------- derived credentials
export NEXT_PUBLIC_SUPABASE_ANON_KEY="$(JWT_SECRET="$JWT_SECRET" node /app/bin/mint-keys.mjs anon)"
export SUPABASE_SERVICE_ROLE_KEY="$(JWT_SECRET="$JWT_SECRET" node /app/bin/mint-keys.mjs service_role)"
export NEXT_PUBLIC_SUPABASE_URL="$PUBLIC_URL"
export NEXT_PUBLIC_SITE_URL="$PUBLIC_URL"

# The data API's own login to Postgres. Derived from the signing secret so it is
# stable across redeploys without being stored anywhere or shown to anyone.
AUTHENTICATOR_PW="$(printf '%s' "$JWT_SECRET" | sha256sum | cut -c1-48)"
AUTH_ADMIN_PW="$(printf 'auth-admin:%s' "$JWT_SECRET" | sha256sum | cut -c1-48)"

# Swap the user and password on the database URL without parsing it by hand.
db_url_as() {
  ROLE="$1" ROLE_PW="$2" node -e '
    const u = new URL(process.env.DATABASE_URL);
    u.username = process.env.ROLE;
    u.password = process.env.ROLE_PW;
    process.stdout.write(u.toString());
  '
}

# ------------------------------------------------------------ wait for postgres
log "waiting for the database"
for i in $(seq 1 120); do
  if psql "$DATABASE_URL" -qAt -c 'select 1' >/dev/null 2>&1; then break; fi
  [ "$i" = 120 ] && die "database never became reachable"
  sleep 2
done
log "database is up"

# --------------------------------------------------------------- 1. platform
# Roles, grants and auth.uid(). Must precede schema.sql, whose policies would
# otherwise fail to create, and whose REVOKEs would otherwise revoke nothing.
log "applying platform bootstrap"
psql "$DATABASE_URL" -qAt -v ON_ERROR_STOP=1 \
  -v authenticator_pw="$AUTHENTICATOR_PW" \
  -v auth_admin_pw="$AUTH_ADMIN_PW" \
  -f /app/sql/bootstrap.sql >/dev/null

# ------------------------------------------------------------- 2. accounts
log "starting the accounts service"
env -i \
  PATH="$PATH" \
  HOME=/root \
  GOTRUE_DB_MIGRATIONS_PATH="${GOTRUE_DB_MIGRATIONS_PATH}" \
  GOTRUE_DB_DRIVER=postgres \
  GOTRUE_DB_DATABASE_URL="$(db_url_as supabase_auth_admin "$AUTH_ADMIN_PW")" \
  GOTRUE_DB_NAMESPACE=auth \
  GOTRUE_API_HOST=127.0.0.1 \
  PORT="$AUTH_PORT" \
  API_EXTERNAL_URL="$PUBLIC_URL" \
  GOTRUE_SITE_URL="$PUBLIC_URL" \
  GOTRUE_URI_ALLOW_LIST="$PUBLIC_URL,$PUBLIC_URL/**" \
  GOTRUE_JWT_SECRET="$JWT_SECRET" \
  GOTRUE_JWT_EXP=3600 \
  GOTRUE_JWT_AUD=authenticated \
  GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
  GOTRUE_DISABLE_SIGNUP="${DISABLE_SIGNUP:-false}" \
  GOTRUE_EXTERNAL_EMAIL_ENABLED=true \
  GOTRUE_EXTERNAL_PHONE_ENABLED=false \
  GOTRUE_SMS_AUTOCONFIRM=true \
  GOTRUE_MAILER_AUTOCONFIRM="${MAILER_AUTOCONFIRM:-true}" \
  GOTRUE_LOG_LEVEL="${LOG_LEVEL:-info}" \
  /usr/local/bin/gotrue &
GOTRUE_PID=$!

# Wait on the service answering, NOT on auth.users existing. A failed migration
# rolls back only its own step, so the table can be sitting there while the
# service is already dead - which is exactly how the missing-enum bug above
# first showed up as a green wait followed by a broken app.
log "waiting for the accounts service"
for i in $(seq 1 120); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$AUTH_PORT/health" 2>/dev/null; then break; fi
  kill -0 "$GOTRUE_PID" 2>/dev/null || die "accounts service exited during migration"
  [ "$i" = 120 ] && die "accounts service never became healthy"
  sleep 2
done
log "accounts service is ready"

# ---------------------------------------------------------- 3. app schema
# Upstream documents this file as safe to re-run, which is what lets an image
# upgrade carry a schema upgrade with it.
log "repointing the auth helpers at the current claim format"
psql "$DATABASE_URL" -qAt -v ON_ERROR_STOP=1 -f /app/sql/auth-helpers.sql >/dev/null

log "applying the application schema"
psql "$DATABASE_URL" -qAt -v ON_ERROR_STOP=1 -f /app/sql/schema.sql >/dev/null

# -------------------------------------------------------------- 4. data API
log "starting the data API"
DB_URI="$(AUTHENTICATOR_PW="$AUTHENTICATOR_PW" node -e '
  const u = new URL(process.env.DATABASE_URL);
  u.username = "authenticator";
  u.password = process.env.AUTHENTICATOR_PW;
  process.stdout.write(u.toString());
')"

env -i \
  PATH="$PATH" \
  PGRST_DB_URI="$DB_URI" \
  PGRST_DB_SCHEMAS=public \
  PGRST_DB_ANON_ROLE=anon \
  PGRST_JWT_SECRET="$JWT_SECRET" \
  PGRST_SERVER_HOST=127.0.0.1 \
  PGRST_SERVER_PORT="$REST_PORT" \
  PGRST_LOG_LEVEL=error \
  /usr/local/bin/postgrest &
PGRST_PID=$!

# ------------------------------------------------------------------ 5. app
log "starting the web app"
(
  cd /app
  PORT="$APP_PORT" HOSTNAME=127.0.0.1 exec node server.js
) &
APP_PID=$!

# --------------------------------------------------------------- 6. router
# One origin in front of all three, because supabase-js builds every URL it
# calls by appending /auth/v1/... and /rest/v1/... to a single base.
cat > /etc/nginx/nginx.conf <<NGINX
worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;
events { worker_connections 2048; }
http {
  include /etc/nginx/mime.types;
  access_log off;
  server_tokens off;
  client_max_body_size 20m;
  proxy_http_version 1.1;
  proxy_read_timeout 600s;
  proxy_send_timeout 600s;

  # A signed-in session is three chunked cookies of ~3.5k each, so both the
  # Set-Cookie response and every request that carries them back blow past
  # nginx's 4k/8k header defaults. Unset, the app 502s the moment you log in.
  proxy_buffer_size 32k;
  proxy_buffers 8 32k;
  proxy_busy_buffers_size 64k;
  large_client_header_buffers 8 32k;

  # Railway terminates TLS at its edge, so \$scheme here is http. Trust the
  # header it sets, and fall back to it for direct local runs.
  map \$http_x_forwarded_proto \$fwd_proto {
    default \$http_x_forwarded_proto;
    ''      \$scheme;
  }

  server {
    listen $PORT default_server;
    listen [::]:$PORT default_server;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$fwd_proto;
    proxy_set_header X-Forwarded-Host \$host;

    # Trailing slashes matter: they strip the prefix, because GoTrue serves
    # /token and PostgREST serves /profiles, both at their own root.
    location /auth/v1/ { proxy_pass http://127.0.0.1:$AUTH_PORT/; }
    location /rest/v1/ { proxy_pass http://127.0.0.1:$REST_PORT/; }

    # The interactive OAuth screens hand the browser back to a CLI's own
    # loopback address on purpose, so their redirects must be left alone. They
    # are listed before the catch-all so the rewrite below cannot reach them.
    location /api/oauth/ { proxy_pass http://127.0.0.1:$APP_PORT; proxy_redirect off; }
    location /oauth/     { proxy_pass http://127.0.0.1:$APP_PORT; proxy_redirect off; }
    location /activate   { proxy_pass http://127.0.0.1:$APP_PORT; proxy_redirect off; }

    # Everything else is the app, including /auth/callback, which is a Next
    # route and is deliberately not matched by /auth/v1/ above.
    location / {
      proxy_pass http://127.0.0.1:$APP_PORT;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";

      # Next builds middleware redirect URLs from the address it is bound to
      # and never from the Host header (next-server.js: \`fetchHostname ||
      # "localhost"\`), so the guard on /dashboard sends a signed-out visitor to
      # https://localhost:$APP_PORT/login - their own machine. The app's route
      # handlers already resolve this themselves; middleware is the one place
      # that cannot. Pin it back to the public origin on the way out, matching
      # only this container's own port so a genuine loopback redirect elsewhere
      # is untouched.
      proxy_redirect ~^https?://(?:localhost|127\.0\.0\.1):$APP_PORT(/.*)\$ $PUBLIC_URL\$1;
    }
  }
}
NGINX

log "starting the router on port $PORT"
nginx -g 'daemon off;' &
NGINX_PID=$!

trap 'kill $GOTRUE_PID $PGRST_PID $APP_PID $NGINX_PID 2>/dev/null || true' TERM INT

# If any one of the four dies the container is broken, so let it die and be
# restarted rather than serving a half-working app.
wait -n
log "a component exited; shutting down"
kill $GOTRUE_PID $PGRST_PID $APP_PID $NGINX_PID 2>/dev/null || true
exit 1
