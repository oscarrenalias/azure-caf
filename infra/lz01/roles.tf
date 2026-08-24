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

# Jump VM system-assigned identity → Foundry Project Manager on the Foundry Hub.
# Since the account went private-endpoint only, the jump host is where local development
# happens (`azd ai agent run`). Granting its identity means DefaultAzureCredential picks
# up the VM's managed identity over IMDS, so the dev loop needs no interactive az login.
data "azurerm_virtual_machine" "jump" {
  name                = "jump7"
  resource_group_name = "rg${var.number}-${var.hub}"
}

resource "azurerm_role_assignment" "jump_vm_foundry_manager" {
  scope                = azurerm_cognitive_account.foundry_hub.id
  role_definition_name = "Foundry Project Manager"
  principal_id         = data.azurerm_virtual_machine.jump.identity[0].principal_id
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
