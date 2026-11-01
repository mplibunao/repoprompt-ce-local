# Synthetic expressions. The outline lists declarations; references feed the graph.
module "worker" {
  source   = "./modules/worker"
  for_each = toset(var.zones)
  zone     = each.key
}

output "blue_endpoint" {
  value = module.worker["blue"].endpoint
}

output "endpoints" {
  value = [for instance in module.worker : instance.endpoint]
}

output "splat_endpoints" {
  value     = values(module.worker)[*].endpoint
  sensitive = false
}

locals {
  legacy_endpoint = module.worker.0.endpoint
  summary         = "${var.project}: %{ for zone in var.zones }${zone} %{ endfor }"
  banner          = <<EOT
Project ${var.project}
EOT
  by_module = { for module, settings in var.overrides : module => settings.size if settings.enabled }
}

resource "example_bucket" "logs" {
  provider = example.secondary
  name     = "${local.summary}-logs" # var.not_a_reference

  dynamic "rule" {
    for_each = var.rules
    content {
      action = rule.value.action
      zone   = data.example_zone.primary.id
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }
}
