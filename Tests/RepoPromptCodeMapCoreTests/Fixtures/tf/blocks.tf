terraform {
  required_version = ">= 1.10"

  backend "local" {
    path = "state/demo.tfstate"
  }

  required_providers {
    example = {
      source = "example/example"
    }
  }
}

provider "example" {
  alias  = "secondary"
  region = "local-2"
}

resource "example_bucket" "logs" {
  count    = 2
  provider = example.secondary
  name     = "logs-${count.index}"

  lifecycle {
    ignore_changes = [tags]
  }

  dynamic "rule" {
    for_each = var.rules
    content {
      action = rule.value
    }
  }
}

data "example_zone" "primary" {
  for_each = toset(var.zones)
  name     = each.key
}

resource "example_marker" "empty" {}

moved {
  from = example_bucket.old
  to   = example_bucket.logs
}

import {
  to = example_bucket.logs[0]
  id = "logs-0"
}

removed {
  from = example_bucket.legacy

  lifecycle {
    destroy = false
  }
}

check "health" {
  assert {
    condition     = true
    error_message = "Unreachable."
  }
}

variable "orphan" "extra" {
  type = string
}

widget "custom" {
  size = 3
}
