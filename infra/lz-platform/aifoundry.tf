resource "random_id" "ai_foundry" {
  byte_length = 6
}

resource "azurerm_cognitive_account" "ai_foundry" {
  name                          = "aif${random_id.ai_foundry.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "aif${random_id.ai_foundry.hex}"
  public_network_access_enabled = false

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "gpt4o" {
  name                 = "gpt-4o"
  cognitive_account_id = azurerm_cognitive_account.ai_foundry.id

  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = "2024-11-20"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 30
  }
}

resource "azurerm_cognitive_deployment" "text_embedding" {
  name                 = "text-embedding-3-small"
  cognitive_account_id = azurerm_cognitive_account.ai_foundry.id

  model {
    format  = "OpenAI"
    name    = "text-embedding-3-small"
    version = "1"
  }

  sku {
    name     = "Standard"
    capacity = 120
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

resource "azurerm_private_endpoint" "ai_foundry" {
  name                = "pe-aif${random_id.ai_foundry.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-aif${random_id.ai_foundry.hex}"
    private_connection_resource_id = azurerm_cognitive_account.ai_foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "privatelink-aifoundry"
    private_dns_zone_ids = [
      data.azurerm_private_dns_zone.cognitive_services.id,
      data.azurerm_private_dns_zone.openai.id,
    ]
  }
}

output "ai_foundry_endpoint" {
  value = "https://${azurerm_cognitive_account.ai_foundry.name}.openai.azure.com"
}
