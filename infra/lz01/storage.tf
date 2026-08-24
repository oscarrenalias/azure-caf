resource "random_id" "storage" {
  byte_length = 6
}

# Holds the source content that AI Search indexes — the markdown produced from the books
# in content/ by tools/epub2md.py. Private endpoint only: the indexer reaches it through
# the shared private link in search.tf, and uploads happen from the jump host.
resource "azurerm_storage_account" "content" {
  name                     = "st${random_id.storage.hex}"
  location                 = module.lz_data.rg.location
  resource_group_name      = module.lz_data.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"

  # The indexer authenticates with the Search service's managed identity
  # (ResourceId= connection string), so no account keys are needed.
  shared_access_key_enabled = false
}

resource "azurerm_storage_container" "books" {
  name                  = "books"
  storage_account_id    = azurerm_storage_account.content.id
  container_access_type = "private"
}

data "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_private_endpoint" "storage" {
  name                = "pe-st${random_id.storage.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-st${random_id.storage.hex}"
    private_connection_resource_id = azurerm_storage_account.content.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-blob"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.blob.id]
  }
}

output "content_storage_account" {
  value = azurerm_storage_account.content.name
}

output "content_container" {
  value = azurerm_storage_container.books.name
}
