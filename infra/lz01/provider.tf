terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.81.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
  backend "azurerm" {
    container_name = "state"
    key            = "novalue"
  }
}

provider "azurerm" {
  features {}
}

provider "azapi" {}