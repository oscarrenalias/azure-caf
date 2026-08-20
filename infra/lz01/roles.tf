resource "azurerm_user_assigned_identity" "appservice" {
  name                = "id-app${random_id.app_service.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
}

# App Service managed identity → Azure AI Developer on the Foundry Project.
# Allows the web UI to invoke agents and read project resources.
resource "azurerm_role_assignment" "appservice_ai_developer" {
  scope                = azurerm_ai_foundry_project.main.id
  role_definition_name = "Azure AI Developer"
  principal_id         = azurerm_user_assigned_identity.appservice.principal_id
}

# App Service managed identity → AcrPull on ACR.
resource "azurerm_role_assignment" "appservice_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.appservice.principal_id
}
