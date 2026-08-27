# Orders API

The system of record the agent acts on. An ordinary Python HTTP API over Table Storage,
running on Azure Functions Flex Consumption — it knows nothing about MCP, agents or
models. APIM is what turns its four operations into MCP tools
(`infra/lz-platform/orders.tf`), and keeping that knowledge out of here is the point of
the exercise.

| Operation | Route | Becomes the tool |
|---|---|---|
| `get-order` | `GET /api/orders/{orderId}` | `getOrder` |
| `list-orders` | `GET /api/orders?customerId=` | `listOrders` |
| `create-order` | `POST /api/orders` | `createOrder` |
| `update-order` | `PATCH /api/orders/{orderId}` | `updateOrder` |

`openapi.yaml` is the contract APIM imports. The `operationId` values in it are what the
MCP tools point at, so renaming one there breaks a tool in `orders.tf`.

## Table layout

One table, `orders`, in the shared content storage account:

| Column | Meaning |
|---|---|
| `PartitionKey` | customer id — so listing a customer's orders is a partition scan |
| `RowKey` | order id, `ORD-` plus eight hex characters, issued by this API |
| `status` | one of pending, confirmed, shipped, delivered, cancelled |
| `items` | JSON string of `[{sku, quantity}]` — Table Storage has no list type |
| `createdAt`, `updatedAt` | ISO 8601, UTC |

## Why the validation is heavier than it looks

A model handed a vague API invents plausible order ids the same way it invents plausible
Homer quotations, and a 500 or an empty 200 lets the invention stand. So:

- The server issues order ids. A caller-supplied one is ignored.
- A missing order is a 404 with `error: "order_not_found"`, never an empty 200.
- `customerId` is required on `listOrders`, so "show me the orders" cannot become a dump
  of the whole table.
- Every 400 names the field and what was expected.

The agent's instructions tell it to report these failures rather than answer around
them, which only works if they are unambiguous.

## Tests

No Azure needed — the table is stubbed:

```bash
cd app/orders
uv run --with pytest pytest tests -q
```

## Deploying

`.github/workflows/ordersdeploy.yml`, on the self-hosted runner — the Function App is
private-endpoint only, so neither the deployment endpoint nor the smoke test is
reachable from a public runner. The workflow exports `requirements.txt` from `uv.lock`
before publishing; it is deliberately not committed, because the Functions remote build
would silently prefer a stale committed copy over the lock.

## Poking at it by hand

From the jump host:

```bash
RG=rg<number>-lz01
FUNC=$(az functionapp list -g $RG --query "[?starts_with(name,'func')].name | [0]" -o tsv)
KEY=$(az functionapp keys list -g $RG -n $FUNC --query functionKeys.default -o tsv)
BASE="https://${FUNC}.azurewebsites.net/api"

curl -s -X POST "$BASE/orders" -H "x-functions-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"customerId":"acme-industries","items":[{"sku":"WIDGET-001","quantity":2}]}'

curl -s "$BASE/orders?customerId=acme-industries" -H "x-functions-key: $KEY"
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/orders/ORD-NOPE" -H "x-functions-key: $KEY"
```

The last one must print `404`. Through the gateway instead, swap the base URL for the
`orders_api_url` output of `infra/lz-platform` and the header for
`Ocp-Apim-Subscription-Key`.

Rows can also be read and seeded directly — the jump VM identity holds Storage Table
Data Contributor for exactly this:

```bash
az storage entity query --table-name orders --auth-mode login \
  --account-name $(az storage account list -g $RG --query "[0].name" -o tsv)
```
