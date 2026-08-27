# Each delegation carries a mandatory action that Azure fills in server-side. With no
# actions declared here the provider reads that as "remove them", so every plan shows
# these subnets changing and every apply pokes the delegation. Azure restores the
# defaults, which is why it has never broken anything — but one of these subnets carries
# the Foundry account's network injection, and a delegation that does break there means
# rebuilding the account behind a 48-hour soft delete. Declaring the actions makes the
# plan honest and leaves the delegation alone.
#
# A delegation missing from this map falls back to the old behaviour rather than failing.
locals {
  delegation_actions = {
    "Microsoft.App/environments" = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    "Microsoft.Web/serverFarms"  = ["Microsoft.Network/virtualNetworks/subnets/action"]
  }
}

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
        name    = delegation.value
        actions = lookup(local.delegation_actions, delegation.value, null)
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