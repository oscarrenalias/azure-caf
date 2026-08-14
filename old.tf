
# https://learn.microsoft.com/en-us/azure/azure-monitor/agents/data-collection-log-text

# C:\WindowsAzure\Resources\AMADataStore.vm-windows\mcs>
# C:\Packages\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent\1.30.0.0\Status
# systemctl status azuremonitoragent
# /etc/opt/microsoft/azuremonitoragent/config-cache/configchunks





provider "azurerm" {
  features {}
  subscription_id = "xxxxxxxxxx"
}

provider "azapi" {
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.48.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">=1.9.0"
    }
  }
}
resource "azapi_resource" "test" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "WindowsLogFiles_CL"
  parent_id = azurerm_log_analytics_workspace.law.id
  body      = { "properties" : { "retentionInDays" : 30, "schema" : { "columns" : [{ "name" : "FilePath", "type" : "string" }, { "name" : "Computer", "type" : "string" }, { "name" : "RawData", "type" : "string" }, { "name" : "TimeGenerated", "type" : "datetime" }], "name" : "WindowsLogFiles_CL" } } }
}

# https://github.com/hashicorp/terraform-provider-azurerm/issues/21897
# az monitor log-analytics workspace table create --resource-group rg-it-tvdv-lab008-law --workspace-name law888 -n WindowsLogFiles_CL --retention-time 45 --columns FilePath=string Computer=string RawData=string TimeGenerated=datetime



resource "azurerm_resource_group" "test" {
  name     = "rg-it-tvdv-lab011"
  location = "westeurope"
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law011"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}


resource "azurerm_virtual_network" "test" {
  name                = "vnet-test"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  address_space       = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "test" {
  name                 = "subnet-test"
  resource_group_name  = azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.test.name
  address_prefixes     = ["10.0.0.0/25"]
}


resource "azurerm_network_interface_security_group_association" "windows" {
  network_interface_id      = azurerm_network_interface.windows.id
  network_security_group_id = azurerm_network_security_group.test.id
}

resource "azurerm_network_interface_security_group_association" "linux" {
  network_interface_id      = azurerm_network_interface.test.id
  network_security_group_id = azurerm_network_security_group.test.id
}

resource "azurerm_network_security_group" "test" {
  name                = "nsg-remoteaccess"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name

  security_rule {
    name                       = "remote"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "109.69.228.213/32"
    destination_address_prefix = "*"
  }

}

resource "azurerm_network_interface" "test" {
  name                = "nic-linux"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.linux.id
  }
}

resource "azurerm_network_interface" "windows" {
  name                = "nic-windows"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.test.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.windows.id
  }
}

resource "azurerm_public_ip" "linux" {
  name                = "publicip-linux"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  allocation_method   = "Static"

}

resource "azurerm_public_ip" "windows" {
  name                = "publicipw-indows"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  allocation_method   = "Static"

}


resource "azurerm_windows_virtual_machine" "windows" {
  name                = "vm-windows"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location
  size                = "Standard_D2s_v5"
  admin_username      = "azureuser"
  admin_password      = "Dpreview.com1!"

  network_interface_ids = [
    azurerm_network_interface.windows.id,
  ]

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "amawindows" {
  name                       = "amawindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.windows.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = "true"
}

resource "azurerm_virtual_machine_extension" "amalinux" {
  name                       = "amalinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.test.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = "true"
}



resource "azurerm_linux_virtual_machine" "test" {
  name                            = "vm-linux"
  resource_group_name             = azurerm_resource_group.test.name
  location                        = azurerm_resource_group.test.location
  size                            = "Standard_D2s_v5"
  admin_username                  = "azureuser"
  admin_password                  = "Dpreview.com1!"
  disable_password_authentication = false
  network_interface_ids = [
    azurerm_network_interface.test.id,
  ]


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




resource "azurerm_monitor_data_collection_rule" "linux" {
  name                = "dcr-linux"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location
  kind                = "Linux"

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
      name                  = "law-nonprod-weu-001-log"
    }
  }

  data_flow {
    streams       = ["Microsoft-Syslog"]
    destinations  = ["law-nonprod-weu-001-log"]
    output_stream = "Microsoft-Syslog"
    transform_kql = "source"
  }

  data_flow {
    streams       = ["Microsoft-Perf"]
    destinations  = ["law-nonprod-weu-001-log"]
    output_stream = "Microsoft-Perf"
    transform_kql = "source"
  }

  data_sources {
    performance_counter {
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers            = ["Logical Disk(*)\\% Free Space"]
      name                          = "perfCounterDataSource60"
    }

    syslog {
      facility_names = ["auth", "authpriv", "daemon", "syslog"]
      log_levels     = ["Emergency", "Alert", "Critical", "Error", "Warning", "Notice", "Info", "Debug"]
      name           = "sysLogsDataSource"
      streams        = ["Microsoft-Syslog"]
    }
  }
  description = "linux data collection rule"
}


resource "azurerm_monitor_data_collection_rule" "windows" {
  name                = "rule-nonprod-weu-windows"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location
  kind                = "Windows"

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
      name                  = "law-nonprod-weu-001-log"
    }
  }

  data_flow {
    streams       = ["Microsoft-Event"]
    destinations  = ["law-nonprod-weu-001-log"]
    output_stream = "Microsoft-Event"
    transform_kql = "source"
  }

  data_flow {
    streams       = ["Microsoft-Perf"]
    destinations  = ["law-nonprod-weu-001-log"]
    output_stream = "Microsoft-Perf"
    transform_kql = "source"
  }

  data_sources {
    windows_event_log {
      x_path_queries = ["Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0)]]", "System!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0)]]"]
      name           = "eventLogsDataSource"
      streams        = ["Microsoft-Event"]
    }

    performance_counter {
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers            = ["\\LogicalDisk(*)\\% Free Space"]
      name                          = "perfCounterDataSource60"
    }
  }
  description = "windows data collection rule"
}






