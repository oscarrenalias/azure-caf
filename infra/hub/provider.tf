terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.81.0"
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