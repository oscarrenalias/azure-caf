# Central egress firewall. Off by default.
#
# Azure Firewall Standard is by far the most expensive resource in this architecture —
# roughly $1.25/hour, about $900/month — which exhausts a Visual Studio subscription's
# monthly credit in about five days and did exactly that. Basic tier is around $290/month
# and still exceeds the credit, so tiering down does not solve it.
#
# As configured it also filtered nothing: the rule collection below allows any source to
# any destination on 443 and 53. It provided the hub-and-spoke *pattern* of central
# egress, not an actual control.
#
# The code is kept, and enabling it restores the pattern for a demo. When it is off,
# routed subnets fall back to Azure's default outbound access. Two consequences worth
# knowing:
#   - Egress IPs are then Azure-assigned and not stable, so nothing can allowlist them.
#   - Microsoft is retiring default outbound access for newly created subnets. Existing
#     subnets here report defaultOutboundAccess=true, but a long-term answer without a
#     firewall is a NAT Gateway (~$33/month), which also gives a stable egress IP.
#
# Turning this on requires applying hub first (to create the firewall and route table),
# then the landing zones (to associate their subnets). Turning it off is the reverse:
# landing zones first to drop the associations, then hub.
variable "enable_firewall" {
  type        = bool
  description = "Deploy Azure Firewall and route egress from routed subnets through it. Costs ~$900/month while enabled."
  default     = false
}

resource "azurerm_public_ip" "fwpip" {
  count               = var.enable_firewall ? 1 : 0
  name                = "pip-001"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_firewall" "hub" {
  count               = var.enable_firewall ? 1 : 0
  name                = "fw-001"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.item["AzureFirewallSubnet"].id
    public_ip_address_id = azurerm_public_ip.fwpip[0].id
  }
}

resource "azurerm_route_table" "main" {
  count               = var.enable_firewall ? 1 : 0
  name                = "main"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  route {
    name                   = "main"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub[0].ip_configuration[0].private_ip_address
  }
}

resource "azurerm_firewall_network_rule_collection" "all" {
  count               = var.enable_firewall ? 1 : 0
  name                = "all"
  azure_firewall_name = azurerm_firewall.hub[0].name
  resource_group_name = azurerm_resource_group.item[var.environment].name
  priority            = 100
  action              = "Allow"
  rule {
    name = "vm-any"
    source_addresses = [
      "*",
    ]
    destination_ports = [
      "443",
      "53"
    ]
    destination_addresses = [
      "*",
    ]
    protocols = [
      "Any",
    ]
  }
}
