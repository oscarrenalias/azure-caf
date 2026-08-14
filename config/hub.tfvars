networks = [
  { name = "hub", range = "10.0.0.0/16" },
  { name = "lz01", range = "10.1.0.0/16" },
  { name = "lz02", range = "10.2.0.0/16" },
]

network = "hub"

environment = "hub"


peerings = [
  { name = "hub-lz01", source = "hub", destination = "lz01" },
  { name = "hub-lz02", source = "hub", destination = "lz02" },
  { name = "lz01-hub", source = "lz01", destination = "hub" },
  { name = "lz02-hub", source = "lz02", destination = "hub" },
]

subnets = [
  { name = "vm", prefix = "10.0.0.0/24" },
  { name = "fw", prefix = "10.0.1.0/24" },
]