
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

variable "ssh_public_key" {
  type      = string
  sensitive = true
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
  use_remote_gateways          = false
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  allow_gateway_transit        = each.value.source == "hub" ? true : false
}

resource "azurerm_subnet" "item" {
  for_each             = { for env in var.subnets : env.name => env }
  name                 = each.value.name
  resource_group_name  = azurerm_resource_group.item[var.network].name
  virtual_network_name = azurerm_virtual_network.item[var.network].name
  address_prefixes     = [each.value.prefix]
}

# resource "azurerm_subnet" "hub" {
#   private_endpoint_network_policies_enabled     = true
#   private_link_service_network_policies_enabled = true
# }
