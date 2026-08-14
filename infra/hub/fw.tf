
resource "azurerm_public_ip" "fwpip" {
  name                = "pip-001"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_firewall" "hub" {
  name                = "fw-001"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.item["AzureFirewallSubnet"].id
    public_ip_address_id = azurerm_public_ip.fwpip.id
  }
}


resource "azurerm_route_table" "main" {
  name                = "main"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  route {
    name                   = "main"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  }
}


resource "azurerm_firewall_network_rule_collection" "all" {
  name                = "all"
  azure_firewall_name = azurerm_firewall.hub.name
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
