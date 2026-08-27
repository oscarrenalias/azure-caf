lz  = "lz-platform"
hub = "hub"

subnets = [
  { name = "apim",             prefix = "10.3.0.0/24", route = false },
  { name = "private-endpoint", prefix = "10.3.1.0/24", route = false },
]

apim_publisher_name  = "AI Platform Team"
apim_publisher_email = "oscar.renalias@accenture.com"

# The orders Function App in lz01, which APIM fronts as a REST API and an MCP server.
# Leave empty until lz01 has been applied at least once, then fill it from:
#   terraform -chdir=infra/lz01 output -raw orders_function_name
# and re-apply lz-platform. Empty means orders.tf creates nothing at all, which is what
# a first-time deploy needs, since lz-platform is applied before lz01 exists.
orders_function_name = "func95aef3156f0f"
