
variable "ssh_public_key" {
  type      = string
  sensitive = true
}

resource "azurerm_network_interface" "vm1" {
  name                = "nic-vm1"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.item["vm"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "linux" {
  network_interface_id      = azurerm_network_interface.vm1.id
  network_security_group_id = azurerm_network_security_group.rule1.id
}

resource "azurerm_linux_virtual_machine" "vm1" {
  name                            = "vm1"
  resource_group_name             = module.lz_data.rg.name
  location                        = module.lz_data.rg.location
  size                            = "Standard_D2s_v5"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids = [
    azurerm_network_interface.vm1.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

resource "azurerm_network_security_group" "rule1" {
  name                = "nsg-ssh"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name

  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22"]
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }

}