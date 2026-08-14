
resource "azurerm_resource_group" "hub" {
  name     = "rg1"
  location = "West Europe"
}

resource "azurerm_virtual_network" "hub" {
  name                = "hub1"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = ["10.0.0.0/16"]
}