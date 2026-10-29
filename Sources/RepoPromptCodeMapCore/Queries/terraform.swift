// Registers Terraform with the query store and the pipeline identity, which hashes these bytes.
// `TerraformCodeMapStrategy` walks the same top-level blocks directly, so the engine never runs it.
let terraformCodeMapQuery = #"""
(config_file
  (body
    (block) @terraform.declaration))
"""#
