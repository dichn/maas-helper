#!/usr/bin/env bash
# End-to-end MaaS test. MaaS uses two credentials:
#   1. your OpenShift token (oc whoami -t) -> mints a MaaS API key via maas-api
#   2. the MaaS API key                     -> calls models through the gateway
# Usage: test-maas.sh <maas-hostname> <subscription> [prompt]
set -euo pipefail

HOST="https://$1"
SUBSCRIPTION="$2"
PROMPT="${3:-Say hello in one short sentence.}"

for bin in curl jq; do
    command -v "$bin" >/dev/null || { echo "❌ $bin is not installed"; exit 1; }
done

OC_TOKEN=$(oc whoami -t 2>/dev/null) || {
    echo "❌ No OpenShift token. Log in with a user token (oc login --token=...), not a kubeconfig cert."
    exit 1
}

# call METHOD URL TOKEN [JSON]: sets $STATUS and $BODY
call() {
    local resp
    resp=$(curl -sk -w '\n%{http_code}' -X "$1" "$2" \
        ${3:+-H "Authorization: Bearer $3"} \
        -H "Content-Type: application/json" ${4:+-d "$4"})
    STATUS=$(tail -n1 <<<"$resp")
    BODY=$(sed '$d' <<<"$resp")
}

echo "=== 1/5 Create API key (subscription: $SUBSCRIPTION) ==="
call POST "$HOST/maas-api/v1/api-keys" "$OC_TOKEN" \
    "$(jq -n --arg s "$SUBSCRIPTION" '{name:"maas-helper-test", expiresIn:"1h", subscription:$s}')"
[[ "$STATUS" == 2?? ]] || { echo "❌ HTTP $STATUS: $BODY"; exit 1; }
API_KEY=$(jq -r .key <<<"$BODY")
KEY_ID=$(jq -r .id <<<"$BODY")
trap 'curl -sk -o /dev/null -X DELETE -H "Authorization: Bearer $OC_TOKEN" "$HOST/maas-api/v1/api-keys/$KEY_ID"' EXIT
echo "✅ API key created (id: $KEY_ID, revoked on exit)"

echo "=== 2/5 List models ==="
call GET "$HOST/maas-api/v1/models" "$API_KEY"
[[ "$STATUS" == 2?? ]] || { echo "❌ HTTP $STATUS: $BODY"; exit 1; }
jq -r '.data[] | "   - \(.id)  \(.url // "")"' <<<"$BODY"
MODEL=$(jq -r '.data[0].id // empty' <<<"$BODY")
[[ -n "$MODEL" ]] || { echo "❌ No models visible for this subscription"; exit 1; }
MODEL_URL=$(jq -r '.data[0].url // empty' <<<"$BODY")
MODEL_URL="${MODEL_URL:-$HOST}"

echo "=== 3/5 Chat completion ($MODEL) ==="
CHAT=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model:$m, messages:[{role:"user", content:$p}], max_tokens:64}')
call POST "${MODEL_URL%/}/v1/chat/completions" "$API_KEY" "$CHAT"
[[ "$STATUS" == 2?? ]] || { echo "❌ HTTP $STATUS: $BODY"; exit 1; }
echo "   $(jq -r '.choices[0].message.content' <<<"$BODY" | tr '\n' ' ' | cut -c1-200)"
echo "   usage: $(jq -c .usage <<<"$BODY")"
echo "✅ Chat completion OK"

echo "=== 4/5 Request without API key (expect 401) ==="
# Same request, no key. The gateway routes by the "model" field, so the body must name the model.
call POST "${MODEL_URL%/}/v1/chat/completions" "" "$CHAT"
[[ "$STATUS" == 401 ]] && echo "✅ HTTP 401" || { echo "❌ Expected 401, got $STATUS"; exit 1; }

echo "=== 5/5 Revoke API key ==="
call DELETE "$HOST/maas-api/v1/api-keys/$KEY_ID" "$OC_TOKEN"
trap - EXIT
echo "✅ HTTP $STATUS"

echo "🎉 MaaS works end to end"
