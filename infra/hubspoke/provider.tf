terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      #   version = "=3.88.0"
    }
    azuread = {
      source = "hashicorp/azuread"
      #   version = "=2.47.0"
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