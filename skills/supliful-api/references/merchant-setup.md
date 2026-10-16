# Merchant setup in the Supliful app

Everything the API can do starts in the merchant's Supliful account. If a call fails because
something is missing here, no code change fixes it: the merchant has to do it in the app.

## 1. Membership: Pro or Enterprise

API connections need a **Pro or Enterprise** membership. It is checked on every request, not
only at setup:

- Without an active membership the "Supliful API" card on the Stores page is disabled with
  "A Pro membership is required to use the Supliful API".
- If the membership lapses or is downgraded later, the keys are left untouched but
  `POST /v1/orders` answers `403 subscription-required`. Upgrading again restores it; no new key
  is needed.

Publishing products also needs a saved label, a payment method, a verified email, a connected
store and an active membership. Clicking **Publish** before they are done shows them as an
"Almost ready to publish" checklist.

## 2. Create the API connection and get the key

1. Open **Stores** and choose the **Supliful API** card ("Push orders for fulfillment via Supliful
   Public API").
2. Name the connection so it can be told apart from other stores, e.g. "Warehouse integration",
   and click **Create connection**.
3. The key is shown **once**. Copy it straight into the backend's secret store
   (`SUPLIFUL_API_KEY`). It cannot be shown again; a lost key means issuing a new one.

The connection then appears in the store list as "Connected", or "No active API key" when it
has none.

## 3. Manage keys

[Store list](https://supliful.com/stores) → the connection's menu → **Manage** → **API keys** tab:

- **New key**, give it a name of up to 32 characters (e.g. "Production", "Staging"), then
  **Create key**. A connection holds up to 5 keys. Each key has its own rate-limit counter, so
  give each workload its own key. The table shows name, created and last used.
- **Rotate key** (from the key's menu) issues a new key and revokes the old one **immediately**.
  Deploy the new value everywhere at once, or the old deploys start failing with 401.
- **Revoke key** stops a key immediately. Revoking the only enabled key stops all API requests for
  the connection until another is added.

## 4. Configure webhooks

Same **Manage** dialog → **Webhooks** tab:

1. **Add endpoint**, enter the receiver URL (`https://`, publicly resolvable) and click
   **Add webhook**.
2. Expand the endpoint's row to reveal or copy its **signing secret**, and store it in
   `SUPLIFUL_WEBHOOK_SECRETS`.
3. Verify the receiver with `POST /v1/test/webhooks` (see `webhooks.md`).

Per endpoint you can also:

- **Switch it off and on.** A switched-off endpoint receives nothing, and events raised meanwhile
  are not kept. It is also switched off automatically after three days without a successful
  delivery; switch it back on here, then reconcile open orders through the API.
- **Edit URL**, e.g. when a tunnel's hostname changes. Pending retries go to the new URL.
- **Rotate secret.** The previous secret keeps working for 24 hours, so deploy the new one within
  that window. Keep both in `SUPLIFUL_WEBHOOK_SECRETS` meanwhile.
- **Remove.** Stops delivery to the URL and deletes its delivery history.

The app does not yet let you choose event types: every endpoint receives all ten. Filter on
`type` in the receiver. It also has no delivery log or resend button yet, so log every delivery
you receive and reconcile with `GET /v1/orders/{orderId}` if you suspect one was missed.

## 5. Publish and unpublish products

A product is only visible to the connection, and orderable through it, while it is published to
that connection.

- **Publish:** open the product under **My Products** and click **Publish** (or **Published**
  if it is already live somewhere). The "Publish to stores" dialog lists every store; click
  **Publish** on the API connection's row. The partner receives `product.published`, and the
  product appears in `GET /v1/products`.
- **Unpublish:** in the same dialog, click **Unpublish** on the API connection's row and confirm.
  Only that store is affected. The partner receives `product.unpublished`;
  the product disappears from `GET /v1/products` and new orders naming it are refused with
  `422 validation-failed` on `lines.productId`. Existing orders stay readable.

A product can be live in several stores at once, the API connection among them, and each is
published or unpublished on its own. Editing a published product's name, description, SKU, retail
price or artwork sends `product.updated`.

## Checklist before the first real order

- [ ] Pro or Enterprise membership active
- [ ] API connection created, key stored as a backend secret
- [ ] `GET /v1/me` returns the connection
- [ ] Webhook endpoint added, secret stored, test delivery received and verified
- [ ] Products published to the connection and listed by `GET /v1/products`
- [ ] A `testMode: true` order walked through the sandbox transitions
