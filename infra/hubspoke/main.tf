
variable environments {
  type = list(object({
    name = string
  }))
}

variable number {
  type = number
}

variable location {
  type = string
}

resource "azurerm_resource_group" "item" {
  for_each = { for env in var.environments : env.name => env  }
  name     = "rg${var.number}-${each.value.name}"
  location = var.location
}

# resource "azurerm_virtual_network" "hub" {
#   name                = "hub1"
#   location            = azurerm_resource_group.hub.location
#   resource_group_name = azurerm_resource_group.hub.name
#   address_space       = ["10.0.0.0/16"]
# }