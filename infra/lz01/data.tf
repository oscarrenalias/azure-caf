variable "number" {
  type = string
}

variable "lz" {
  type = string
}

module "lz_data" {
  source = "../modules/lz-data"
  number = var.number
  lz     = var.lz
}

output "rg" {
  value = module.lz_data.rg
}

output "vnet" {
  value = module.lz_data.vnet
}