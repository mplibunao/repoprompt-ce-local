# Synthetic module interface for codemap tests.
variable "project_id" {
  type        = string
  description = "Project that owns every resource."
}

variable "workers" {
  description = "Worker pools keyed by name."
  type = map(object({
    image       = string
    concurrency = optional(number, 4)
    labels      = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = length(var.workers) < 10
    error_message = "Keep fewer than ten worker pools."
  }
}

variable "api_token" {
  type      = string
  sensitive = true
  nullable  = false
  ephemeral = true
}

variable "region" {
  const   = true
  default = "local-1"
}

output "endpoint" {
  description = "Public endpoint of the first worker."
  value       = module.worker[0].endpoint
}

output "token_hint" {
  value     = "${var.api_token}-hint"
  sensitive = true
  ephemeral = true
}

locals {
  name_prefix  = "demo-${var.project_id}"
  worker_names = [for name, pool in var.workers : "${local.name_prefix}-${name}"]
}

locals {}