resource "azurerm_monitor_data_collection_rule_association" "linux" {
  name                    = "dcra-linux"
  target_resource_id      = azurerm_linux_virtual_machine.test.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.linux.id
  description             = "test1-dcra"
}

resource "azurerm_monitor_data_collection_rule_association" "windows" {
  name                    = "dcra-windows"
  target_resource_id      = azurerm_windows_virtual_machine.windows.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.windows.id
  description             = "test2-dcra"
}



# az vm extension set --name AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor --ids "/subscriptions/cb3febcb-a417-42bf-b5bf-1c57da0bd9a4/resourceGroups/RG-IT-TVDV-TFEPOLICY/providers/Microsoft.Compute/virtualMachines/test-machine" --enable-auto-upgrade true





resource "azurerm_monitor_data_collection_endpoint" "file" {
  name                = "dce-file"
  resource_group_name = azurerm_resource_group.test.name
  location            = azurerm_resource_group.test.location

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_monitor_data_collection_rule_association" "file" {
  target_resource_id          = azurerm_windows_virtual_machine.windows.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.file.id
  description                 = "dcra-file"
}

resource "azurerm_monitor_data_collection_rule_association" "file2" {
  name                    = "dcra-file"
  target_resource_id      = azurerm_windows_virtual_machine.windows.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.file.id
  description             = "dcra-file"
}



resource "azurerm_monitor_data_collection_rule" "file" {
  name                        = "dcr-file"
  resource_group_name         = azurerm_resource_group.test.name
  location                    = azurerm_resource_group.test.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.file.id
  kind                        = "Windows"

  stream_declaration {
    stream_name = "Custom-Text-WindowsLogFiles_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "RawData"
      type = "string"
    }
    column {
      name = "FilePath"
      type = "string"
    }
    column {
      name = "Computer"
      type = "string"
    }
  }

  data_sources {
    log_file {
      name          = "Custom-Text-WindowsLogFiles_CL"
      format        = "text"
      streams       = ["Custom-Text-WindowsLogFiles_CL"]
      file_patterns = ["C:\\app\\app.log"]
      settings {
        text {
          record_start_timestamp_format = "ISO 8601"
        }
      }
    }
  }

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
      name                  = "la--0000"
    }
  }

  data_flow {
    streams       = ["Custom-Text-WindowsLogFiles_CL"]
    destinations  = ["la--0000"]
    output_stream = "Custom-WindowsLogFiles_CL"
    transform_kql = "source"
  }
}



resource "azurerm_monitor_data_collection_rule_association" "linuxfile" {
  target_resource_id          = azurerm_linux_virtual_machine.test.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.file.id
  description                 = "dcra-linuxfile"
}

resource "azurerm_monitor_data_collection_rule_association" "linuxfile2" {
  name                    = "dcra-linuxfile"
  target_resource_id      = azurerm_linux_virtual_machine.test.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.linuxfile.id
  description             = "dcra-linuxfile"
}


resource "azurerm_monitor_data_collection_rule" "linuxfile" {
  name                        = "dcr-linuxfile"
  resource_group_name         = azurerm_resource_group.test.name
  location                    = azurerm_resource_group.test.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.file.id
  kind                        = "Linux"

  stream_declaration {
    stream_name = "Custom-Text-WindowsLogFiles_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "RawData"
      type = "string"
    }
    column {
      name = "FilePath"
      type = "string"
    }
    column {
      name = "Computer"
      type = "string"
    }
  }

  data_sources {
    log_file {
      name          = "Custom-Text-WindowsLogFiles_CL"
      format        = "text"
      streams       = ["Custom-Text-WindowsLogFiles_CL"]
      file_patterns = ["/tmp/app.log"]
      settings {
        text {
          record_start_timestamp_format = "ISO 8601"
        }
      }
    }
  }

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
      name                  = "la--0000"
    }
  }

  data_flow {
    streams       = ["Custom-Text-WindowsLogFiles_CL"]
    destinations  = ["la--0000"]
    output_stream = "Custom-WindowsLogFiles_CL"
    transform_kql = "source"
  }
}


resource "azurerm_monitor_action_group" "group1" {
  name                = "ted"
  resource_group_name = azurerm_resource_group.test.name
  short_name          = "ted"
  enabled             = true

  email_receiver {
    name          = "xxxxx"
    email_address = "xxxxxx@xxxxx.com"
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "log_alert1" {
  name                 = "error"
  resource_group_name  = azurerm_resource_group.test.name
  location             = azurerm_resource_group.test.location
  scopes               = ["/subscriptions/cb3febcb-a417-42bf-b5bf-1c57da0bd9a4"]
  description          = "error"
  window_duration      = "PT5M"
  evaluation_frequency = "PT1M"
  severity             = 1

  criteria {
    query                   = <<-KQL
      WindowsLogFiles_CL|where RawData contains "-xxxxx-"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThanOrEqual"
    threshold               = 1
  }

  action {
    action_groups = [azurerm_monitor_action_group.group1.id]
  }
}



