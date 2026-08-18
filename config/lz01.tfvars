lz  = "lz01"
hub = "hub"
subnets = [
  { name = "vm", prefix = "10.1.0.0/24", route = true },
  { name = "gw", prefix = "10.1.1.0/24", route = false },
  { name = "private-endpoint", prefix = "10.1.2.0/24", route = false },
  { name = "app-service-integration", prefix = "10.1.3.0/24", route = true, delegation = "Microsoft.Web/serverFarms" },
  { name = "ai-agents", prefix = "10.1.4.0/24", route = true, delegation = "Microsoft.App/environments" },
]

