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

output "rg" {
  value = module.spoke_data.rg
}

output "vnet" {
  value = module.spoke_data.vnet
}