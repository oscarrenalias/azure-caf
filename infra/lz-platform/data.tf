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
