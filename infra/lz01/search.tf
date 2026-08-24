resource "random_id" "search" {
  byte_length = 6
}

data "azurerm_private_dns_zone" "search" {
  name                = "privatelink.search.windows.net"
  resource_group_name = "rg${var.number}-${var.hub}"
}

# Reachable only through the private endpoint below. Every caller is now in the VNet:
# the hosted agent runs in the ai-agents subnet, and local development runs on the jump
# VM rather than on a workstation, so no IP allowlist is needed.
resource "azurerm_search_service" "main" {
  name                          = "srch${random_id.search.hex}"
  location                      = module.lz_data.rg.location
  resource_group_name           = module.lz_data.rg.name
  sku                           = "basic"
  public_network_access_enabled = false
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

# Shared private links are Search's *outbound* private connectivity: the service is
# itself private-endpoint only, and its indexer and vectorizer still have to reach two
# resources that are also private. Each creates a private endpoint connection on the
# target that must be approved before it leaves the "Pending" state.
#
# Group ids are case-sensitive: "blob" for storage, "openai_account" for a Cognitive
# Services account used as an embedding model.

resource "azurerm_search_shared_private_link_service" "storage" {
  name               = "spl-blob"
  search_service_id  = azurerm_search_service.main.id
  subresource_name   = "blob"
  target_resource_id = azurerm_storage_account.content.id
  request_message    = "AI Search indexer reading book content"
}

# The embedding model lives in the platform landing zone and is private-endpoint only,
# so integrated vectorization — both the indexing skill and the query-time vectorizer —
# needs this link. Note this traffic does not pass through the APIM gateway.
resource "azurerm_search_shared_private_link_service" "openai" {
  name               = "spl-openai"
  search_service_id  = azurerm_search_service.main.id
  subresource_name   = "openai_account"
  target_resource_id = data.azurerm_cognitive_account.platform_foundry.id
  request_message    = "AI Search integrated vectorization"
}

output "search_endpoint" {
  value = "https://${azurerm_search_service.main.name}.search.windows.net"
}

output "search_primary_key" {
  value     = azurerm_search_service.main.primary_key
  sensitive = true
}
