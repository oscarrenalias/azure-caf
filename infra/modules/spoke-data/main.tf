variable "number" {
  type = string
}

variable "spoke" {
  type = string
}

data "azurerm_resource_group" "spoke" {
  name = "rg${var.number}-${var.spoke}"
}

data "azurerm_virtual_network" "spoke" {
  name                = "vnet${var.number}-${var.spoke}"
  resource_group_name = data.azurerm_resource_group.spoke.name
}