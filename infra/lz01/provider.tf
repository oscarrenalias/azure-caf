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
  features {
    storage {
      # The content storage account has shared_access_key_enabled = false, and it is
      # private-endpoint only. The provider's default post-create probe of the blob
      # data plane uses account keys and runs from the Terraform host, so it fails
      # twice over — "Key based authentication is not permitted on this storage
      # account". Containers are managed through the management plane instead.
      data_plane_available = false
    }
  }
}

provider "azapi" {}