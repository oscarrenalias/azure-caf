# The Orders API, and the MCP server generated from it.
#
# The gateway that already fronts the models fronts the system of record too. Nothing
# in the backend (infra/lz01/functions.tf, app/orders/) knows what MCP is: APIM reads
# the OpenAPI definition, and each operation named below becomes a tool an agent can
# call. That is the whole argument for putting the gateway here.
#
# lz-platform therefore depends on lz01, which already depends on lz-platform for the
# model gateway. The cycle is broken the same way `platform_foundry_name` breaks it in
# the other direction: a name copied into tfvars after the other stack applies, and
# everything here gated on it so a greenfield deploy still works.
#
#   1. apply hub -> 2. apply lz-platform (orders_function_name empty, skipped)
#   -> 3. apply lz01 -> copy `orders_function_name` output into config/lz-platform.tfvars
#   -> 4. apply lz-platform again

variable "orders_function_name" {
  type        = string
  description = "Name of the orders Function App in lz01 (func<hex>). Leave empty to skip the Orders API and MCP server entirely — the first apply of this stack, before lz01 exists, must do so."
  default     = ""
}

variable "orders_lz" {
  type        = string
  description = "The landing zone hosting the orders Function App, used to find its resource group."
  default     = "lz01"
}

locals {
  orders_enabled = var.orders_function_name != ""
  orders_rg      = "rg${var.number}-${var.orders_lz}"

  # The Function App's own hostname, not the gateway's. APIM is VNet-injected, so it
  # resolves this through the privatelink.azurewebsites.net zone to the private
  # endpoint in lz01 and routes there over the lz01 <-> lz-platform peering.
  orders_backend_url = "https://${var.orders_function_name}.azurewebsites.net/api"

  # Constructed rather than taken from azurerm_api_management_api.orders[0].id, which
  # carries a `;rev=1` suffix that is not valid inside an operation resource id.
  orders_api_id = "${azurerm_api_management.main.id}/apis/orders-api"
}

# Read over the management plane (Microsoft.Web/sites/host/listkeys), which works even
# though the Function App itself is private-endpoint only. That is what lets the key
# stay out of a GitHub secret: Terraform fetches it at plan time with the credentials it
# already has, rather than a human copying it between two stacks.
data "azurerm_function_app_host_keys" "orders" {
  count               = local.orders_enabled ? 1 : 0
  name                = var.orders_function_name
  resource_group_name = local.orders_rg
}

resource "azurerm_api_management_named_value" "orders_function_key" {
  count               = local.orders_enabled ? 1 : 0
  name                = "orders-function-key"
  resource_group_name = module.lz_data.rg.name
  api_management_name = azurerm_api_management.main.name
  display_name        = "orders-function-key"
  value               = data.azurerm_function_app_host_keys.orders[0].default_function_key
  secret              = true
}

resource "azurerm_api_management_backend" "orders" {
  count               = local.orders_enabled ? 1 : 0
  name                = "orders-api"
  resource_group_name = module.lz_data.rg.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = local.orders_backend_url
}

# The operations are imported from app/orders/openapi.yaml rather than declared here,
# so the contract has one definition. The operation ids in that file — get-order,
# list-orders, create-order, update-order — are what the MCP tools below point at, so
# renaming one there breaks a tool here.
resource "azurerm_api_management_api" "orders" {
  count                 = local.orders_enabled ? 1 : 0
  name                  = "orders-api"
  resource_group_name   = module.lz_data.rg.name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "Orders API"
  path                  = "orders-api"
  protocols             = ["https"]
  subscription_required = true
  service_url           = local.orders_backend_url

  import {
    content_format = "openapi"
    content_value  = file("${path.module}/../../app/orders/openapi.yaml")
  }
}

# The gateway holds the function key, so no caller ever sees it — the same swap the
# model API performs with a managed-identity token. Entra authentication on the Function
# App would be better and is the obvious next step; a function key is what keeps this
# stage to one moving part.
#
# set-backend-service is also what makes the routing authoritative: the OpenAPI import
# above carries a `servers:` entry, and whether APIM takes its service_url from the spec
# or from the argument, this policy overrides both with the named backend.
resource "azurerm_api_management_api_policy" "orders" {
  count               = local.orders_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.orders[0].name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = module.lz_data.rg.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-header name="x-functions-key" exists-action="override">
          <value>{{orders-function-key}}</value>
        </set-header>
        <set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
        <set-backend-service backend-id="orders-api" />
        <rate-limit calls="300" renewal-period="60" />
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML

  depends_on = [
    azurerm_api_management_named_value.orders_function_key,
    azurerm_api_management_backend.orders,
  ]
}

