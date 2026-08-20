resource "random_id" "foundry" {
  byte_length = 6
}

data "azurerm_client_config" "current" {}

# CognitiveServices-based Foundry Hub (AIServices account)
resource "azurerm_cognitive_account" "foundry_hub" {
  name                          = "hub${random_id.foundry.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "hub${random_id.foundry.hex}"
  public_network_access_enabled = false

  identity {
    type = "SystemAssigned"
  }
}

# Enable project management on the Hub.
# This triggers Azure to provision a linked ML workspace, which is required
# before CognitiveServices projects and connections can be created.
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

# APIM gateway connection on the Hub — shared to all projects.
# Model reference in agent code: "apim-gateway/gpt-4o"
resource "azapi_resource" "apim_connection" {
  type      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name      = "apim-gateway"
  parent_id = azurerm_cognitive_account.foundry_hub.id

  depends_on = [azapi_update_resource.foundry_hub_enable_projects]

  body = {
    properties = {
      category      = "AzureOpenAI"
      target        = var.apim_gateway_url
      authType      = "ApiKey"
      credentials   = { key = var.apim_subscription_key }
      isSharedToAll = true
      metadata = {
        ApiType    = "Azure"
        ApiVersion = "2024-11-01-preview"
        Kind       = "AzureOpenAI"
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
