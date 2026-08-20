# App Service managed identity → Azure AI Developer on the Foundry Project.
# Allows the web UI to invoke agents and read project resources.
resource "azurerm_role_assignment" "appservice_ai_developer" {
  scope                = azurerm_ai_foundry_project.main.id
  role_definition_name = "Azure AI Developer"
  principal_id         = azurerm_linux_web_app.item.identity.principal_id
}

# App Service managed identity → AcrPull on ACR.
# Needed if App Service ever pulls a container image directly; also useful for CI validation.
resource "azurerm_role_assignment" "appservice_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.item.identity.principal_id
}
