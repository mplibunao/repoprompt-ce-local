module "worker" {
  source = "../../modules/worker"
  count  = var.enabled ? 1 : 0

  project_id = var.project_id
  workers    = var.workers
  settings = {
    retries = 3
    timeout = "30s"
  }

  providers = {
    example = example.secondary
  }
  depends_on = [module.network]
}

module "network" {
  source  = "example-org/network/example"
  version = "~> 2.1"

  for_each                   = toset(["blue", "green"])
  name                       = each.key
  ignore_nested_deprecations = true
}

module "dns" {
  source = "${path.module}/modules/dns"
  zone   = "example.internal"
}

module "unsourced" {
  zone = "example.internal"
}

module "twice" {
  source = "./modules/a"
  source = "./modules/b"
}

module "accented" {
  source = "./modules/caf\u00e9"
}
