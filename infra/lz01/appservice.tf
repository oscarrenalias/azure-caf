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
  service_plan_id           = azurerm_service_plan.app_service.id
  virtual_network_subnet_id = azurerm_subnet.item["app-service-integration"].id
  https_only                = true

  # Public access is on only to carry the ip_restriction allowlist below. With
  # allowed_ips empty the site config denies by default, so nothing is publicly
  # reachable. This is the one component that still needs a public front door — it is
  # how the UI is opened in a browser.
  public_network_access_enabled = true

  # Pull the container through the VNet rather than over the platform network, so the
  # image can be fetched from ACR's private endpoint. Without this, closing ACR's public
  # access leaves the site unable to start on its next cold start or restart.
  vnet_image_pull_enabled = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appservice.id]
  }

  site_config {
    # Route outbound through the VNet so the private DNS zones linked there apply.
    # Without this the app resolves the Foundry account to its public IP, which puts
    # its calls to the agent endpoint through the account's network ACL, where the
    # App Service outbound IP is not allowlisted. With it, the name resolves to the
    # private endpoint in the private-endpoint subnet and the ACL doesn't apply.
    vnet_route_all_enabled = true

    ip_restriction_default_action = "Deny"

    # Pull the image with the app's own identity, which holds AcrPull (roles.tf).
    # ACR has admin_enabled = false, so the DOCKER_REGISTRY_SERVER_USERNAME/PASSWORD
    # credentials the site was configured with cannot authenticate — the site had been
    # failing to start with ImagePullUnauthorizedFailure.
    container_registry_use_managed_identity       = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.appservice.client_id

    # Developer workstations, so the UI can be opened in a browser.
    dynamic "ip_restriction" {
      for_each = var.allowed_ips
      content {
        name       = "allowed-ip-${ip_restriction.key}"
        action     = "Allow"
        priority   = 100 + ip_restriction.key
        ip_address = "${ip_restriction.value}/32"
      }
    }

    # Hub-and-spoke address space, so the jump host and other in-VNet clients keep
    # working via the private endpoint regardless of how private traffic is
    # evaluated against these rules.
    ip_restriction {
      name       = "hub-and-spoke"
      action     = "Allow"
      priority   = 200
      ip_address = "10.0.0.0/8"
    }

    application_stack {
      docker_image_name   = "rag-ui:latest"
      docker_registry_url = "https://${azurerm_container_registry.main.login_server}"
    }
  }

  app_settings = {
    APIM_ENDPOINT            = var.apim_gateway_url
    APIM_API_KEY             = var.apim_subscription_key
    SEARCH_ENDPOINT          = "https://${azurerm_search_service.main.name}.search.windows.net"
    SEARCH_API_KEY           = azurerm_search_service.main.primary_key
    OPENAI_DEPLOYMENT        = "gpt-4o"
    OPENAI_API_VERSION       = "2024-11-01-preview"
    FOUNDRY_PROJECT_NAME     = azapi_resource.foundry_project.name
    FOUNDRY_PROJECT_RG       = module.lz_data.rg.name
    FOUNDRY_PROJECT_ENDPOINT = "https://${azurerm_cognitive_account.foundry_hub.name}.services.ai.azure.com/api/projects/${azapi_resource.foundry_project.name}"
    AGENT_NAME               = "rag-agent"
    WEBSITES_PORT            = "8000"
    AZURE_CLIENT_ID          = azurerm_user_assigned_identity.appservice.client_id
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
