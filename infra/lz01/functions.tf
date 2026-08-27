resource "random_id" "functions" {
  byte_length = 6
}

# A user-assigned identity rather than the system-assigned one, for a sequencing
# reason rather than a preference. Flex Consumption validates the deployment storage
# container when the app is created, and with identity-based storage auth that check
# runs as the app's identity. A system-assigned principal does not exist until the app
# exists, so its role assignments cannot precede the create — the app would be created,
# fail the check, and only work after a second apply. A user-assigned identity is
# created and granted first, which makes a single apply sufficient.
#
# The same identity is what the function code authenticates to Table Storage with, via
# DefaultAzureCredential picking up AZURE_CLIENT_ID below.
resource "azurerm_user_assigned_identity" "functions" {
  name                = "id-func${random_id.functions.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
}

resource "azurerm_service_plan" "functions" {
  name                = "aspfunc${random_id.functions.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  os_type             = "Linux"

  # FC1 is the Flex Consumption SKU. It scales to zero, which is why adding a system of
  # record to this environment costs effectively nothing when nobody is asking about
  # orders. It cannot share a plan with the B1 one the UI runs on.
  sku_name = "FC1"
}

# The orders backend. It knows nothing about MCP or about agents: it is an ordinary
# REST API over Table Storage. APIM in the platform LZ is what turns its operations
# into MCP tools (infra/lz-platform/orders.tf) — that separation is the point of the
# exercise, so keep this app free of anything agent-shaped.
resource "azurerm_function_app_flex_consumption" "orders" {
  name                = "func${random_id.functions.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  service_plan_id     = azurerm_service_plan.functions.id

  https_only = true

  # Reachable only through the private endpoint below. The one caller is APIM, which is
  # VNet-injected in lz-platform and routes here over the lz01 <-> lz-platform peering
  # added in config/hub.tfvars. Developers reach it from the jump host.
  public_network_access_enabled = false

  # Outbound into the app's own delegated subnet, so the storage account's blob and
  # table private endpoints resolve and are routable. Flex Consumption sends all
  # outbound traffic through the integrated subnet — there is no vnet_route_all toggle
  # to set as there is on the App Service.
  virtual_network_subnet_id = azurerm_subnet.item["functions"].id

  storage_container_type     = "blobContainer"
  storage_container_endpoint = "${azapi_resource.content.output.properties.primaryEndpoints.blob}${azapi_resource.function_releases.name}"

  # Identity-based, because the storage account has allowSharedKeyAccess = false and a
  # connection string therefore cannot be produced at all — this is not a hardening
  # choice made here, it is the only option the account allows.
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.functions.id

  runtime_name    = "python"
  runtime_version = "3.12"

  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.functions.id]
  }

  site_config {}

  app_settings = {
    # The Functions host's own bookkeeping storage, also identity-based for the same
    # reason. The three-part __ syntax is how the host is told to use a managed
    # identity instead of a connection string.
    AzureWebJobsStorage__accountName = azapi_resource.content.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.functions.client_id

    # Read by app/orders/function_app.py.
    ORDERS_TABLE_ENDPOINT = "https://${azapi_resource.content.name}.table.core.windows.net"
    ORDERS_TABLE_NAME     = azapi_resource.orders_table.name

    # Makes DefaultAzureCredential in the function code pick this identity rather than
    # guessing when more than one is present.
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.functions.client_id
  }

  # The role assignments must land before the app is created, or the deployment
  # container check fails. Terraform infers no dependency from a role assignment that
  # only references the identity, so it is stated here.
  depends_on = [
    azurerm_role_assignment.functions_storage_blob_owner,
    azurerm_role_assignment.functions_storage_table_contributor,
  ]
}

resource "azurerm_private_endpoint" "functions" {
  name                = "pe-func${random_id.functions.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  subnet_id           = azurerm_subnet.item["private-endpoint"].id

  private_service_connection {
    name                           = "psc-func${random_id.functions.hex}"
    private_connection_resource_id = azurerm_function_app_flex_consumption.orders.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "privatelink-azurewebsites"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.app_service.id]
  }
}

output "orders_function_name" {
  value       = azurerm_function_app_flex_consumption.orders.name
  description = "Copy into orders_function_name in config/lz-platform.tfvars, then re-apply lz-platform to publish the REST API and MCP server."
}

output "orders_function_hostname" {
  value = azurerm_function_app_flex_consumption.orders.default_hostname
}
