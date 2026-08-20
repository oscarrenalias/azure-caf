# GitHub Actions managed identity — needs Azure AI Developer to deploy agents via azd.
data "azurerm_user_assigned_identity" "github_actions" {
  name                = "mihubspoke${var.number}"
  resource_group_name = "rgmi${var.number}"
}

resource "azurerm_role_assignment" "github_actions_ai_developer" {
  scope                = azapi_resource.foundry_project.id
  role_definition_name = "Azure AI Developer"
  principal_id         = data.azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_user_assigned_identity" "appservice" {
  name                = "id-app${random_id.app_service.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
}

# App Service managed identity → Azure AI Developer on the Foundry Project.
# Allows the web UI to invoke agents and read project resources.
resource "azurerm_role_assignment" "appservice_ai_developer" {
  scope                = azapi_resource.foundry_project.id
  role_definition_name = "Azure AI Developer"
  principal_id         = azurerm_user_assigned_identity.appservice.principal_id
}

# App Service managed identity → AcrPull on ACR.
resource "azurerm_role_assignment" "appservice_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.appservice.principal_id
}

# Foundry Project managed identity → Container Registry Repository Reader on ACR.
# Required for the Agent Service platform to pull the agent container image.
# Without this, deployment fails with image_pull_failed.
resource "azurerm_role_assignment" "foundry_project_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "Container Registry Repository Reader"
  principal_id         = azapi_resource.foundry_project.output.identity.principalId
}
