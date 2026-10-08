# Endpoints in detail

All under `https://public-api.supliful.com`. Auth header on everything except `/v1/ping`.
Shapes below are from the served OpenAPI spec (`GET /v1/openapi.json`).

## GET /v1/ping

No auth. `200 {"status": "ok", "servedAt": "<date-time>"}`. Liveness only.

## GET /v1/me

`200 {"connection": {"id": "<uuid>", "name": "string"}}`. Errors: 401, 403, 429.
No side effects. Use it to validate a credential and to identify the connection when
contacting support (never send the key itself).

## GET /v1/products

Query: `limit` integer 1..100 (default 50), `cursor` string (opaque, from the previous page's
`nextCursor`), `sku` string filter.

```json
{
  "data": [ { ...Product } ],
  "nextCursor": "string or null"
}
```

Ordered oldest-exposed first. Errors: 400, 401, 403, 429.

## GET /v1/products/{id}

Path `id` is a UUID. Returns one `Product`. Errors: 400, 401, 403, 404, 429.

### Product

| Field | Type | Notes |
|---|---|---|
| id | uuid | Use this to order |
| name | string | |
| shortDescription | string | One-line summary for a tile |
| description | string | Full text for a product page |
| sku | string or null | Merchant's SKU, not unique |
| imageUrl | uri or null | May point at one of `mockupUrls` |
| mockupUrls | uri[] | Newest first, may be empty |
| dimensions | `{width, height, length, unit}` or null | unit: INCH, CENTIMETER, MILLIMETER. Outer container, for rating shipping |
| weight | `{value, unit}` or null | unit: OUNCE, POUND, GRAM, KILOGRAM |
| available | boolean | Snapshot, not a reservation. False means stop selling |
| status | `active` or `discontinued` | Discontinued still resolves; new orders refused |
| updatedAt | date-time | Changes when name, description, SKU or artwork change. Poll this to sync |

## POST /v1/orders

Headers: `Idempotency-Key` optional string 1..255. Body `CreateOrder`:

| Field | Type | Notes |
|---|---|---|
| externalOrderId | string 1..200, optional | Your id. Used as the idempotency key when the header is absent. Unique per connection |
| shippingAddress | OrderAddress, required | |
| lines | OrderLineInput[] 1..100, required | |
| testMode | boolean, optional | Creates a throwaway `test_` order. Omit for a real, charged order |

OrderAddress: `firstName`\*, `lastName`\* (1..100), `name` (1..200), `company` (..200), `phone` (..50),
`address1`\* (1..200), `address2` (..200), `city`\* (1..100), `stateCode` (..10), `zip`\* (1..20),
`countryCode`\* (exactly 2 chars). Starred fields are required.

OrderLineInput: `productId` uuid from `/v1/products`, `quantity` integer 1..10000.

Responses:

- `201` new order, `200` the same request was already placed (idempotent replay). Both return `Order`:
  `{id, testMode, status, createdAt, externalOrderId, lines: [{productId, quantity}]}`.
  `id` is a UUID, or `test_`-prefixed for a test order. A replay returns the order as it stands
  now, so its `status` may have moved on since creation.
- `400` validation-failed (with `errors[]`), or neither key nor externalOrderId sent. Beyond schema
  errors, three refusals come back this way; tell them apart by `errors[].path` and `message`:
  - `lines.productId`, "… is not available to this connection": not exposed to you, or withdrawn
  - `lines.productId`, "exposed but cannot currently be fulfilled": no working warehouse can take it
  - `shippingAddress`: the address would be rejected at label creation. One entry per issue; show them to the buyer
- `403` subscription-required: the merchant's plan does not include API ordering. Only this endpoint
  answers it. `403` account-unavailable is the other 403; branch on `type`
- `409` order-already-exists (`orderId` of the existing order)
- `422` idempotency-key-reused (`orderId` the key already produced)
- `401`, `429`

A real order is charged to the merchant at creation. If that charge fails, the order is held with
`payment_required` rather than refused.

## GET /v1/orders/{orderId}

Path `orderId` is Supliful's id **or** your `externalOrderId` (1..200). Returns `OrderDetail`:

