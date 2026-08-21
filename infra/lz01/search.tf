resource "random_id" "search" {
  byte_length = 6
}

data "azurerm_private_dns_zone" "search" {
  name                = "privatelink.search.windows.net"
  resource_group_name = "rg${var.number}-${var.hub}"
}

# Public access is enabled only to carry the developer IP allowlist, same pattern
# as the Foundry hub in foundry.tf: the RAG tool in app/agent runs on the developer
# workstation during `azd ai agent run`, and the private endpoint below is not
# reachable from there. With allowed_ips empty this is a deny-all — no public
# reachability — and in-VNet traffic always uses the private endpoint.
resource "azurerm_search_service" "main" {
  name                          = "srch${random_id.search.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  sku                           = "basic"
  public_network_access_enabled = true
  allowed_ips                   = var.allowed_ips
  local_authentication_enabled  = true

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_private_endpoint" "search" {
  name                = "pe-srch${random_id.search.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-srch${random_id.search.hex}"
    private_connection_resource_id = azurerm_search_service.main.id
    subresource_names              = ["searchService"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-search"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.search.id]
  }
}

output "search_endpoint" {
  value = "https://${azurerm_search_service.main.name}.search.windows.net"
}

output "search_primary_key" {
  value     = azurerm_search_service.main.primary_key
  sensitive = true
}
