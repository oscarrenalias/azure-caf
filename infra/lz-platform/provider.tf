terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.81.0"
    }
    # The AzureRM provider has no MCP server resources. APIM MCP servers are an API of
    # type "mcp" with `tools` sub-resources, which azapi reaches directly — Microsoft's
    # own documented Terraform path, and already how this repo manages Foundry.
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
  }
}

provider "azapi" {}
