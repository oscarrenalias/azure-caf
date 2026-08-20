resource "random_id" "apim" {
  byte_length = 4
}

resource "azurerm_public_ip" "apim" {
  name                = "pip-apim${random_id.apim.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "apim${random_id.apim.hex}"
}

# APIM internal VNet mode requires these specific NSG rules on its subnet.
# Outbound uses NSG defaults (allow internet) since route=false keeps traffic off the firewall.
resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name

  security_rule {
    name                       = "apim-management-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "apim-loadbalancer-inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "apim-client-inbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.item["apim"].id
  network_security_group_id = azurerm_network_security_group.apim.id
}

# Developer_1 SKU, internal VNet mode. Expect 30-45 minutes to provision.
resource "azurerm_api_management" "main" {
  name                = "apim${random_id.apim.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = "Developer_1"

  virtual_network_type = "Internal"

  virtual_network_configuration {
    subnet_id = azurerm_subnet.item["apim"].id
  }

  public_ip_address_id = azurerm_public_ip.apim.id

  identity {
    type = "SystemAssigned"
  }
}

# APIM managed identity → Cognitive Services OpenAI User on AI Foundry
# This allows APIM to call AI Foundry with a bearer token instead of an API key.
resource "azurerm_role_assignment" "apim_openai_user" {
  scope                = azurerm_cognitive_account.ai_foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.main.identity[0].principal_id
}

# Single AI Foundry backend (PAYG).
# To add PTU+PAYG spillover: add a second azurerm_api_management_backend pointing
# at a PTU instance, then update the policy to retry on 429 against this PAYG backend.
resource "azurerm_api_management_backend" "ai_foundry" {
  name                = "ai-foundry"
  resource_group_name = module.lz_data.rg.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = "https://${azurerm_cognitive_account.ai_foundry.name}.openai.azure.com/openai"
}

# OpenAI-compatible API. Consumers call https://<apim>.azure-api.net/openai/...
# which is structurally identical to calling Azure OpenAI directly — zero SDK changes.
resource "azurerm_api_management_api" "openai" {
  name                  = "azure-openai"
  resource_group_name   = module.lz_data.rg.name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "Azure OpenAI"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = true

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }
}

resource "azurerm_api_management_api_operation" "post" {
  operation_id        = "passthrough-post"
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = module.lz_data.rg.name
  display_name        = "Passthrough POST"
  method              = "POST"
  url_template        = "/*"
}

resource "azurerm_api_management_api_operation" "get" {
  operation_id        = "passthrough-get"
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = module.lz_data.rg.name
  display_name        = "Passthrough GET"
  method              = "GET"
  url_template        = "/*"
}

# Policy: swap consumer api-key for APIM managed identity bearer token,
# route to AI Foundry backend, and enforce per-subscription token rate limit.
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = module.lz_data.rg.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
        <set-header name="Authorization" exists-action="override">
          <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
        </set-header>
        <set-header name="api-key" exists-action="delete" />
        <set-backend-service backend-id="ai-foundry" />
        <azure-openai-token-limit tokens-per-minute="100000" counter-key="@(context.Subscription.Id)" estimate-prompt-tokens="true" tokens-consumed-variable-name="tokens-consumed" />
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

# Product that workload teams subscribe to in order to get an api-key
resource "azurerm_api_management_product" "ai_platform" {
  product_id            = "ai-platform"
  api_management_name   = azurerm_api_management.main.name
  resource_group_name   = module.lz_data.rg.name
  display_name          = "AI Platform"
  description           = "Access to Azure OpenAI models via the AI Gateway. Use the subscription key as api-key in SDK calls."
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "ai_platform_openai" {
  api_name            = azurerm_api_management_api.openai.name
  product_id          = azurerm_api_management_product.ai_platform.product_id
  api_management_name = azurerm_api_management.main.name
  resource_group_name = module.lz_data.rg.name
}

# Private DNS A record: resolves <apim-name>.azure-api.net to APIM's private IP
# from any VNet linked to the hub's azure-api.net zone.
data "azurerm_private_dns_zone" "apim" {
  name                = "azure-api.net"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_private_dns_a_record" "apim_gateway" {
  name                = azurerm_api_management.main.name
  zone_name           = data.azurerm_private_dns_zone.apim.name
  resource_group_name = data.azurerm_private_dns_zone.apim.resource_group_name
  ttl                 = 300
  records             = [azurerm_api_management.main.private_ip_addresses[0]]
}

output "apim_gateway_url" {
  value       = "https://${azurerm_api_management.main.name}.azure-api.net/openai"
  description = "Base URL for Azure OpenAI SDK — use this instead of the AI Foundry endpoint directly."
}

output "apim_name" {
  value = azurerm_api_management.main.name
}
