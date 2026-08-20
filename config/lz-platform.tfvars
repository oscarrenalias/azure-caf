lz  = "lz-platform"
hub = "hub"

subnets = [
  { name = "apim",             prefix = "10.3.0.0/24", route = false },
  { name = "private-endpoint", prefix = "10.3.1.0/24", route = false },
]

apim_publisher_name  = "AI Platform Team"
apim_publisher_email = "oscar.renalias@accenture.com"
