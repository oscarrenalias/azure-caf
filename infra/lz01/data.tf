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

variable "platform_foundry_name" {
  type        = string
  description = "Name of the shared AI Foundry account in the platform LZ (aif<hex>), which hosts the embedding model AI Search vectorizes with"
  default     = ""
}

# The embedding deployment used by integrated vectorization. Lives in the platform LZ,
# so lz01 only needs its name — the resource group follows the naming convention.
data "azurerm_cognitive_account" "platform_foundry" {
  name                = var.platform_foundry_name
  resource_group_name = "rg${var.number}-lz-platform"
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