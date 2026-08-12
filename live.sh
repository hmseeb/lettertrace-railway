#!/usr/bin/env bash
# Drives the real user journey against a live deployment.
#
# Usage:  ./live.sh https://your-app.up.railway.app
set -uo pipefail

BASE="${1:?usage: live.sh <origin>}"
BASE="${BASE%/}"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }

echo "== $BASE =="

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/login")
[ "$code" = "200" ] && ok "sign-in page serves 200" || bad "sign-in page serves 200" "got $code"

html=$(curl -s "$BASE/login")
host="${BASE#https://}"
if echo "$html" | grep -q "\"supabaseUrl\":\"$BASE\""; then
  ok "the browser is pointed at this deployment's own origin"
else
  bad "the browser is pointed at this deployment's own origin" \
      "$(echo "$html" | grep -o '"supabaseUrl":"[^"]*"' | head -1)"
fi

ANON=$(echo "$html" | grep -o '"supabaseAnonKey":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$ANON" ] && ok "a browser key was minted at boot" || bad "a browser key was minted at boot"

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/auth/v1/health")
[ "$code" = "200" ] && ok "the accounts service answers over the public origin" \
                    || bad "the accounts service answers over the public origin" "got $code"

EMAIL="live-$RANDOM-$RANDOM@example.com"
PASSWORD="live-verification-password-123"

signup=$(curl -s -X POST "$BASE/auth/v1/signup" -H "apikey: $ANON" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")
TOKEN=$(echo "$signup" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
USERID=$(echo "$signup" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user",{}).get("id",""))' 2>/dev/null)
[ -n "$TOKEN" ] && ok "a stranger can create an account" || bad "a stranger can create an account" "$signup"

# Signing out and back in is a different code path from signup and is the one
# every returning visit uses.
signin=$(curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")
TOKEN2=$(echo "$signin" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
[ -n "$TOKEN2" ] && ok "the same account can sign back in" || bad "the same account can sign back in" "$signin"
[ -n "$TOKEN2" ] && TOKEN="$TOKEN2"

prof=$(curl -s "$BASE/rest/v1/profiles?select=id,email" -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN")
echo "$prof" | grep -q "$EMAIL" && ok "the account has a profile row" || bad "the account has a profile row" "$prof"

# The full shape the setup wizard writes: an organisation, a competitor, a
# topic and a prompt under it.
proj=$(curl -s -X POST "$BASE/rest/v1/projects" -H "apikey: $ANON" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"name\":\"Live Check\",\"brand_name\":\"Live Check\",\"brand_domains\":[\"example.com\"],\"user_id\":\"$USERID\"}")
PROJID=$(echo "$proj" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")' 2>/dev/null)
[ -n "$PROJID" ] && ok "an organisation can be created" || bad "an organisation can be created" "$proj"

comp=$(curl -s -X POST "$BASE/rest/v1/competitors" -H "apikey: $ANON" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"project_id\":\"$PROJID\",\"name\":\"Rival\"}")
echo "$comp" | grep -q '"name":"Rival"' && ok "a competitor can be added" || bad "a competitor can be added" "$comp"

topic=$(curl -s -X POST "$BASE/rest/v1/topics" -H "apikey: $ANON" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"project_id\":\"$PROJID\",\"name\":\"brand monitoring\"}")
TOPICID=$(echo "$topic" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")' 2>/dev/null)
[ -n "$TOPICID" ] && ok "a topic can be added" || bad "a topic can be added" "$topic"

prompt=$(curl -s -X POST "$BASE/rest/v1/prompts" -H "apikey: $ANON" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"project_id\":\"$PROJID\",\"topic_id\":\"$TOPICID\",\"text\":\"best brand monitoring tool\"}")
echo "$prompt" | grep -q "best brand monitoring tool" && ok "a prompt can be added" || bad "a prompt can be added" "$prompt"

# Read it all back the way the dashboard does, in one nested query.
back=$(curl -s "$BASE/rest/v1/projects?select=name,topics(name,prompts(text)),competitors(name)&id=eq.$PROJID" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN")
# Nested results come back pretty-printed by the data API, so match on the
# values rather than on an exact JSON spelling.
if echo "$back" | grep -q "best brand monitoring tool" && echo "$back" | grep -q "Rival"; then
  ok "the dashboard's own nested read returns everything"
else
  bad "the dashboard's own nested read returns everything" "$back"
fi

# Somebody else's session must not see any of it.
OTHER=$(curl -s -X POST "$BASE/auth/v1/signup" -H "apikey: $ANON" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"other-$RANDOM@example.com\",\"password\":\"$PASSWORD\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
theirs=$(curl -s "$BASE/rest/v1/projects?select=id" -H "apikey: $ANON" -H "Authorization: Bearer $OTHER")
[ "$theirs" = "[]" ] && ok "a second account sees none of the first account's data" \
                     || bad "a second account sees none of the first account's data" "$theirs"

# The app's own server routes, which is a different process from the two above.
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/projects" -H "Authorization: Bearer lt_live_nonsense")
[ "$code" = "401" ] && ok "the app's API refuses a bad key rather than erroring" \
                    || bad "the app's API refuses a bad key" "got $code"

# The scheduled-run endpoint must refuse an unauthenticated caller: it spends
# the deployer's provider credit.
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/cron/run")
[ "$code" = "401" ] || [ "$code" = "403" ] && ok "the scheduled-run endpoint refuses an unauthenticated call (got $code)" \
                    || bad "the scheduled-run endpoint refuses an unauthenticated call" "got $code"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
