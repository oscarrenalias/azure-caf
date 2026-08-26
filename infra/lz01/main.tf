resource "azurerm_subnet" "item" {
  for_each             = { for env in var.subnets : env.name => env }
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

# Routed subnets send egress to the hub firewall. Both the lookup and the associations
# are conditional: with the firewall off there is no route table to find, and a data
# source for a missing resource fails the plan outright. See enable_firewall in
# infra/hub/fw.tf for why it defaults to off.
variable "enable_firewall" {
  type        = bool
  description = "Associate routed subnets with the hub firewall's route table. Must match the hub stack's setting."
  default     = false
}

data "azurerm_route_table" "hub" {
  count               = var.enable_firewall ? 1 : 0
  name                = "main"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_subnet_route_table_association" "item" {
  for_each       = var.enable_firewall ? { for s in var.subnets : s.name => s if s.route == true } : {}
  subnet_id      = azurerm_subnet.item[each.key].id
  route_table_id = data.azurerm_route_table.hub[0].id
}