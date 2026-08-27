"""Orders REST API — the system of record the agent acts on.

Deliberately knows nothing about MCP, agents or models. APIM turns these four
operations into MCP tools (infra/lz-platform/orders.tf); from here they are an
ordinary HTTP API over Table Storage.

Validation is stricter than a demo strictly needs, and that is the point. A model
handed a vague API invents plausible-looking order ids the same way it invents
plausible-looking Homer quotations, and a 500 or an empty 200 lets the invention
stand. Every failure below names what was wrong and what was expected.
"""

from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any

import azure.functions as func
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.data.tables import TableClient, UpdateMode
from azure.identity import DefaultAzureCredential

logger = logging.getLogger("orders-api")

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

VALID_STATUSES = ("pending", "confirmed", "shipped", "delivered", "cancelled")
MAX_ITEMS = 50


@lru_cache(maxsize=1)
def _table() -> TableClient:
    # Read at call time rather than import time so a missing setting surfaces as a
    # request error with a stack trace, not a silent host startup failure.
    return TableClient(
        endpoint=os.environ["ORDERS_TABLE_ENDPOINT"],
        table_name=os.environ.get("ORDERS_TABLE_NAME", "orders"),
        credential=DefaultAzureCredential(),
    )


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _json(payload: Any, status: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload), status_code=status, mimetype="application/json"
    )


def _error(status: int, code: str, message: str, **extra: Any) -> func.HttpResponse:
    logger.info("Returning %s %s: %s", status, code, message)
    return _json({"error": code, "message": message, **extra}, status)


def _to_order(entity: dict) -> dict:
    """Table entity -> the JSON shape the OpenAPI definition promises."""
    return {
        "orderId": entity["RowKey"],
        "customerId": entity["PartitionKey"],
        "status": entity.get("status", "pending"),
        # `items` is stored as a JSON string: Table Storage has no list type, and
        # flattening to item0Sku/item0Qty columns would make the schema depend on the
        # largest order ever placed.
        "items": json.loads(entity.get("items", "[]")),
        "createdAt": entity.get("createdAt"),
        "updatedAt": entity.get("updatedAt"),
    }


def _validate_items(raw: Any) -> tuple[list[dict] | None, str | None]:
    """Return (items, error). Items are normalised to {sku, quantity}."""
    if not isinstance(raw, list) or not raw:
        return None, "'items' must be a non-empty array of {sku, quantity} objects."
    if len(raw) > MAX_ITEMS:
        return None, f"'items' must contain at most {MAX_ITEMS} entries."

    normalised = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            return None, f"items[{index}] must be an object with 'sku' and 'quantity'."

        sku = item.get("sku")
        if not isinstance(sku, str) or not sku.strip():
            return None, f"items[{index}].sku must be a non-empty string."

        quantity = item.get("quantity", 1)
        if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity < 1:
            return None, f"items[{index}].quantity must be an integer of 1 or more."

        normalised.append({"sku": sku.strip(), "quantity": quantity})

    return normalised, None


def _find(order_id: str, customer_id: str | None) -> dict | None:
    """Look an order up by id, using the partition key when the caller supplied it."""
    if customer_id:
        try:
            return _table().get_entity(partition_key=customer_id, row_key=order_id)
        except ResourceNotFoundError:
            return None

    # No customer id, so the partition is unknown and this is a cross-partition query.
    # Acceptable because order ids are unique and the table is small; if this ever
    # holds real volume, make customerId required on the read paths instead.
    matches = list(
        _table().query_entities(
            "RowKey eq @orderId", parameters={"orderId": order_id}, results_per_page=2
        )
    )
    return matches[0] if matches else None


@app.route(route="orders/{orderId}", methods=["GET"])
def get_order(req: func.HttpRequest) -> func.HttpResponse:
    order_id = req.route_params["orderId"]
    entity = _find(order_id, req.params.get("customerId"))

    if entity is None:
        # An explicit, machine-readable 404. The agent is instructed to report this
        # rather than answer around it, which only works if it is unambiguous.
        return _error(
            404,
            "order_not_found",
            f"No order with id '{order_id}' exists. Order ids are not guessable — "
            "look the order up with listOrders before asking for it by id.",
            orderId=order_id,
        )

    return _json(_to_order(entity))


