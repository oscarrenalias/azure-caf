
resource "azurerm_public_ip" "jump" {
  name                = "publicip-jump"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name
  allocation_method   = "Static"

}

resource "azurerm_network_interface" "jump" {
  name                = "nic-jump"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.item["vm"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jump.id
  }
}

resource "azurerm_network_interface_security_group_association" "linux" {
  network_interface_id      = azurerm_network_interface.jump.id
  network_security_group_id = azurerm_network_security_group.rule1.id
}

resource "azurerm_linux_virtual_machine" "jump" {
  name                            = "jump7"
  resource_group_name             = azurerm_resource_group.item[var.environment].name
  location                        = azurerm_resource_group.item[var.environment].location
  size                            = "Standard_D2s_v5"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  custom_data = base64encode(templatefile("${path.module}/scripts/github-runner.sh.tftpl", {
    github_repository = var.github_repository
    github_runner_pat = var.github_runner_pat
  }))
  network_interface_ids = [
    azurerm_network_interface.jump.id,
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
  name                = "nsg-remoteaccess"
  location            = azurerm_resource_group.item[var.environment].location
  resource_group_name = azurerm_resource_group.item[var.environment].name

  security_rule {
    name                       = "remote"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "83.83.37.87/32"
    destination_address_prefix = "*"
  }

}