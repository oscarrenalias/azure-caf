data "azurerm_private_dns_zone" "app_service" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_service_plan" "app_service" {
  name                = "asp${random_id.app_service.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "random_id" "app_service" {
  byte_length = 6
}

resource "azurerm_linux_web_app" "item" {
  name                          = "app${random_id.app_service.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  service_plan_id               = azurerm_service_plan.app_service.id
  virtual_network_subnet_id     = azurerm_subnet.item["app-service-integration"].id
  public_network_access_enabled = false
  https_only                    = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
  }

  app_settings = {
    APIM_ENDPOINT                  = var.apim_gateway_url
    APIM_API_KEY                   = var.apim_subscription_key
    SEARCH_ENDPOINT                = "https://${azurerm_search_service.main.name}.search.windows.net"
    SEARCH_API_KEY                 = azurerm_search_service.main.primary_key
    OPENAI_DEPLOYMENT              = "gpt-4o"
    OPENAI_API_VERSION             = "2024-11-01-preview"
    FOUNDRY_PROJECT_NAME           = azurerm_ai_foundry_project.main.name
    FOUNDRY_PROJECT_RG             = module.lz_data.rg.name
    FOUNDRY_PROJECT_ENDPOINT       = "https://${azurerm_ai_foundry_project.main.name}.${module.lz_data.rg.location}.api.azureml.ms"
    AGENT_NAME                     = "rag-agent"
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
  }
}

resource "azurerm_private_endpoint" "app_service" {
  name                = "pe-app${random_id.app_service.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-app${random_id.app_service.hex}"
    private_connection_resource_id = azurerm_linux_web_app.item.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-azurewebsites"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.app_service.id]
  }
}