| Field | Type | Notes |
|---|---|---|
| id | string | |
| testMode | boolean | |
| externalOrderId | string or null | Null for orders the merchant placed another way |
| status | enum | `NEW`, `PROCESSING`, `ACCEPTED`, `IN_PROGRESS`, `COMPLETED`, `CANCELED`, `RETURNED` |
| onHold | boolean | Separate from status; a held order keeps its status |
| onHoldReasons | enum[] | `out_of_stock`, `payment_required`, `subscription_required`, `label_issue`, `invalid_address`, `customs_information_required`, `internal_review` |
| createdAt | date-time | |
| shippingAddress | object or null | All fields present, nullable: name, firstName, lastName, company, phone, address1, address2, city, stateCode, zip, countryCode |
| lines | OrderLine[] | `{id, productId, quantity, shipmentId or null}` |
| shipments | OrderShipment[] | Empty until the first parcel is prepared |

OrderShipment: `{id, status: pending|shipped|returned, trackingNumber or null, trackingUrl or null, createdAt, lineIds[]}`.
An order can ship in parts: compare `lineIds` against `lines` rather than assuming one shipment.
A shipment is created over the lines it carries, so `lineIds` names them.

Errors: 401, 403, 404, 429.

### Status

| Status | Meaning | Cancelable |
|---|---|---|
| `NEW` | Placed, not yet accepted. Accepted automatically about two hours after creation | Yes |
| `PROCESSING` | An unusually large line quantity; waiting for Supliful to review and accept it | No |
| `ACCEPTED` | Accepted for fulfilment | No |
| `IN_PROGRESS` | A warehouse has it | No |
| `COMPLETED` | Every line shipped. Terminal | No |
| `CANCELED` | Canceled by you or by Supliful. Terminal | No |
| `RETURNED` | A shipment came back to the warehouse | No |

A held order keeps its status; `onHold` is independent of this table. An order whose payment
failed can also be canceled, whatever its status.

## POST /v1/orders/{orderId}/cancel

Path `orderId` is Supliful's id **or** your `externalOrderId`. No body. `200` returns the canceled
`OrderDetail`, and the merchant is refunded exactly as their own cancel button would. `order.canceled`
follows. Safe to retry: an order that is already canceled answers `200` again rather than an error.

Only an order that is still `NEW` (roughly its first two hours) or whose payment failed can be
canceled. Anything else is `409 order-not-cancelable`; its `orderStatus` member is the status the
order had when you asked, so refetch before deciding what to do. Send cancellations as soon as your
system decides on them: the window is measured from creation, not from your last request.

Errors: 401, 403, 404, 409, 429.

## POST /v1/test/webhooks

Body `{event: <one of the ten event types>, orderId?: string 1..200}`. `202 {"deliveries": n}`.
Delivers a real, signed, retried event to every enabled endpoint on the connection. The payload
carries `testMode: true` and describes nothing that happened. `orderId` is echoed so you can match it.

## POST /v1/test/orders/{orderId}/transitions

Only for `test_` orders. Body `{transition, reasons?, lineIds?, shipmentId?}` with transition one of
`process`, `accept`, `hold`, `releaseHold`, `ship`, `returnShipment`, `complete`, `cancel`.
`process` and `accept` only move status; the others also publish the matching webhook for real
(signed, logged, `data.testMode: true`). Returns `{order: OrderDetail, event, deliveries}`.

Rules the sandbox enforces:

- A test order is kept for **two hours** from creation, and transitions do not extend it. A 404
  after that is by design, not a bug.
- It stays `NEW` until you move it; unlike a real order it is never accepted by itself.
- `ship` takes `lineIds` to rehearse a partial shipment; it defaults to every unshipped line.
- `returnShipment` takes `shipmentId`; it defaults to the most recent parcel still out.
- `hold` takes `reasons`; it defaults to `["out_of_stock"]`.
- `complete` is refused while any line has no shipment.
- `cancel` here mirrors Supliful canceling, from any unsettled state. To rehearse your own cancel
  with its real `NEW`-only rule, call `POST /v1/orders/{orderId}/cancel` instead.
- A test order is never charged and never fulfilled.
