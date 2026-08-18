# ai-agents subnet is provisioned via the shared subnet loop in main.tf
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

resource "azurerm_cognitive_deployment" "gpt" {
  name                 = "gpt-5.6-sol"
  cognitive_account_id = azurerm_cognitive_account.ai_foundry.id

  model {
    format = "OpenAI"
    name   = "gpt-5.6-sol"
  }

  sku {
    name     = "Standard"
    capacity = 10
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
