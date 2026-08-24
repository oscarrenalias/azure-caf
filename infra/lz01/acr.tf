resource "random_id" "acr" {
  byte_length = 6
}

resource "azurerm_container_registry" "main" {
  name                          = "acr${random_id.acr.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  sku           = "Premium"
  admin_enabled = false

  # Reachable only through the private endpoint below. This became possible once the
  # Foundry account was network-injected: the agent build and pull now run inside the
  # VNet instead of on Azure-managed infrastructure outside it. The App Service reaches
  # it through vnet_image_pull_enabled.
  public_network_access_enabled = false
}

data "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr${random_id.acr.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-acr${random_id.acr.hex}"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-acr"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.acr.id]
  }
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_id" {
  value = azurerm_container_registry.main.id
}
