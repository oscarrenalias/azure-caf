# resource "azurerm_subnet" "hubfw" {
#   name                                          = "AzureFirewallSubnet"
#   resource_group_name                           = azurerm_resource_group.hub.name
#   virtual_network_name                          = azurerm_virtual_network.hub.name
#   address_prefixes                              = ["10.0.1.0/24"]
#   private_endpoint_network_policies_enabled     = true
#   private_link_service_network_policies_enabled = true
# }

resource "azurerm_public_ip" "fwpip" {
  name                = "pip-001"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  allocation_method   = "Static"
  sku                 = "Standard"
  #domain_name_label   = "dev1138fw001pip"
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

# resource "azurerm_subnet_route_table_association" "aks-pe" {
#   subnet_id      = azurerm_subnet.aks-pe.id
#   route_table_id = azurerm_route_table.main.id
# }



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
      "*",
    ]
    destination_addresses = [
      "*",
    ]
    protocols = [
      "Any",
    ]
  }
}
