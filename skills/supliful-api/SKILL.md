---
name: supliful-api
description: Integrate the Supliful public API (products, orders, webhooks) into a merchant or partner system. Use when writing code that lists Supliful products, places or reads orders, receives Supliful webhooks, handles its RFC 9457 errors, or when the user mentions Supliful, `public-api.supliful.com`, `x-supliful-signature`, or an API connection key.
---

# Supliful public API

Base URL: read it from `SUPLIFUL_BASE_URL`, never hard-code it. The API is
`https://public-api.supliful.com`; the docs live at `https://developers.supliful.com`, which is
also the host of every error `type` URL.
The API serves its own OpenAPI spec at `GET /v1/openapi.json` with no key. Always read it from
there, `https://public-api.supliful.com/v1/openapi.json`, rather than from a saved copy.

Every endpoint is under `/v1`. Errors are RFC 9457 problem documents (`application/problem+json`).

## Workflow

0. **Check the merchant side is set up** (`references/merchant-setup.md`): a Pro or Enterprise
   membership, an API connection with a key, a webhook endpoint with its secret, and products
   published to the connection. None of these can be done through the API.
1. **Put credentials in backend env vars and gitignore them** before anything else (see
   Secrets below). Then generate types from the spec rather than hand-writing request and response shapes.
   TypeScript: `openapi-typescript https://public-api.supliful.com/v1/openapi.json -o supliful/openapi.d.ts`.
2. **Wrap the API in one client** with: bearer auth, problem-document parsing, retry policy
   (below), and a log of every request and response, with the `Authorization` header redacted.
   The log is what makes a failing integration diagnosable; Supliful support asks for
   `instance` and the request time.
3. **Verify the credential first** with `GET /v1/me`. It has no side effects and returns the
   connection the key acts as. If it works and another call fails, the bug is in that call.
4. **Build the webhook receiver before placing orders**, and prove it with
   `POST /v1/test/webhooks` (see `references/webhooks.md`).
5. **Place orders idempotently**, then read them back with `GET /v1/orders/{id}`.

## Authentication

Send `Authorization: Bearer <key>`. `x-api-key: <key>` is also accepted. Anything else
(Basic, bare token, empty Bearer) counts as no key and returns 401 `invalid-api-key`.
A key belongs to one API connection; rotating it disables the old key immediately.

## Secrets: backend only, never committed

The API key and the webhook endpoint secret are credentials for the merchant's account.
An order placed with the key is a real order, charged to the merchant when it is created.

- **Server side only.** Read them from environment variables in the backend. Never put them in
  frontend code, a bundle, a public config, or a URL. A browser must never call the API directly.
