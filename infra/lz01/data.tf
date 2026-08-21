variable "number" {
  type = string
}

variable "lz" {
  type = string
}

variable "apim_gateway_url" {
  type    = string
  default = ""
}

variable "apim_subscription_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "allowed_ips" {
  type        = list(string)
  description = "IP addresses allowed public access to AI Services endpoints (e.g. developer workstations)"
  default     = []
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