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
      allowSharedKeyAccess     = false
      allowBlobPublicAccess    = false
      supportsHttpsTrafficOnly = true
      minimumTlsVersion        = "TLS1_2"
      accessTier               = "Hot"

      # Not "Disabled", despite the private endpoint below, because the AI Search
      # indexer cannot reach it otherwise. When storage is network-protected and in the
      # *same region* as the search service, Microsoft does not support the shared
      # private link path: the connection has to come through the trusted-service
      # exception or a resource instance rule, and both are evaluated on the public
      # endpoint. With it Disabled the indexer fails with "Credentials provided in the
      # connection string are invalid or have expired", which reads like an auth problem
      # and is not.
      #
      # The exposure is narrow: default action Deny with no IP rules, so the only
      # non-private caller admitted is the one search service named below. Everything
      # else — the jump host uploading content — still goes through the private endpoint.
      publicNetworkAccess = "Enabled"
      networkAcls = {
        defaultAction = "Deny"
        bypass        = "None"
        ipRules       = []
        virtualNetworkRules = []
        resourceAccessRules = [
          {
            tenantId   = data.azurerm_client_config.current.tenant_id
            resourceId = azurerm_search_service.main.id
          }
        ]
      }
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

# Deployment container for the orders Function App. Flex Consumption keeps the app
# package in blob storage and pulls it at every cold start, so this is on the startup
# path — not a one-off upload target. See infra/lz01/functions.tf.
resource "azapi_resource" "function_releases" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "function-releases"
  parent_id = "${azapi_resource.content.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# The system of record the agent acts on. PartitionKey is the customer id and RowKey
# the order id, so listing a customer's orders is a partition scan rather than a table
# scan, and fetching one order is a point read.
resource "azapi_resource" "orders_table" {
  type      = "Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01"
  name      = "orders"
  parent_id = "${azapi_resource.content.id}/tableServices/default"

  body = {
    properties = {}
  }
}

data "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = "rg${var.number}-${var.hub}"
}

data "azurerm_private_dns_zone" "table" {
  name                = "privatelink.table.core.windows.net"
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

# A private endpoint is per sub-resource, not per account: the one above covers `blob`
# and nothing else. Without this the Function App resolves the table endpoint to the
# account's public IP, where networkAcls denies it.
resource "azurerm_private_endpoint" "storage_table" {
  name                = "pe-st${random_id.storage.hex}-table"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-st${random_id.storage.hex}-table"
    private_connection_resource_id = azapi_resource.content.id
    subresource_names              = ["table"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-table"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.table.id]
  }
}

output "content_storage_account" {
  value = azapi_resource.content.name
}

output "orders_table_endpoint" {
  value = "https://${azapi_resource.content.name}.table.core.windows.net"
}

output "content_container" {
  value = azapi_resource.books.name
}
