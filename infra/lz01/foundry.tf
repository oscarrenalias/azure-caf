resource "random_id" "foundry" {
  byte_length = 6
}

data "azurerm_client_config" "current" {}

resource "azurerm_cognitive_account" "foundry_hub" {
  name                          = "hub${random_id.foundry.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "hub${random_id.foundry.hex}"
  public_network_access_enabled = true
  project_management_enabled    = true

  # Deny by default, with two exceptions:
  #  - allowed_ips: developer workstations, for local `azd ai agent run`
  #  - bypass AzureServices: required by the Agent Service platform itself. A hosted
  #    agent's request is orchestrated platform-side (FoundryStorageProvider writes
  #    the response before the container is invoked) from Microsoft-managed compute
  #    outside this VNet, so without the bypass every hosted invocation fails with a
  #    500 that never reaches the container. Verified: with the bypass a hosted
  #    invoke completes; without it, the container logs show no inbound request.
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.allowed_ips
  }

  identity {
    type = "SystemAssigned"
  }
}

# azapi_update_resource kept intentionally: removing it causes the provider to
# revert allowProjectManagement to false via a DELETE-time PATCH.
# project_management_enabled = true on the account above is the stable source
# of truth; this resource is now a harmless no-op.
resource "azapi_update_resource" "foundry_hub_enable_projects" {
  type        = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  resource_id = azurerm_cognitive_account.foundry_hub.id

  body = {
    properties = {
      allowProjectManagement = true
    }
  }
}

# Project under the Hub — Agent Service runs here
resource "azapi_resource" "foundry_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = "proj${random_id.foundry.hex}"
  parent_id = azurerm_cognitive_account.foundry_hub.id
  location  = module.lz_data.rg.location

  depends_on = [azapi_update_resource.foundry_hub_enable_projects]

  body = {
    properties = {}
    identity = {
      type = "SystemAssigned"
    }
  }

  response_export_values = ["*"]

  lifecycle {
    ignore_changes = [body, output]
  }
}

# APIM AI Gateway connection on the project — the "connected mode" link that lets
# agents here consume the shared models in the platform LZ.
#
# Foundry treats an APIM gateway as a ModelGateway connection, which is a different
# shape from an "AzureOpenAI" connection to a Cognitive Services account:
#   - category must be "ApiManagement"
#   - metadata must declare how the gateway routes (deploymentInPath) and which
#     models it exposes (static "models" list, or modelDiscovery endpoints)
# With the wrong category or without model info, the Responses API cannot resolve
# "apim-gateway/<deployment>" and fails with "Connection 'apim-gateway' not found".
# Schema: foundry-samples/infrastructure/infrastructure-setup-bicep/01-connections/apim
#
# Model reference in agent code: "apim-gateway/gpt-4o"
resource "azapi_resource" "apim_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = "apim-gateway"
  parent_id = azapi_resource.foundry_project.id

  body = {
    properties = {
      category      = "ApiManagement"
      target        = var.apim_gateway_url
      authType      = "ApiKey"
      credentials   = { key = var.apim_subscription_key }
      isSharedToAll = true
      metadata = {
        # The gateway is a passthrough, so inference URLs keep the Azure OpenAI
        # shape: <target>/deployments/<deployment>/chat/completions
        deploymentInPath    = "true"
        inferenceAPIVersion = "2024-10-21"

        # Static model list — mirrors the deployments on the platform LZ Foundry
        # (infra/lz-platform/aifoundry.tf). Static discovery avoids having to add
        # ARM-backed /deployments operations to the APIM API. Must be a JSON string.
        models = jsonencode([
          {
            name = "gpt-4o"
            properties = {
              model = {
                name    = "gpt-4o"
                version = "2024-11-20"
                format  = "OpenAI"
              }
            }
          },
          {
            name = "text-embedding-3-small"
            properties = {
              model = {
                name    = "text-embedding-3-small"
                version = "1"
                format  = "OpenAI"
              }
            }
          },
        ])
      }
    }
  }

  # Azure masks secrets in GET responses, so body always drifts on credential fields.
  lifecycle {
    ignore_changes = [body]
  }
}

data "azurerm_private_dns_zone" "cognitive_services" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = "rg${var.number}-${var.hub}"
}

data "azurerm_private_dns_zone" "openai" {
  name                = "privatelink.openai.azure.com"
  resource_group_name = "rg${var.number}-${var.hub}"
}

data "azurerm_private_dns_zone" "ai_services" {
  name                = "privatelink.services.ai.azure.com"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_private_endpoint" "foundry_hub" {
  name                = "pe-hub${random_id.foundry.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-hub${random_id.foundry.hex}"
    private_connection_resource_id = azurerm_cognitive_account.foundry_hub.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "privatelink-hub"
    private_dns_zone_ids = [
      data.azurerm_private_dns_zone.cognitive_services.id,
      data.azurerm_private_dns_zone.openai.id,
      data.azurerm_private_dns_zone.ai_services.id,
    ]
  }
}

output "foundry_project_name" {
  value = azapi_resource.foundry_project.name
}

output "foundry_project_id" {
  value = azapi_resource.foundry_project.id
}

output "foundry_project_rg" {
  value = module.lz_data.rg.name
}

output "foundry_hub_name" {
  value = azurerm_cognitive_account.foundry_hub.name
}
