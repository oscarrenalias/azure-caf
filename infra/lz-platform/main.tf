variable "hub" {
  type = string
}

variable "subnets" {
  type = list(object({
    name       = string
    prefix     = string
    route      = bool
    delegation = optional(string)
  }))
}

variable "apim_publisher_name" {
  type = string
}

variable "apim_publisher_email" {
  type = string
}

resource "azurerm_subnet" "item" {
  for_each             = { for s in var.subnets : s.name => s }
  name                 = each.value.name
  resource_group_name  = module.lz_data.rg.name
  virtual_network_name = module.lz_data.vnet.name
  address_prefixes     = [each.value.prefix]

  dynamic "delegation" {
    for_each = each.value.delegation != null ? [each.value.delegation] : []
    content {
      name = each.value.name
      service_delegation {
        name = delegation.value
      }
    }
  }
}

data "azurerm_route_table" "hub" {
  name                = "main"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_subnet_route_table_association" "item" {
  for_each       = { for s in var.subnets : s.name => s if s.route == true }
  subnet_id      = azurerm_subnet.item[each.key].id
  route_table_id = data.azurerm_route_table.hub.id
}
