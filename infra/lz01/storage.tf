resource "random_id" "storage" {
  byte_length = 6
}

# Holds the source content that AI Search indexes — the markdown produced from the books
# in content/ by tools/epub2md.py. Private endpoint only: the indexer reaches it through
# the shared private link in search.tf, and uploads happen from the jump host.
#
# Managed with azapi rather than azurerm_storage_account deliberately. The azurerm
# resource touches the storage *data plane* during create and refresh — it probes the
# blob service with account keys, and reads file share properties — which cannot work
# here on two counts: shared keys are disabled, and the account is unreachable from the
# public runner that Terraform runs on. azapi stays on the management plane.
resource "azapi_resource" "content" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = "st${random_id.storage.hex}"
  parent_id = module.lz_data.rg.id
  location  = module.lz_data.rg.location

  body = {
    sku  = { name = "Standard_LRS" }
    kind = "StorageV2"
    properties = {
      publicNetworkAccess      = "Disabled"
      allowSharedKeyAccess     = false
      allowBlobPublicAccess    = false
      supportsHttpsTrafficOnly = true
      minimumTlsVersion        = "TLS1_2"
      accessTier               = "Hot"
    }
  }

  response_export_values = ["*"]
}

resource "azapi_resource" "books" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "books"
  parent_id = "${azapi_resource.content.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
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
    private_connection_resource_id = azapi_resource.content.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-blob"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.blob.id]
  }
}

output "content_storage_account" {
  value = azapi_resource.content.name
}

output "content_container" {
  value = azapi_resource.books.name
}
