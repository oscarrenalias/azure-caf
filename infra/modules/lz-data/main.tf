variable "number" {
  type = string
}

variable "lz" {
  type = string
}

data "azurerm_resource_group" "lz" {
  name = "rg${var.number}-${var.lz}"
}

data "azurerm_virtual_network" "lz" {
  name                = "vnet${var.number}-${var.lz}"
  resource_group_name = data.azurerm_resource_group.lz.name
}

output rg {
  value = data.azurerm_resource_group.lz
}

output vnet {
  value = data.azurerm_virtual_network.lz
}