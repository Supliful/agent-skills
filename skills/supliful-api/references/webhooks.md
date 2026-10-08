# Webhooks

Supliful POSTs JSON to the endpoint registered on the connection. Two headers matter:

| Header | Meaning |
|---|---|
| `x-supliful-signature` | `t=<unix seconds>,v1=<hex>[,v1=<hex>...]`. HMAC-SHA256 over `${t}.${rawBody}` keyed by the endpoint secret. During a secret rotation there is one `v1=` per live secret; match any |
| `x-supliful-idempotency-key` | Stable across every retry of one delivery. Deduplicate on it |

Reject a `t` older than 300 seconds. Respond with any 2xx to acknowledge. Supliful retries
5xx, 408, 429 and connection failures with backoff; any other 4xx is treated as permanent.

## Operating limits

| Topic | Behaviour |
|---|---|
| Endpoint URL | Must be `https://` and publicly resolvable. A private-network address is refused when saved and again at delivery |
| Event selection | Not configurable in the app yet: every endpoint receives all ten types. Filter on `type` |
| Secrets | One per endpoint; two connections never share one. During rotation the retired secret keeps working for **24 hours**, which is your window to redeploy |
| Retries | For about **three days**, waiting longer each time, from a minute up to a day. Every attempt repeats the same body and idempotency key |
| Dead endpoint | An endpoint with no accepted delivery for **three days** is disabled. Switch it back on in the app once the URL works; nothing is delivered while it is off |
| Delivery log | Supliful records every attempt for **30 days**, but the app has no log view or resend button yet. Keep your own log of deliveries received |
| Setup | Adding, editing, switching off, rotating and removing endpoints: `merchant-setup.md` |

## Verification

Compute over the exact bytes received. Frameworks that parse JSON before your handler runs
will break the signature; capture the raw body (Fastify: a custom content type parser with
`parseAs: "string"`; Express: `express.raw()` or the `verify` callback of `express.json()`).

```ts
import { createHmac, timingSafeEqual } from "node:crypto";

export function verifySupliful(rawBody: string, header: string | undefined, secrets: string[], now = Date.now() / 1000) {
  if (!header) return false;
  let t: number | undefined;
  const sigs: string[] = [];
  for (const part of header.split(",")) {
    const [k, v] = part.trim().split("=", 2);
    if (k === "t") t = Number(v);
    else if (k === "v1" && v) sigs.push(v.toLowerCase());
  }
  if (!t || !Number.isFinite(t) || sigs.length === 0) return false;
  if (Math.abs(now - t) > 300) return false;
  const payload = `${t}.${rawBody}`;
  return secrets.some((secret) => {
    const expected = createHmac("sha256", secret).update(payload).digest("hex");
    return sigs.some((s) => s.length === expected.length && timingSafeEqual(Buffer.from(s, "hex"), Buffer.from(expected, "hex")));
  });
}
```

Python equivalent: `hmac.new(secret.encode(), f"{t}.{raw}".encode(), hashlib.sha256).hexdigest()`
compared with `hmac.compare_digest`.

## Receiver shape

1. Read raw body, headers.
2. Verify signature. On failure store the delivery for debugging and respond 401 (permanent).
3. Look up the idempotency key. Seen before with a valid signature: respond 200, do nothing.
   A previously rejected delivery must not block a later valid retry with the same key.
4. Store the event, respond 200.
5. Process after the response. Record the outcome on the stored event so it can be replayed.

## Payloads

Every event: `{ "type": "<event>", "occurredAt": "<date-time>", "data": {...} }`.
Test deliveries, from `POST /v1/test/webhooks` or a sandbox transition, carry `data.testMode: true`.
Real deliveries carry `data.testMode: false`.

| Event | `data` | Meaning |
|---|---|---|
| order.created | `orderId`, `externalOrderId` | Order accepted for this connection |
| order.canceled | `orderId`, `externalOrderId` | Cancelled before it shipped |
| order.onHold | `orderId`, `externalOrderId`, `reasons[]` | Blocked. A later hold arrives as another event |
| order.onHoldReleased | `orderId`, `externalOrderId` | Moving again, whether cleared itself or resolved by a person |
| order.shipmentCreated | `orderId`, `externalOrderId`, `shipmentId`, `trackingNumber`, `trackingUrl` | A parcel left the warehouse. Not order completion; several per order possible |
| order.shipmentReturned | same as above | A parcel came back |
| order.completed | `orderId`, `externalOrderId` | Every line fulfilled |
| product.published | `productId`, `sku` | Merchant exposed the product; orderable from now |
| product.unpublished | `productId`, `sku` | Withdrawn; orders naming it will be rejected |
| product.updated | `productId`, `sku` | Name, description, SKU or artwork changed. Payload does not say which; refetch |

Order events are only sent for orders placed through your connection. `externalOrderId` is the
value you sent, or null when you placed the order with only an `Idempotency-Key`.
`POST /v1/test/webhooks` always sends `externalOrderId: null` with placeholder ids that resolve to
nothing. Match on `orderId` first, then `externalOrderId`.

## What to do with each event

Order events: payloads are deliberately thin. Apply what the payload carries immediately
(hold reasons, shipment tracking) so users see it even if the refetch fails, then call
`GET /v1/orders/{orderId}` and reconcile status, `onHold`, lines and shipments from it.
Because you reconcile from the source of truth, out-of-order delivery is harmless.

Derive your local status from Supliful's: `CANCELED`, `RETURNED`, `COMPLETED` are terminal;
otherwise count lines covered by shipments with status `shipped` to get shipped versus
partially shipped (every shipment names its lines in `lineIds`); otherwise
`ACCEPTED`/`IN_PROGRESS` is accepted and `NEW`/`PROCESSING` is submitted.

Product events:
- `product.published`: fetch the product, create or reactivate your local record. If your
  system prices products, create it unpriced and hidden until someone prices it.
- `product.updated`: fetch and refresh name, description, SKU, images. Keep your own price.
  Hide it if `status` became `discontinued` or `available` is false.
- `product.unpublished`: hide it and refuse it at checkout. Do not delete: existing orders reference it.

## Testing a receiver

Without Supliful: `scripts/sign-webhook.sh <secret> <url> <idempotency-key> '<json>'` signs
and posts a delivery. Test dedupe by sending the same key twice, staleness by passing an old
timestamp as the fifth argument, and rejection by signing with the wrong secret.

With Supliful: `POST /v1/test/webhooks {"event": "order.created"}` sends a real signed
delivery carrying `data.testMode: true`. Your handler should log it and change nothing. It only
reaches endpoints subscribed to that event type.
