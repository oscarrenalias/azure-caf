
variable "environments" {
  type = list(object({
    name = string
    range = string
  }))
}

variable "number" {
  type = number
}

variable "location" {
  type = string
}

resource "azurerm_resource_group" "item" {
  for_each = { for env in var.environments : env.name => env }
  name     = "rg${var.number}-${each.value.name}"
  location = var.location
}

resource "azurerm_virtual_network" "item" {
  for_each            = { for env in var.environments : env.name => env }
  name                = "vnet${var.number}-${each.value.name}"
  location            = azurerm_resource_group.item[each.key].location
  resource_group_name = azurerm_resource_group.item[each.key].name
  address_space       = [each.value.range]
}