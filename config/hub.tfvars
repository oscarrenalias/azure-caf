networks = [
  { name = "hub",         range = "10.0.0.0/16" },
  { name = "lz01",        range = "10.1.0.0/16" },
  { name = "lz02",        range = "10.2.0.0/16" },
  { name = "lz-platform", range = "10.3.0.0/16" },
]

network = "hub"

environment = "hub"


peerings = [
  { name = "hub-lz01",         source = "hub",         destination = "lz01"        },
  { name = "hub-lz02",         source = "hub",         destination = "lz02"        },
  { name = "hub-lz-platform",  source = "hub",         destination = "lz-platform" },
  { name = "lz01-hub",         source = "lz01",        destination = "hub"         },
  { name = "lz02-hub",         source = "lz02",        destination = "hub"         },
  { name = "lz-platform-hub",  source = "lz-platform", destination = "hub"         },

  # Spoke-to-spoke, and the only pair that has it. VNet peering is not transitive and
  # the firewall is off by default, so without this APIM in lz-platform cannot reach
  # the orders Function App's private endpoint in lz01 — the privatelink record for
  # <func>.azurewebsites.net resolves to 10.1.2.x from every VNet, but only a peered
  # VNet can route there. See infra/lz-platform/orders.tf.
  { name = "lz01-lz-platform",  source = "lz01",        destination = "lz-platform" },
  { name = "lz-platform-lz01",  source = "lz-platform", destination = "lz01"        },
]

subnets = [
  { name = "vm", prefix = "10.0.0.0/24" },
  { name = "AzureFirewallSubnet", prefix = "10.0.1.0/24" },
]