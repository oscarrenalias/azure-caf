terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      #   version = "=3.88.0"
    }
  }
  backend "azurerm" {
    container_name = "state"
    key            = "novalue"
  }
}

provider "azurerm" {
  features {
  }
}