"""Handler tests against an in-memory stand-in for Table Storage.

These run with no Azure at all — `uv run --with pytest pytest` from app/orders — and
exist to catch the boring failures (a bad status code, a 500 where a 404 was meant)
before a deploy cycle does. The agent's behaviour depends on this API being precise
about failure, so the failure paths are what get the most coverage here.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("ORDERS_TABLE_ENDPOINT", "https://example.table.core.windows.net")
os.environ.setdefault("ORDERS_TABLE_NAME", "orders")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import azure.functions as func  # noqa: E402
from azure.core.exceptions import ResourceNotFoundError  # noqa: E402

import function_app  # noqa: E402


class FakeTable:
    def __init__(self) -> None:
        self.rows: dict[tuple[str, str], dict] = {}

    def get_entity(self, partition_key: str, row_key: str) -> dict:
        try:
            return dict(self.rows[(partition_key, row_key)])
        except KeyError:
            raise ResourceNotFoundError("not found") from None

    def query_entities(self, query, parameters=None, **_kwargs):
        parameters = parameters or {}
        if query.startswith("RowKey"):
            wanted = parameters["orderId"]
            return [dict(v) for k, v in self.rows.items() if k[1] == wanted]
        wanted = parameters["customerId"]
        return [dict(v) for k, v in self.rows.items() if k[0] == wanted]

    def create_entity(self, entity: dict) -> None:
        self.rows[(entity["PartitionKey"], entity["RowKey"])] = dict(entity)

    def update_entity(self, entity: dict, mode=None) -> None:
        self.rows[(entity["PartitionKey"], entity["RowKey"])] = dict(entity)


@pytest.fixture
def table(monkeypatch) -> FakeTable:
    fake = FakeTable()
    monkeypatch.setattr(function_app, "_table", lambda: fake)
    return fake


def _request(method: str, url: str, body=None, route_params=None, params=None):
    return func.HttpRequest(
        method=method,
        url=url,
        body=json.dumps(body).encode() if body is not None else b"",
        headers={"Content-Type": "application/json"},
        route_params=route_params or {},
        params=params or {},
    )


def _body(response) -> dict:
    return json.loads(response.get_body())


def _create(customer="acme", items=None, status=None):
    payload = {"customerId": customer, "items": items or [{"sku": "WIDGET-001", "quantity": 2}]}
    if status:
        payload["status"] = status
    return function_app.create_order(_request("POST", "/api/orders", payload))


def test_create_returns_201_and_a_server_issued_id(table):
    response = _create()
    assert response.status_code == 201

    order = _body(response)
    assert order["orderId"].startswith("ORD-")
    assert order["customerId"] == "acme"
    assert order["status"] == "pending"
    assert order["items"] == [{"sku": "WIDGET-001", "quantity": 2}]
    assert order["createdAt"] == order["updatedAt"]


def test_create_ignores_a_caller_supplied_order_id(table):
    response = function_app.create_order(
        _request(
            "POST",
            "/api/orders",
            {"customerId": "acme", "orderId": "ORD-MADEUP", "items": [{"sku": "X"}]},
        )
    )
    assert response.status_code == 201
    assert _body(response)["orderId"] != "ORD-MADEUP"


@pytest.mark.parametrize(
    "payload,expected_code",
    [
        ({"items": [{"sku": "X"}]}, "missing_field"),
        ({"customerId": "  ", "items": [{"sku": "X"}]}, "missing_field"),
        ({"customerId": "acme"}, "invalid_field"),
        ({"customerId": "acme", "items": []}, "invalid_field"),
        ({"customerId": "acme", "items": [{"sku": ""}]}, "invalid_field"),
        ({"customerId": "acme", "items": [{"sku": "X", "quantity": 0}]}, "invalid_field"),
        ({"customerId": "acme", "items": [{"sku": "X", "quantity": "two"}]}, "invalid_field"),
        ({"customerId": "acme", "items": [{"sku": "X"}], "status": "invented"}, "invalid_field"),
    ],
)
def test_create_rejects_bad_input_with_a_named_error(table, payload, expected_code):
    response = function_app.create_order(_request("POST", "/api/orders", payload))
    assert response.status_code == 400
    assert _body(response)["error"] == expected_code
    assert _body(response)["message"]


def test_get_reads_back_a_created_order(table):
    order_id = _body(_create())["orderId"]

    response = function_app.get_order(
        _request("GET", f"/api/orders/{order_id}", route_params={"orderId": order_id})
    )
    assert response.status_code == 200
    assert _body(response)["orderId"] == order_id


def test_get_uses_the_partition_when_the_customer_is_known(table):
    order_id = _body(_create())["orderId"]

    response = function_app.get_order(
        _request(
            "GET",
            f"/api/orders/{order_id}",
            route_params={"orderId": order_id},
            params={"customerId": "acme"},
        )
    )
    assert response.status_code == 200


def test_get_unknown_id_is_404_not_something_ambiguous(table):
    response = function_app.get_order(
        _request("GET", "/api/orders/ORD-NOPE", route_params={"orderId": "ORD-NOPE"})
    )
    assert response.status_code == 404

    body = _body(response)
    assert body["error"] == "order_not_found"
    assert body["orderId"] == "ORD-NOPE"


def test_list_requires_a_customer(table):
    response = function_app.list_orders(_request("GET", "/api/orders"))
    assert response.status_code == 400
    assert _body(response)["error"] == "missing_parameter"


def test_list_returns_only_that_customer_newest_first(table):
    _create(customer="acme", items=[{"sku": "A"}])
    _create(customer="acme", items=[{"sku": "B"}])
    _create(customer="globex", items=[{"sku": "C"}])

    response = function_app.list_orders(
        _request("GET", "/api/orders", params={"customerId": "acme"})
    )
    body = _body(response)
    assert body["count"] == 2
    assert {o["customerId"] for o in body["orders"]} == {"acme"}


def test_list_for_an_unknown_customer_is_an_empty_list_not_an_error(table):
    response = function_app.list_orders(
        _request("GET", "/api/orders", params={"customerId": "nobody"})
    )
    assert response.status_code == 200
    assert _body(response)["count"] == 0


def test_update_changes_status_and_bumps_updated_at(table):
    created = _body(_create())
    order_id = created["orderId"]

    response = function_app.update_order(
        _request(
            "PATCH",
            f"/api/orders/{order_id}",
            {"status": "confirmed"},
            route_params={"orderId": order_id},
        )
    )
    assert response.status_code == 200

    updated = _body(response)
    assert updated["status"] == "confirmed"
    assert updated["items"] == created["items"]


def test_update_rejects_fields_it_does_not_own(table):
    order_id = _body(_create())["orderId"]

    response = function_app.update_order(
        _request(
            "PATCH",
            f"/api/orders/{order_id}",
            {"createdAt": "2020-01-01T00:00:00+00:00"},
            route_params={"orderId": order_id},
        )
    )
    assert response.status_code == 400
    assert _body(response)["error"] == "unknown_field"


def test_update_unknown_id_is_404(table):
    response = function_app.update_order(
        _request(
            "PATCH",
            "/api/orders/ORD-NOPE",
            {"status": "shipped"},
            route_params={"orderId": "ORD-NOPE"},
        )
    )
    assert response.status_code == 404
    assert _body(response)["error"] == "order_not_found"
