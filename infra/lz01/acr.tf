resource "random_id" "acr" {
  byte_length = 6
}

resource "azurerm_container_registry" "main" {
  name                          = "acr${random_id.acr.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  sku                           = "Premium"
  admin_enabled                 = false
  # Public access required: the Foundry hosted agent platform pulls images
  # from Azure-managed infrastructure outside our VNet.
  public_network_access_enabled = true
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
