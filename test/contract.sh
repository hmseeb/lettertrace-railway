#!/usr/bin/env bash
# Contract tests for the bundled Lettertrace image.
#
# The image is an appliance: it has to stand up its own login service, data API
# and web app against nothing but an empty Postgres and two secrets. These tests
# assert exactly that, because a green healthcheck has passed on a broken app in
# every template built so far.
#
# Usage:  ./test/contract.sh [image-tag]
set -uo pipefail

IMAGE="${1:-lettertrace-railway:test}"
NET="lt-contract-net"
PG="lt-contract-pg"
APP="lt-contract-app"
PORT=3399
PGPASS="contract-pg-pass"
JWT_SECRET="contract-jwt-secret-at-least-32-bytes-long-xxxxx"
ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }

cleanup() {
  docker rm -f "$APP" "$PG" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

echo "== booting throwaway postgres =="
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=railway \
  postgres:16-alpine >/dev/null || { echo "could not start postgres"; exit 1; }

for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

echo "== booting the image =="
docker run -d --name "$APP" --network "$NET" -p "$PORT:8080" \
  -e PORT=8080 \
  -e DATABASE_URL="postgresql://postgres:$PGPASS@$PG:5432/railway" \
  -e JWT_SECRET="$JWT_SECRET" \
  -e ENCRYPTION_KEY="$ENCRYPTION_KEY" \
  -e PUBLIC_URL="http://localhost:$PORT" \
  "$IMAGE" >/dev/null 2>&1 || { echo "could not start $IMAGE"; exit 1; }

BASE="http://localhost:$PORT"
booted=""
for _ in $(seq 1 180); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/login" 2>/dev/null)
  [ "$code" = "200" ] && { booted=yes; break; }
  docker ps -q -f name="$APP" | grep -q . || break
  sleep 1
done

echo
echo "== contract =="

# 1. the web app itself answers
if [ "$booted" = "yes" ]; then ok "sign-in page serves 200"
else bad "sign-in page serves 200" "$(docker logs --tail 30 "$APP" 2>&1 | tr '\n' '|')"; fi

# 2. the browser is handed a login key at runtime, not one baked in at build
html=$(curl -s "$BASE/login")
if echo "$html" | grep -q "__LETTERTRACE_PUBLIC_ENV__"; then
  url=$(echo "$html" | grep -o '__LETTERTRACE_PUBLIC_ENV__={[^<]*' | head -1)
  if echo "$url" | grep -q "localhost:$PORT"; then ok "runtime public config points at this deployment"
  else bad "runtime public config points at this deployment" "$url"; fi
else bad "runtime public config is delivered to the browser"; fi

# 3. the login service is reachable on the path supabase-js uses
health=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/auth/v1/health")
[ "$health" = "200" ] && ok "login service answers on /auth/v1" || bad "login service answers on /auth/v1" "got $health"

# 4. a stranger can create an account and is signed in immediately
EMAIL="contract-$RANDOM@example.com"
# Taken from the page the browser gets, which is the only place it is published
# and therefore the only honest place to read it from.
ANON=$(echo "$html" | grep -o '"supabaseAnonKey":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$ANON" ] && ok "an anon key was minted at boot" || bad "an anon key was minted at boot"

signup=$(curl -s -X POST "$BASE/auth/v1/signup" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"contract-password-123\"}")
TOKEN=$(echo "$signup" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
UID_=$(echo "$signup" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user",{}).get("id",""))' 2>/dev/null)
[ -n "$TOKEN" ] && ok "signup returns a session" || bad "signup returns a session" "$signup"

# 5. the signup trigger created the profile row (proves schema.sql applied
#    AFTER the login service migrated its own tables)
prof=$(curl -s "$BASE/rest/v1/profiles?select=id,email" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN")
if echo "$prof" | grep -q "$EMAIL"; then ok "signup auto-created the profile row"
else bad "signup auto-created the profile row" "$prof"; fi

# 6. row-level isolation is live: no token, no rows
anonread=$(curl -s "$BASE/rest/v1/profiles?select=id" -H "apikey: $ANON" -H "Authorization: Bearer $ANON")
if [ "$anonread" = "[]" ]; then ok "a signed-out reader sees no rows"
else bad "a signed-out reader sees no rows" "$anonread"; fi

# 7. the app's own server routes work with the session cookie path
me=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/projects" -H "Authorization: Bearer $TOKEN")
[ "$me" = "401" ] || [ "$me" = "200" ] && ok "the app API answers rather than crashing (got $me)" || bad "the app API answers" "got $me"

# 8. writing through the data API round-trips, and the ownership rule is
#    enforced from the token rather than trusted from the body
proj=$(curl -s -X POST "$BASE/rest/v1/projects" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -H "Prefer: return=representation" \
  -d "{\"name\":\"Contract\",\"brand_name\":\"Contract\",\"user_id\":\"$UID_\"}")
if echo "$proj" | grep -q '"name":"Contract"'; then ok "a row written through the data API reads back"
else bad "a row written through the data API reads back" "$proj"; fi

# 9. the same write claiming somebody else owns it must be refused, which is
#    what proves auth.uid() is really reading the caller's token
stolen=$(curl -s -X POST "$BASE/rest/v1/projects" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Stolen","brand_name":"Stolen","user_id":"00000000-0000-0000-0000-000000000001"}')
if echo "$stolen" | grep -q "row-level security"; then ok "a write claiming another owner is refused"
else bad "a write claiming another owner is refused" "$stolen"; fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
