resource "azurerm_user_assigned_identity" "appservice" {
  name                = "id-app${random_id.app_service.hex}"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
}

# GitHub Actions managed identity — needs Azure AI Developer to deploy agents via azd.
data "azurerm_user_assigned_identity" "github_actions" {
  name                = "mihubspoke${var.number}"
  resource_group_name = "rgmi${var.number}"
}

# Foundry Project Manager: includes Microsoft.CognitiveServices/* in dataActions,
# which covers AIServices/agents/write required by azd hosted agent deployment.
# Azure AI Developer only covers OpenAI/*, SpeechServices/*, ContentSafety/*, MaaS/*.
resource "azurerm_role_assignment" "github_actions_foundry_manager" {
  scope                = azurerm_cognitive_account.foundry_hub.id
  role_definition_name = "Foundry Project Manager"
  principal_id         = data.azurerm_user_assigned_identity.github_actions.principal_id
}

import {
  to = azurerm_role_assignment.appservice_ai_developer
  id = "/subscriptions/05b45b16-d05c-4322-8af3-5c839cedae36/resourceGroups/rg17872182643090-lz01/providers/Microsoft.CognitiveServices/accounts/hub45c2224c22f5/providers/Microsoft.Authorization/roleAssignments/25be65c5-544a-4eda-8edb-a3a15870b3af"
}

# App Service managed identity → Foundry Project Manager on the Foundry Hub.
# Azure AI Developer is insufficient to invoke hosted agent responses endpoints;
# Foundry Project Manager includes the broader data-plane actions needed.
resource "azurerm_role_assignment" "appservice_ai_developer" {
  scope                = azurerm_cognitive_account.foundry_hub.id
  role_definition_name = "Foundry Project Manager"
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
resource "azurerm_role_assignment" "foundry_project_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azapi_resource.foundry_project.output.identity.principalId
}