# A product of its own rather than reuse of ai-platform. The key issued here is the one
# that ends up in the Foundry project connection, and an orders key that can also spend
# model tokens would make that connection more powerful than it needs to be.
resource "azurerm_api_management_product" "orders" {
  count                 = local.orders_enabled ? 1 : 0
  product_id            = "orders"
  api_management_name   = azurerm_api_management.main.name
  resource_group_name   = module.lz_data.rg.name
  display_name          = "Orders"
  description           = "The orders system of record, as a REST API and as an MCP server."
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "orders_rest" {
  count               = local.orders_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.orders[0].name
  product_id          = azurerm_api_management_product.orders[0].product_id
  api_management_name = azurerm_api_management.main.name
  resource_group_name = module.lz_data.rg.name
}

resource "azurerm_api_management_subscription" "orders" {
  count               = local.orders_enabled ? 1 : 0
  api_management_name = azurerm_api_management.main.name
  resource_group_name = module.lz_data.rg.name
  product_id          = azurerm_api_management_product.orders[0].id
  display_name        = "Orders Default"
  state               = "active"
}

# ---------------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------------

# An APIM API of type "mcp". Streamable HTTP is served at <path>/mcp, so the endpoint
# an MCP client connects to is https://<apim>.azure-api.net/orders-mcp/mcp.
#
# schema_validation_enabled = false throughout: the azapi provider's bundled schema for
# Microsoft.ApiManagement predates the preview API version that introduced `mcp`, and it
# rejects the type and the tools sub-resource outright rather than passing them through.
resource "azapi_resource" "orders_mcp" {
  count     = local.orders_enabled ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2025-09-01-preview"
  name      = "orders-mcp"
  parent_id = azurerm_api_management.main.id

  schema_validation_enabled = false

  body = {
    properties = {
      type                 = "mcp"
      displayName          = "Orders MCP Server"
      description          = "The Orders API exposed as MCP tools."
      path                 = "orders-mcp"
      protocols            = ["https"]
      subscriptionRequired = true
    }
  }

  # Tools reference operations in the REST API, so it and its operations must exist.
  depends_on = [azurerm_api_management_api.orders]
}

# The tool descriptions below are the highest-leverage prose in this repository. They
# are what the model reads when deciding which tool to call, so they are written for it:
# what the tool does, when to reach for it, and what not to assume. The parameter-level
# guidance lives in app/orders/openapi.yaml, which supplies each tool's input schema.
locals {
  orders_tools = local.orders_enabled ? {
    getOrder = {
      operation   = "get-order"
      description = <<-EOT
        Look up one order by its id and return its status, items and dates.
        Use this when the user names a specific order. The id must be one that
        listOrders or createOrder returned — order ids are random and cannot be
        derived from a customer name or a date. If the order does not exist this
        returns 404; say so rather than describing an order that is not there.
      EOT
    }
    listOrders = {
      operation   = "list-orders"
      description = <<-EOT
        List every order belonging to one customer, newest first.
        Use this to find an order when the user does not know its id, and before
        getOrder or updateOrder whenever the id is uncertain. Requires the customer
        id — ask the user for it rather than guessing. An empty list is a valid
        answer meaning the customer has no orders.
      EOT
    }
    createOrder = {
      operation   = "create-order"
      description = <<-EOT
        Place a new order for a customer and return it, including the id this API
        issues. WRITES TO THE SYSTEM OF RECORD. Before calling it, make sure you have
        the customer id and every item with its product code and quantity, then
        restate the whole order to the user and get an explicit yes. Do not supply an
        order id; one is generated. Do not call this to check whether an order exists.
      EOT
    }
    updateOrder = {
      operation   = "update-order"
      description = <<-EOT
        Change the status or the items of an existing order and return the result.
        WRITES TO THE SYSTEM OF RECORD. Only status and items can be changed, and only
        the fields you supply are touched. Confirm the exact change with the user, in
        words, before calling it. Verify the order id with listOrders or getOrder
        first: an id that does not exist returns 404 and nothing is changed.
      EOT
    }
  } : {}
}

resource "azapi_resource" "orders_mcp_tool" {
  for_each  = local.orders_tools
  type      = "Microsoft.ApiManagement/service/apis/tools@2025-09-01-preview"
  name      = each.key
  parent_id = azapi_resource.orders_mcp[0].id

  schema_validation_enabled = false

  body = {
    properties = {
      displayName = each.key
      description = trimspace(each.value.description)
      # The full resource id of the backing operation, not just its name.
      operationId = "${local.orders_api_id}/operations/${each.value.operation}"
    }
  }
}

# Policies at MCP scope run on every tool invocation. The rate limit is lower than the
# REST API's: a model in a loop is a more plausible source of runaway calls than a
# human-written client is.
resource "azapi_resource" "orders_mcp_policy" {
  count     = local.orders_enabled ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview"
  name      = "policy"
  parent_id = azapi_resource.orders_mcp[0].id

  schema_validation_enabled = false

  body = {
    properties = {
      format = "rawxml"
      value  = "<policies><inbound><base /><rate-limit calls=\"60\" renewal-period=\"60\" /></inbound><backend><forward-request /></backend><outbound><base /></outbound></policies>"
    }
  }

  depends_on = [azapi_resource.orders_mcp_tool]
}

resource "azapi_resource" "orders_mcp_product_binding" {
  count     = local.orders_enabled ? 1 : 0
  type      = "Microsoft.ApiManagement/service/products/apis@2025-09-01-preview"
  name      = "orders-mcp"
  parent_id = "${azurerm_api_management.main.id}/products/${azurerm_api_management_product.orders[0].product_id}"

  schema_validation_enabled = false

  body = {}

  depends_on = [azapi_resource.orders_mcp]
}

output "orders_api_url" {
  value       = local.orders_enabled ? "https://${azurerm_api_management.main.name}.azure-api.net/orders-api" : ""
  description = "Base URL of the Orders REST API through the gateway. Call it with the orders subscription key as Ocp-Apim-Subscription-Key."
}

output "orders_mcp_url" {
  value       = local.orders_enabled ? "https://${azurerm_api_management.main.name}.azure-api.net/orders-mcp/mcp" : ""
  description = "Streamable HTTP MCP endpoint. Use as --target when creating the Foundry project connection (see app/toolbox/README.md)."
}

output "orders_subscription_key" {
  value       = local.orders_enabled ? azurerm_api_management_subscription.orders[0].primary_key : ""
  sensitive   = true
  description = "Subscription key for the orders product, for both the REST API and the MCP server."
}
