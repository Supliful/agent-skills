# Errors

Every error is an RFC 9457 problem document, `Content-Type: application/problem+json`:

```json
{
  "type": "https://developers.supliful.com/errors/<code>",
  "title": "Human title",
  "status": 401,
  "detail": "What to do",
  "instance": "/v1/me"
}
```

Take the code from the last path segment of `type`, and branch on it: a status can carry more than
one meaning. Both `account-unavailable` and `subscription-required` are 403; both
`order-already-exists` and `order-not-cancelable` are 409. Some types add members: `errors[]` on
validation-failed, `orderId` on order-already-exists and idempotency-key-reused, `orderStatus` on
order-not-cancelable. Parse defensively: a non-JSON body
(proxy error, HTML) should be wrapped into a synthetic problem rather than crashing.

| Code | HTTP | Meaning | Retry |
|---|---|---|---|
| invalid-api-key | 401 | No key, wrong scheme, unknown, revoked, expired, or key without a reachable connection. Deliberately indistinguishable. Response carries `WWW-Authenticate: Bearer realm="Supliful Public API"` | Never. Fix config |
| account-unavailable | 403 | Key is valid but the Supliful account behind it is disabled. Checked on every request; keys outlive account state | Not on a short interval. Human process, hours or days. Per account, not API wide |
| subscription-required | 403 | Key and account are fine, but the merchant's membership does not include placing orders through the API (needs Pro or Enterprise). Only `POST /v1/orders` answers it; reads and cancels keep working | Not until the merchant changes plan. Pause order submission and tell the merchant |
| order-not-cancelable | 409 | `POST /v1/orders/{orderId}/cancel` on an order past its window: accepted, under review (`PROCESSING`), or already with a warehouse. `orderStatus` is the status the order had when you asked | Never. Refetch the order and treat it as going ahead; to stop it, contact the merchant |
| validation-failed | 400 | Parameters did not match the schema. `errors: [{path, message}]` names every failing field, dot-joined paths, array indexes as `lines.0.quantity` | Never unmodified. Log `errors` |
| not-found | 404 | No route matches method and path. Returned before auth. `detail` names the method and path received | Never. Check `/v1` prefix, method, doubled slashes |
| order-already-exists | 409 | `externalOrderId` belongs to another order on this connection. `orderId` is that order | Never the same request. If it was a retry, adopt `orderId`; else use a new externalOrderId |
| idempotency-key-reused | 422 | Key already placed a different request. `orderId` is what it produced | Never. New key for a new order; identical payload for a retry |
| rate-limit-exceeded | 429 | 600 requests per 60 seconds per key, shared across processes. May carry `Retry-After` seconds | Yes, after `Retry-After` or exponential backoff from a few seconds |
| internal-error | 500 | Supliful's fault. No `detail` on purpose; full error is in their logs | 2 or 3 attempts with backoff, then stop. Verify state before retrying non-idempotent work |

## invalid-api-key checklist

1. Header is `Authorization: Bearer <key>` or `x-api-key: <key>`. Basic, bare tokens and empty Bearer count as no key.
2. No whitespace or newline pasted into the env var or config.
3. Key still enabled. Rotating disables the previous key immediately; an old deploy keeps failing while a new one works.
4. Connection still exists in Supliful.
5. `GET /v1/me` succeeds. If it does and your call does not, the problem is that request.

If all five pass, contact help@supliful.com with the `instance` path and the request time.

## What to send support for a 500

- `instance` from the response
- Time of the request with timezone
- The connection from `GET /v1/me`. Never the key
- Whether it reproduces, and the request shape if so

## Common causes of hitting 429 in normal operation

- Polling on a tight interval instead of reacting to webhooks
- Resubmitting work whose success was not recorded
- A retry loop with no backoff amplifying one failure

Each key has its own counter; requests made with a different key do not count toward this one.
