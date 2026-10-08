#!/usr/bin/env bash
# Sign and send a fake Supliful webhook delivery to a local receiver.
#
# usage: sign-webhook.sh <secret> <url> <idempotency-key> '<json-body>' [unix-timestamp]
#
# Examples:
#   sign-webhook.sh devsecret http://localhost:4000/webhooks/supliful k1 \
#     '{"type":"order.created","occurredAt":"2026-01-01T00:00:00Z","data":{"orderId":"11111111-1111-4111-8111-111111111111","externalOrderId":"VS-000001"}}'
#   # stale delivery (should be rejected):
#   sign-webhook.sh devsecret http://localhost:4000/webhooks/supliful k2 '{...}' 1700000000
set -euo pipefail

if [ $# -lt 4 ]; then
  sed -n '2,10p' "$0"
  exit 1
fi

secret=$1
url=$2
key=$3
body=$4
t=${5:-$(date +%s)}

sig=$(printf '%s.%s' "$t" "$body" | openssl dgst -sha256 -hmac "$secret" | awk '{print $NF}')

curl -sS -w '\n[%{http_code}]\n' -X POST "$url" \
  -H 'content-type: application/json' \
  -H "x-supliful-signature: t=$t,v1=$sig" \
  -H "x-supliful-idempotency-key: $key" \
  --data-binary "$body"
