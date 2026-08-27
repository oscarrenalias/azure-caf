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

# Jump VM identity → Foundry User, which is the role the Toolbox documentation names
# for creating and calling toolboxes. Granted explicitly rather than assumed to be
# implied by Foundry Project Manager above: the toolbox is created from the jump host
# (app/toolbox/README.md), and a missing role there surfaces as an opaque 403.
resource "azurerm_role_assignment" "jump_vm_foundry_user" {
  scope                = azurerm_cognitive_account.foundry_hub.id
  role_definition_name = "Foundry User"
  principal_id         = data.azurerm_virtual_machine.jump.identity[0].principal_id
}

# Jump VM identity → upload content to the container. The storage account is
# private-endpoint only and has shared keys disabled, so ingestion runs from inside the
# VNet with `az storage blob upload --auth-mode login`, authenticating as this identity.
resource "azurerm_role_assignment" "jump_vm_storage_contributor" {
  scope                = azapi_resource.content.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_virtual_machine.jump.identity[0].principal_id
}

# AI Search identity → read the book content it indexes. The storage account has
# shared_access_key_enabled = false, so the indexer's data source authenticates as this
# identity rather than with a key.
resource "azurerm_role_assignment" "search_storage_reader" {
  scope                = azapi_resource.content.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_search_service.main.identity[0].principal_id
}

# AI Search identity → call the embedding model for integrated vectorization, both when
# indexing (the embedding skill) and at query time (the index's vectorizer).
resource "azurerm_role_assignment" "search_openai_user" {
  scope                = data.azurerm_cognitive_account.platform_foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_search_service.main.identity[0].principal_id
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

# Orders Function App identity → its deployment container and the Functions host's own
# bookkeeping blobs. Blob Data *Owner* rather than Contributor: with an identity-based
# AzureWebJobsStorage the host creates and leases its own containers, which Contributor
# does not permit, and the app then fails to start with a lease error that says nothing
# about permissions.
resource "azurerm_role_assignment" "functions_storage_blob_owner" {
  scope                = azapi_resource.content.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.functions.principal_id
}

# Orders Function App identity → read and write the orders table. This is the only
# write path to the system of record; nothing else is granted it.
resource "azurerm_role_assignment" "functions_storage_table_contributor" {
  scope                = azapi_resource.content.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.functions.principal_id
}

# Jump VM identity → read and write the orders table, so a developer can inspect or
# seed rows directly when a tool call misbehaves and it is unclear whether the fault is
# the API's or the agent's.
resource "azurerm_role_assignment" "jump_vm_storage_table_contributor" {
  scope                = azapi_resource.content.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = data.azurerm_virtual_machine.jump.identity[0].principal_id
}

# Foundry Project managed identity → Container Registry Repository Reader on ACR.
# Required for the Agent Service platform to pull the agent container image.
resource "azurerm_role_assignment" "foundry_project_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azapi_resource.foundry_project.output.identity.principalId
}
