data "azurerm_private_dns_zone" "app_service" {
	name                = "privatelink.azurewebsites.net"
	resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_service_plan" "app_service" {
	name                = "asp${var.number}-${var.lz}"
	location            = module.lz_data.rg.location
	resource_group_name = module.lz_data.rg.name
	os_type             = "Linux"
	sku_name            = "S1"
}

resource "azurerm_linux_web_app" "item" {
	name                      = "app${var.number}-${var.lz}"
	location                  = module.lz_data.rg.location
	resource_group_name       = module.lz_data.rg.name
	service_plan_id           = azurerm_service_plan.app_service.id
	virtual_network_subnet_id = azurerm_subnet.item["app-service-integration"].id
	public_network_access_enabled = false
	https_only                = true

	site_config {
		application_stack {
			python_version = "3.12"
		}
	}
}

resource "azurerm_private_endpoint" "app_service" {
	name                = "pe-app-${var.lz}"
	location            = module.lz_data.rg.location
	resource_group_name = module.lz_data.rg.name
	subnet_id           = azurerm_subnet.item["private-endpoint"].id

	private_service_connection {
		name                           = "psc-app-${var.lz}"
		private_connection_resource_id = azurerm_linux_web_app.item.id
		subresource_names              = ["sites"]
		is_manual_connection           = false
	}

	private_dns_zone_group {
		name                 = "privatelink-azurewebsites"
		private_dns_zone_ids = [data.azurerm_private_dns_zone.app_service.id]
	}
}
