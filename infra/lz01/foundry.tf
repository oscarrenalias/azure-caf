resource "random_id" "foundry" {
  byte_length = 6
}

data "azurerm_client_config" "current" {}

resource "azurerm_storage_account" "foundry" {
  name                     = "st${random_id.foundry.hex}"
  location                 = module.lz_data.rg.location
  resource_group_name      = module.lz_data.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_key_vault" "foundry" {
  name                = "kv${random_id.foundry.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

# Foundry Hub — workload-owned. No model deployments; models are accessed via the APIM connection.
resource "azurerm_machine_learning_workspace" "hub" {
  name                = "hub${random_id.foundry.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  kind                = "Hub"
  storage_account_id  = azurerm_storage_account.foundry.id
  key_vault_id        = azurerm_key_vault.foundry.id

  identity {
    type = "SystemAssigned"
  }
}

# Foundry Project — Agent Service runs here.
resource "azurerm_machine_learning_workspace" "project" {
  name                = "proj${random_id.foundry.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  kind                = "Project"
  workspace_hub_id    = azurerm_machine_learning_workspace.hub.id

  identity {
    type = "SystemAssigned"
  }
}

# APIM connection on the Hub — shared to all projects.
# Model reference in agent code: "apim-gateway/gpt-4o"
resource "azapi_resource" "apim_connection" {
  type      = "Microsoft.MachineLearningServices/workspaces/connections@2024-10-01"
  name      = "apim-gateway"
  parent_id = azurerm_machine_learning_workspace.hub.id

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
}

data "azurerm_private_dns_zone" "cognitive_services" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = "rg${var.number}-${var.hub}"
}

data "azurerm_private_dns_zone" "openai" {
  name                = "privatelink.openai.azure.com"
  resource_group_name = "rg${var.number}-${var.hub}"
}

data "azurerm_private_dns_zone" "ml_api" {
  name                = "privatelink.api.azureml.ms"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_private_endpoint" "foundry_hub" {
  name                = "pe-hub${random_id.foundry.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-hub${random_id.foundry.hex}"
    private_connection_resource_id = azurerm_machine_learning_workspace.hub.id
    subresource_names              = ["amlworkspace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-hub"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.ml_api.id]
  }
}

resource "azurerm_private_endpoint" "foundry_project" {
  name                = "pe-proj${random_id.foundry.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-proj${random_id.foundry.hex}"
    private_connection_resource_id = azurerm_machine_learning_workspace.project.id
    subresource_names              = ["amlworkspace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-proj"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.ml_api.id]
  }
}

output "foundry_project_name" {
  value = azurerm_machine_learning_workspace.project.name
}

output "foundry_project_rg" {
  value = module.lz_data.rg.name
}

output "foundry_hub_name" {
  value = azurerm_machine_learning_workspace.hub.name
}
