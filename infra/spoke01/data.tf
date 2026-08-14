variable "number" {
  type = string
}

variable "spoke" {
  type = string
}

module "spoke_data" {
  source = "../modules/spoke-data"
  number = var.number
  spoke  = var.spoke
}

output "resource_group_name" {
  value = module.spoke_data.rg
}

output "virtual_network_name" {
  value = module.spoke_data.vnet
}