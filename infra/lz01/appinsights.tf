resource "azurerm_log_analytics_workspace" "main" {
  name                = "law${var.number}-lz01"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "main" {
  name                = "ai${var.number}-lz01"
  location            = module.lz_data.rg.location
  resource_group_name = module.lz_data.rg.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
}

# Connect App Insights to the Foundry project so Foundry emits server-side
# agent traces automatically — no code changes required in the agent.
# Uses azapi_update_resource to patch the project body without touching the
# main azapi_resource (which has ignore_changes = [body, output]).
resource "azapi_update_resource" "foundry_project_appinsights" {
  type        = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  resource_id = azapi_resource.foundry_project.id

  body = {
    properties = {
      applicationInsights = azurerm_application_insights.main.id
    }
  }
}

output "appinsights_connection_string" {
  value     = azurerm_application_insights.main.connection_string
  sensitive = true
}

output "appinsights_instrumentation_key" {
  value     = azurerm_application_insights.main.instrumentation_key
  sensitive = true
}
