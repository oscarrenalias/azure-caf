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

# Connect App Insights to the Foundry project as a connection of category
# "AppInsights". The project-level `applicationInsights` property on the
# ARM resource is silently ignored by the API — connections are the correct
# path for this resource type.
#
# The connection string must be passed in metadata.ApplicationInsightsConnectionString.
# authType ProjectManagedIdentity means the Foundry platform authenticates
# using the project's system-assigned identity, which needs Monitoring Metrics
# Publisher on the App Insights resource (see role assignment below).
import {
  to = azapi_resource.foundry_appinsights_connection
  id = "/subscriptions/05b45b16-d05c-4322-8af3-5c839cedae36/resourceGroups/rg17872182643090-lz01/providers/Microsoft.CognitiveServices/accounts/hub823c59bbefea/projects/proj823c59bbefea/connections/app-insights"
}

import {
  to = azurerm_role_assignment.foundry_project_appinsights
  id = "/subscriptions/05b45b16-d05c-4322-8af3-5c839cedae36/resourceGroups/rg17872182643090-lz01/providers/microsoft.insights/components/ai17872182643090-lz01/providers/Microsoft.Authorization/roleAssignments/c8791d48-8b04-4c86-a631-0a65ac99842e"
}

resource "azapi_resource" "foundry_appinsights_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = "app-insights"
  parent_id = azapi_resource.foundry_project.id

  # azapi's bundled schema predates ProjectManagedIdentity authType — disable
  # validation so it passes the value through rather than rejecting it.
  schema_validation_enabled = false

  body = {
    properties = {
      category     = "AppInsights"
      target       = azurerm_application_insights.main.id
      authType     = "ProjectManagedIdentity"
      isSharedToAll = true
      metadata = {
        ApplicationInsightsConnectionString = azurerm_application_insights.main.connection_string
      }
    }
  }

  lifecycle {
    ignore_changes = [body]
  }
}

# The project's system-assigned identity writes traces to App Insights.
resource "azurerm_role_assignment" "foundry_project_appinsights" {
  scope                = azurerm_application_insights.main.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azapi_resource.foundry_project.output.identity.principalId
}

output "appinsights_connection_string" {
  value     = azurerm_application_insights.main.connection_string
  sensitive = true
}

output "appinsights_instrumentation_key" {
  value     = azurerm_application_insights.main.instrumentation_key
  sensitive = true
}