@app.route(route="orders", methods=["GET"])
def list_orders(req: func.HttpRequest) -> func.HttpResponse:
    customer_id = req.params.get("customerId")
    if not customer_id or not customer_id.strip():
        return _error(
            400,
            "missing_parameter",
            "'customerId' is required. Ask the customer who they are rather than "
            "listing every order in the system.",
        )

    customer_id = customer_id.strip()
    entities = _table().query_entities(
        "PartitionKey eq @customerId", parameters={"customerId": customer_id}
    )
    orders = sorted(
        (_to_order(e) for e in entities),
        key=lambda o: o.get("createdAt") or "",
        reverse=True,
    )
    return _json({"customerId": customer_id, "count": len(orders), "orders": orders})


@app.route(route="orders", methods=["POST"])
def create_order(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return _error(400, "invalid_body", "Request body must be a JSON object.")

    if not isinstance(body, dict):
        return _error(400, "invalid_body", "Request body must be a JSON object.")

    customer_id = body.get("customerId")
    if not isinstance(customer_id, str) or not customer_id.strip():
        return _error(
            400, "missing_field", "'customerId' is required and must be a non-empty string."
        )
    customer_id = customer_id.strip()

    items, item_error = _validate_items(body.get("items"))
    if item_error:
        return _error(400, "invalid_field", item_error)

    status = body.get("status", "pending")
    if status not in VALID_STATUSES:
        return _error(
            400,
            "invalid_field",
            f"'status' must be one of {', '.join(VALID_STATUSES)}.",
        )

    # The server owns the identifier. A caller-supplied one would let a model hand back
    # an id it made up and have the system agree with it.
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    timestamp = _now()

    entity = {
        "PartitionKey": customer_id,
        "RowKey": order_id,
        "status": status,
        "items": json.dumps(items),
        "createdAt": timestamp,
        "updatedAt": timestamp,
    }

    try:
        _table().create_entity(entity)
    except ResourceExistsError:
        return _error(
            409, "order_exists", f"An order with id '{order_id}' already exists."
        )

    logger.info("Created order %s for customer %s", order_id, customer_id)
    return _json(_to_order(entity), status=201)


@app.route(route="orders/{orderId}", methods=["PATCH"])
def update_order(req: func.HttpRequest) -> func.HttpResponse:
    order_id = req.route_params["orderId"]

    try:
        body = req.get_json()
    except ValueError:
        return _error(400, "invalid_body", "Request body must be a JSON object.")

    if not isinstance(body, dict) or not body:
        return _error(
            400,
            "invalid_body",
            "Request body must be a JSON object with at least one of 'status' or 'items'.",
        )

    unknown = set(body) - {"status", "items", "customerId"}
    if unknown:
        return _error(
            400,
            "unknown_field",
            f"Cannot update {', '.join(sorted(unknown))}. Only 'status' and 'items' "
            "are updatable.",
        )

    entity = _find(order_id, body.get("customerId") or req.params.get("customerId"))
    if entity is None:
        return _error(
            404,
            "order_not_found",
            f"No order with id '{order_id}' exists, so there is nothing to update.",
            orderId=order_id,
        )

    if "status" in body:
        if body["status"] not in VALID_STATUSES:
            return _error(
                400,
                "invalid_field",
                f"'status' must be one of {', '.join(VALID_STATUSES)}.",
            )
        entity["status"] = body["status"]

    if "items" in body:
        items, item_error = _validate_items(body["items"])
        if item_error:
            return _error(400, "invalid_field", item_error)
        entity["items"] = json.dumps(items)

    entity["updatedAt"] = _now()
    _table().update_entity(entity, mode=UpdateMode.MERGE)

    logger.info("Updated order %s", order_id)
    return _json(_to_order(entity))
