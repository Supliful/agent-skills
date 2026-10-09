# Endpoints in detail

All under `https://public-api.supliful.com`. Auth header on everything except `/v1/ping`.
Shapes below are from the served OpenAPI spec (`GET /v1/openapi.json`).

## GET /v1/ping

No auth. `200 {"status": "ok", "servedAt": "<date-time>"}`. Liveness only.

## GET /v1/me

`200 {"connection": {"id": "<uuid>", "name": "string or null"}}`. Errors: 401, 403, 429.
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
| status | `active` or `discontinued` | Discontinued still resolves; a new order naming it is refused with 422 |
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

OrderLineInput: `productId` uuid from `/v1/products`, `quantity` integer 1..10000. There is no
retail price: an international parcel declares the merchant's cost as its customs value.

Responses:

- `201` new order, `200` the same request was already placed (idempotent replay). Both return `Order`:
  `{id, testMode, status, createdAt, externalOrderId, lines: [{productId, quantity}]}`.
  `id` is a UUID, or `test_`-prefixed for a test order. A replay returns the order as it stands
  now, so its `status` may have moved on since creation.
- `400` validation-failed (with `errors[]`): the body failed the schema, or neither key nor
  externalOrderId was sent
- `422` validation-failed: Supliful refuses the order. Tell the refusals apart this way:
  - `errors[].path` `lines.productId`, "… is not available to this connection": not exposed to you, or withdrawn
  - `errors[].path` `lines.productId`, "… is discontinued": Supliful no longer makes it. Stop offering it
  - `errors[].path` `shippingAddress`: the address would be rejected at label creation. One entry per issue; show them to the buyer
  - no `errors`, only `detail` "… exposed but cannot be fulfilled": the product has no fulfilment data yet. Retry later or ask the merchant
- `403` subscription-required: the merchant has no active Pro or Enterprise membership. Only this
  endpoint answers it, and not for `testMode` orders. `403` account-unavailable is the other 403;
  branch on `type`
- `409` order-already-exists (`orderId` of the existing order)
- `422` idempotency-key-reused (`orderId` the key already produced). Branch on `type` to tell it
  from validation-failed
- `401`, `429`

A real order is charged to the merchant at creation. If that charge fails, the order is held with
`payment_required` rather than refused.

## GET /v1/orders/{orderId}

Path `orderId` is Supliful's id **or** your `externalOrderId` (1..200), for test orders too.
Returns `OrderDetail`:

| Field | Type | Notes |
|---|---|---|
| id | string | |
| testMode | boolean | |
| externalOrderId | string or null | Null for orders the merchant placed another way |
| status | enum | `NEW`, `PROCESSING`, `ACCEPTED`, `IN_PROGRESS`, `COMPLETED`, `CANCELED`, `RETURNED` |
| onHold | boolean | Separate from status; a held order keeps its status |
| onHoldReasons | enum[] | `out_of_stock`, `payment_required`, `subscription_required`, `label_issue`, `invalid_address`, `customs_information_required`, `internal_review` |
| createdAt | date-time | |
| shippingAddress | object or null | Every field present: name, firstName, lastName, address1, city, zip, countryCode; company, phone, address2 and stateCode may be null |
| lines | OrderLine[] | `{id, productId, quantity, shipmentId or null}` |
| shipments | OrderShipment[] | Empty until the first parcel is prepared |

OrderShipment: `{id, status: pending|shipped|returned, trackingNumber or null, trackingUrl or null, createdAt, lineIds[]}`.
An order can ship in parts: compare `lineIds` against `lines` rather than assuming one shipment.
A shipment is created over the lines it carries, so `lineIds` names them.
A product can appear on more than one line (part of it covered by pre-paid units), so sum
`quantity` by `productId` rather than keying lines by product.
A parcel Supliful re-sends to replace a lost or damaged one appears in `shipments`, with `lineIds`
naming the lines it replaces, so a line can be in more than one shipment.

Errors: 401, 403, 404, 429. 404 `not-found` means no such order on this connection (or a test
order past its two hours).

### Status

| Status | Meaning | Cancelable |
|---|---|---|
| `NEW` | Placed, not yet accepted. Accepted automatically about two hours after creation | Yes |
| `PROCESSING` | Rare; the order requires additional review before it is accepted | No |
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
carries `testMode: true` and describes nothing that happened. For an order event, `orderId` is
echoed so you can match it; product events ignore it and carry a placeholder `productId`. Test ids
are not UUIDs, so do not validate webhook ids as UUIDs.

## POST /v1/test/orders/{orderId}/transitions

Only for `test_` orders. Body `{transition, reasons?, lineIds?, shipmentId?}` with transition one of
`process`, `accept`, `hold`, `releaseHold`, `ship`, `returnShipment`, `complete`, `cancel`.
`process` and `accept` only move status; the others also publish the matching webhook for real
(signed, logged, `data.testMode: true`). Returns `{order: OrderDetail, event, deliveries}`.

Rules the sandbox enforces:

- A test order is kept for **two hours** from creation, and transitions do not extend it. A 404
  after that is by design, not a bug.
- It starts `NEW` (or `PROCESSING` when a real order would require
  additional review) and stays there until you move it; it is never accepted by itself.
- `process` needs `NEW`; `accept` needs `NEW` or `PROCESSING`; `ship` is refused while the order is
  on hold; a settled order (completed, canceled, returned) only allows `returnShipment`. A
  transition that is not allowed answers `422 validation-failed`.
- `ship` takes `lineIds` (the `test_` line ids from the order) to rehearse a partial shipment; it
  defaults to every unshipped line.
- `returnShipment` takes `shipmentId`; it defaults to the most recent parcel still out.
- `hold` takes `reasons`; it defaults to `["out_of_stock"]`.
- `complete` is refused while any line has no shipment.
- `cancel` here mirrors Supliful canceling, from any unsettled state. To rehearse your own cancel
  with its real `NEW`-only rule, call `POST /v1/orders/{orderId}/cancel` instead.
- A test order is never charged and never fulfilled.
