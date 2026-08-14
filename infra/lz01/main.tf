resource "azurerm_subnet" "item" {
  for_each             = { for env in var.subnets : env.name => env }
  name                 = "subnet-${each.value.name}"
  resource_group_name  = module.lz_data.rg.name
  virtual_network_name = module.lz_data.vnet.name
  address_prefixes     = [each.value.prefix]
}

variable "subnets" {
  type = list(object({
    name   = string
    prefix = string
  }))
}