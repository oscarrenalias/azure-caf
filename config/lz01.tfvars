lz = "lz01"
hub = "hub"
subnets = [
  { name = "vm", prefix = "10.1.0.0/24", route = true, delegated = false },
  { name = "gw", prefix = "10.1.1.0/24", route = false, delegated = false },
  { name = "private-endpoint", prefix = "10.1.2.0/24", route = false, delegated = false },
  { name = "app-service-integration", prefix = "10.1.3.0/24", route = true, delegated = true },
]

