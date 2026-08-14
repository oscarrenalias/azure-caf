
variable "networks" {
  type = list(object({
    name  = string
    range = string
  }))
}

variable "network" {
  type = string
}

variable "environment" {
  type = string
}

variable "number" {
  type = number
}

variable "subnets" {
  type = list(object({
    name   = string
    prefix = string
  }))
}

variable "location" {
  type = string
}

variable "peerings" {
  type = list(object({
    name        = string
    source      = string
    destination = string
  }))
}

resource "azurerm_resource_group" "item" {
  for_each = { for env in var.networks : env.name => env }
  name     = "rg${var.number}-${each.value.name}"
  location = var.location
}

resource "azurerm_virtual_network" "item" {
  for_each            = { for env in var.networks : env.name => env }
  name                = "vnet${var.number}-${each.value.name}"
  location            = azurerm_resource_group.item[each.key].location
  resource_group_name = azurerm_resource_group.item[each.key].name
  address_space       = [each.value.range]
}

resource "azurerm_virtual_network_peering" "item" {
  for_each                     = { for p in var.peerings : p.name => p }
  name                         = each.value.name
  resource_group_name          = azurerm_resource_group.item[each.value.source].name
  virtual_network_name         = azurerm_virtual_network.item[each.value.source].name
  remote_virtual_network_id    = azurerm_virtual_network.item[each.value.destination].id
  use_remote_gateways          = each.value.source == "hub" ? false : false # set to true when spoke needs to use hub gateway
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  allow_gateway_transit        = each.value.source == "hub" ? true : false
}

resource "azurerm_subnet" "item" {
  for_each             = { for env in var.subnets : env.name => env }
  name                 = "subnet-${each.value.name}"
  resource_group_name  = azurerm_resource_group.item[var.network].name
  virtual_network_name = azurerm_virtual_network.item[var.network].name
  address_prefixes     = [each.value.prefix]
}


# # spoke2hub
#   use_remote_gateways          = true
#   allow_forwarded_traffic      = true
#   allow_virtual_network_access = true
# # hub2spoke
#   use_remote_gateways          = false
#   allow_gateway_transit        = true
#   allow_forwarded_traffic      = true
#   allow_virtual_network_access = true



# resource "azurerm_subnet" "hub" {
#   name                                          = "hub-subnet"
#   resource_group_name                           = azurerm_resource_group.hub.name
#   virtual_network_name                          = azurerm_virtual_network.hub.name
#   address_prefixes                              = ["10.0.0.0/24"]
#   private_endpoint_network_policies_enabled     = true
#   private_link_service_network_policies_enabled = true
# }

# resource "azurerm_subnet" "hubfw" {
#   name                                          = "AzureFirewallSubnet"
#   resource_group_name                           = azurerm_resource_group.hub.name
#   virtual_network_name                          = azurerm_virtual_network.hub.name
#   address_prefixes                              = ["10.0.1.0/24"]
#   private_endpoint_network_policies_enabled     = true
#   private_link_service_network_policies_enabled = true
# }

# resource "azurerm_public_ip" "fwpip" {
#   name                = "fw001pip"
#   location            = azurerm_resource_group.hub.location
#   resource_group_name = azurerm_resource_group.hub.name
#   allocation_method   = "Static"
#   sku                 = "Standard"
#   domain_name_label   = "dev1138fw001pip"
# }



# resource "azurerm_firewall" "hub" {
#   name                = "fw001"
#   location            = azurerm_resource_group.hub.location
#   resource_group_name = azurerm_resource_group.hub.name
#   sku_name            = "AZFW_VNet"
#   sku_tier            = "Standard"

#   ip_configuration {
#     name                 = "configuration"
#     subnet_id            = azurerm_subnet.hubfw.id
#     public_ip_address_id = azurerm_public_ip.fwpip.id
#   }
# }