- **Never commit them.** Keep real values in a gitignored `.env` (or the host's secret store) and
  commit only a `.env.example` with empty values. Before writing any file, check `.gitignore`
  covers `.env`, `.env.*` and any local secrets file. If one is missing, add it first.
- **Never print them.** Do not log the key, echo it in a shell command, paste it in chat, or
  include it in an error message, request log, or bug report. Log the connection from
  `GET /v1/me` instead when you need to identify which credential was used.
- **Never hard-code a fallback.** No default key in code, tests, or fixtures. Missing
  `SUPLIFUL_API_KEY` should fail loudly at startup, not silently use something.
- **If a key was exposed** (committed, logged, pasted), rotate it in the Supliful app right away.
  Rotation disables the old key immediately, so update every running deploy at the same time.

Suggested variables, read once at startup:

```
SUPLIFUL_BASE_URL=https://public-api.supliful.com
SUPLIFUL_API_KEY=
SUPLIFUL_WEBHOOK_SECRETS=          # comma separated; two values during a rotation
```

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/ping` | No auth. `{status, servedAt}` |
| GET | `/v1/me` | `{connection: {id, name or null}}` |
| GET | `/v1/products` | `limit` 1..100 (default 50), `cursor`, `sku`. Returns `{data, nextCursor}` |
| GET | `/v1/products/{id}` | UUID. The only way to fetch exactly one product |
| POST | `/v1/orders` | 201 created, 200 when the idempotent retry returned the existing order |
| GET | `/v1/orders/{orderId}` | Accepts Supliful's id **or** your `externalOrderId` |
| POST | `/v1/orders/{orderId}/cancel` | Same id forms. Only while `NEW` or after a failed payment; the merchant is refunded |
| POST | `/v1/test/webhooks` | Sends a signed test delivery with `testMode: true` |
| POST | `/v1/test/orders/{orderId}/transitions` | Only for `test_` orders created with `testMode: true` |

Field-level detail: `references/endpoints.md`.

## Rules that are easy to get wrong

- **Cursor pagination only.** Never page by offset. `nextCursor` is opaque; null on the last page.
  A product published mid-sync can land on a later page or the next pass. `product.published` tells you sooner.
- **`sku` is a filter, not a lookup.** Two products may share a SKU, so `?sku=` returns a list.
  Never assume `data[0]`. Use the UUID to fetch one product.
- **`available: false` or `status: "discontinued"` means stop selling.** Discontinued products still
  resolve so open orders stay readable, but a new order naming one is refused with 422.
- **Ordering unknown product ids is not discovery.** A product the merchant has not exposed to
  your connection is refused the same way as a nonexistent one.
- **Every order needs an idempotency key.** Send `Idempotency-Key` (1..255 chars) or `externalOrderId`
  (1..200 chars, used as the key when the header is absent). Neither present is a 400.
  Keep the key stable across retries, or a retry becomes a duplicate order.
- **A key is bound to one payload.** Same key, different lines/address/externalOrderId is
  422 `idempotency-key-reused` with the original `orderId`. Field order does not matter; values do.
- **`externalOrderId` is unique per connection.** Reusing it under a new key is 409
  `order-already-exists` with the existing `orderId`. Both conflicts tell you which order exists: adopt it.
- **A replay returns the order as it stands now**, not as it was when first created. Reconcile from it.
- **Ordering needs the right membership.** `POST /v1/orders` answers 403 `subscription-required` when
  the merchant has no active Pro or Enterprise membership. Every other call keeps working, and
  `testMode` orders skip the check. `account-unavailable` is also 403, so branch on the problem
  `type`, never on status alone.
- **`validation-failed` is 400 for a malformed request and 422 for an order Supliful refuses.**
  400: the body or query failed the schema, or neither idempotency key was sent. 422 (order-time):
  `errors[].path` `lines.productId` "not available to this connection" means not exposed or
  withdrawn, "is discontinued" means Supliful no longer makes it; `shippingAddress` means the address would fail at label creation (show it to the
  buyer); a 422 with no `errors`, only `detail`, means the product exists but cannot be fulfilled
  yet. Treat the 422s as a decision about the order, not a bug in your request.
- **Prices are the merchant's.** Your retail price never reaches Supliful; the order carries no shipping cost.
  A product's `retailPrice` is the merchant's suggested consumer price (USD), not what Supliful charges.
- **Tracking mail goes to the merchant's account email.** To inform the buyer, pass on
  `trackingUrl` from each shipment (`GET /v1/orders/{orderId}` and `order.shipmentCreated`).
- **A held order keeps its status.** Read `onHold` and `onHoldReasons` separately from `status`.
  `payment_required` appears because a real order is charged at creation.
- **Know the lifecycle.** `NEW` is accepted automatically about two hours after creation, and that
  window is the only time you can cancel. `PROCESSING` is rare and means the order requires
  additional review; it cannot be canceled through the API. `ACCEPTED` then
  `IN_PROGRESS` (a warehouse has it), ending in `COMPLETED`, `CANCELED` or `RETURNED`. See
  `references/endpoints.md` for what each means to your system.
- **Rate limit is 600 requests per 60 seconds per key**, shared across all your processes. A second key
  gets its own counter. Honour `Retry-After` on 429.

## Retry policy

| Status | Action |
|---|---|
| 429 | Wait `Retry-After` seconds (exponential backoff from a few seconds if absent), then retry |
| 500 | Retry 2 or 3 times with backoff, then stop and surface it. Never retry indefinitely |
| 403 `subscription-required` | Terminal until the merchant changes plan. Stop placing orders; reads still work |
| 403 `account-unavailable` | Terminal for hours or days. Stop all calls for that account and alert a person |
| 409 `order-not-cancelable` | Terminal. Refetch the order; it has moved past its cancel window |
| 400, 401, 404, 409, 422 | Terminal. Fix the request or configuration; do not retry unmodified |

Branch on status first, then on the problem `type` where one status has several meanings (403, 409,
422):
429 means the credential is fine, 401 means stop and fix configuration.
Full catalogue of problem types, fields and fixes: `references/errors.md`.

## Webhooks

Ten event types: `order.created`, `order.canceled`, `order.onHold`, `order.onHoldReleased`,
`order.shipmentCreated`, `order.shipmentReturned`, `order.completed`, `product.published`,
`product.unpublished`, `product.updated`. Every payload is `{type, occurredAt, data}`.

Non-negotiables for a receiver:

1. Verify `x-supliful-signature` over the **raw request bytes** (never re-serialised JSON).
2. Deduplicate on `x-supliful-idempotency-key`; it is stable across retries of one delivery.
3. Deliveries are unordered. Sort by `occurredAt`, or better, treat every order event as a
   trigger to refetch `GET /v1/orders/{id}` and reconcile from that.
4. Answer 2xx fast, then process. Supliful retries 5xx, 408, 429 and connection failures;
   any other 4xx is treated as permanent.
5. Ignore payloads with `data.testMode: true` for state changes; they describe nothing real.
   Real deliveries carry `testMode: false`.
6. Register an `https://`, publicly resolvable URL, answer within 10 seconds, and do not redirect.
   An endpoint is switched off after three days without a successful delivery, and events raised
   while it is off are not kept: reconcile with `GET /v1/orders/{id}` after switching it back on.
   Filter on `type`. Operating limits: `references/webhooks.md`.

Signature format, verification code, per-event payloads and what to do with each event:
`references/webhooks.md`. To exercise a local receiver without Supliful, sign and send a
delivery with `scripts/sign-webhook.sh`.
