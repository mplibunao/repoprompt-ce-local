import XCTest
@testable import RepoPromptCodeMapCore

final class TerraformCodeMapTests: XCTestCase {
    func testOutlinePreservesTopLevelDeclarationsAndTypes() throws {
        let source = """
        variable "pools" {
          type = map(object({
            image = string
            size  = optional(number, 2)
          }))
        }

        module "pool" {
          source = "./pool"
          pools  = var.pools
          extra = {
            image = "nested-key"
          }
          depends_on = []
        }

        resource "example_service" "api" {
          count = 1

          dynamic "port" {
            for_each = [80]
            content {
              number = port.value
            }
          }

          lifecycle {
            create_before_destroy = true
          }
        }

        locals {
          region = "local-1"
          zones  = ["a"]
        }
        """

        XCTAssertEqual(try terraformArtifact(in: source).declarations, try [
            TerraformCodeMapDeclaration(
                kind: .variable,
                blockType: "variable",
                labels: ["pools"],
                lineNumber: 1,
                attributes: [TerraformOutlineAttribute(
                    name: "type",
                    valueText: "map(object({\n    image = string\n    size  = optional(number, 2)\n  }))"
                )]
            ),
            TerraformCodeMapDeclaration(
                kind: .module,
                blockType: "module",
                labels: ["pool"],
                lineNumber: 8,
                moduleSource: .literal("./pool"),
                argumentNames: ["extra", "pools"]
            ),
            TerraformCodeMapDeclaration(
                kind: .resource,
                blockType: "resource",
                labels: ["example_service", "api"],
                lineNumber: 17,
                attributes: [TerraformOutlineAttribute(name: "count", valueText: "1")]
            ),
            TerraformCodeMapDeclaration(kind: .local, blockType: "locals", labels: ["region"], lineNumber: 33),
            TerraformCodeMapDeclaration(kind: .local, blockType: "locals", labels: ["zones"], lineNumber: 34)
        ])
    }

    func testOutcomePolicy() throws {
        enum Expected: Equatable {
            case invalidSyntax
            case ready(TerraformCodeMapArtifact)
        }
        let repaired = try TerraformCodeMapArtifact(
            declarations: [TerraformCodeMapDeclaration(kind: .output, blockType: "output", labels: ["name"], lineNumber: 1)],
            references: [TerraformCodeMapReference(kind: .variable, parts: ["name"])]
        )
        let empty = TerraformCodeMapArtifact(declarations: [], references: [])
        let heredocLocal = try TerraformCodeMapDeclaration(
            kind: .local,
            blockType: "locals",
            labels: ["greeting"],
            lineNumber: 2
        )
        let rows: [(name: String, source: String, expected: Expected)] = [
            ("broken braces", "output \"name\" {\n  value = var.name\n", .invalidSyntax),
            ("broken template", "locals {\n  greeting = \"${name\"\n}\n", .invalidSyntax),
            ("repaired content", "output \"name\" {\n  value = var.name\n}\n", .ready(repaired)),
            ("empty file", "", .ready(empty)),
            ("comment-only file", "# note\n// note\n/* note */\n", .ready(empty)),
            ("JSON-style root", #"{ "variable": { "name": {} } }"#, .invalidSyntax),
            ("escape naming no Unicode scalar, in a label", #"variable "bad\uD800" {}"#, .invalidSyntax),
            (
                "escape naming no Unicode scalar, in a template value",
                #"locals {\#n  greeting = "${name}\uD800"\#n}\#n"#,
                .invalidSyntax
            ),
            (
                "escape naming no Unicode scalar, in a top-level attribute",
                #"ignored = "\uD800"\#nvariable "name" {}\#n"#,
                .invalidSyntax
            ),
            // A heredoc doesn't process backslash escapes, so the same text is valid there.
            (
                "escape-like text in a heredoc",
                #"locals {\#n  greeting = <<EOT\#n\uD800\#nEOT\#n}\#n"#,
                .ready(TerraformCodeMapArtifact(declarations: [heredocLocal], references: []))
            ),
            // The pinned grammar's scanner can't match a non-ASCII heredoc identifier, so the file
            // fails explicitly. A grammar upgrade that fixes the scanner changes this expectation.
            ("non-ASCII heredoc identifier", "locals {\n  greeting = <<ÉTÉ\nhello\nÉTÉ\n}\n", .invalidSyntax)
        ]

        for row in rows {
            let outcome = try CodeMapSyntaxArtifactBuilder.build(
                source: CodeMapFixtureRunner.makeSourceSnapshot(content: row.source),
                language: .terraform
            )
            let observed: Expected? = switch outcome {
            case .parseFailed(.invalidTerraformSyntax): .invalidSyntax
            case let .ready(artifact): artifact.terraform.map { .ready($0) }
            default: nil
            }
            XCTAssertEqual(observed, row.expected, "\(row.name): \(outcome)")
        }
    }

    func testTraversalExtractionRespectsInstancesTemplatesAndLexicalScopes() throws {
        let worker = try reference(.moduleCall, "worker")
        let endpoint = try reference(.moduleOutput, "worker", "endpoint")
        let rows: [(name: String, source: String, expected: Set<TerraformCodeMapReference>)] = try [
            ("module output", output("module.worker.endpoint"), [worker, endpoint]),
            ("numeric instance key", output("module.worker[0].endpoint"), [worker, endpoint]),
            ("string instance key", output(#"module.worker["blue"].endpoint"#), [worker, endpoint]),
            ("each instance key", output("module.worker[each.key].endpoint"), [worker, endpoint]),
            ("legacy numeric index", output("module.worker.0.endpoint"), [worker, endpoint]),
            ("full splat", output("module.worker[*].endpoint"), [worker, endpoint]),
            ("attribute splat", output("module.worker.*.endpoint"), [worker, endpoint]),
            ("indexing after the output", output(#"module.worker.endpoint["blue"]"#), [worker, endpoint]),
            ("instance key without an output", output(#"module.worker["blue"]"#), [worker]),
            ("function result", output("values(module.worker)[*].endpoint"), [worker]),
            (
                "parenthesized traversal",
                output("[(module.worker).endpoint, ((module.worker))[0].status]"),
                [worker, endpoint, reference(.moduleOutput, "worker", "status")]
            ),
            ("for over a call", output("[for instance in module.worker : instance.endpoint]"), [worker]),
            (
                "roots",
                output("[var.region, local.prefix, data.example_zone.primary.id, example_bucket.logs.arn]"),
                [
                    reference(.variable, "region"),
                    reference(.local, "prefix"),
                    reference(.data, "example_zone", "primary"),
                    reference(.resource, "example_bucket", "logs")
                ]
            ),
            (
                "explicit resource prefix",
                output("[resource.example_bucket.logs.arn, resource.example_bucket]"),
                [reference(.resource, "example_bucket", "logs")]
            ),
            (
                "context and ephemeral roots",
                output("[each.value, count.index, self.id, path.module, terraform.workspace, ephemeral.example_token.session]"),
                []
            ),
            (
                "index expressions and operands without an expression wrapper",
                output("-var.list[local.position] + var.offset * 2"),
                [reference(.variable, "list"), reference(.local, "position"), reference(.variable, "offset")]
            ),
            (
                "interpolation and directives",
                output(#""${var.name}-%{ if var.enabled }${local.suffix}%{ endif }""#),
                [reference(.variable, "name"), reference(.variable, "enabled"), reference(.local, "suffix")]
            ),
            (
                "heredoc interpolation",
                """
                output "o" {
                  value = <<EOT
                ${example_bucket.logs.id}
                EOT
                }
                """,
                [reference(.resource, "example_bucket", "logs")]
            ),
            (
                "template for binds its name in its body",
                output(#""%{ for name in var.names }${name.upper}%{ endfor }""#),
                [reference(.variable, "names")]
            ),
            (
                "binder named module",
                output("[for module in var.modules : module.worker.endpoint]"),
                [reference(.variable, "modules")]
            ),
            (
                "nested binders that reuse a name",
                output(
                    "[[for module in var.outer : [[for module in var.inner : module.inner.id], module.outer.id]], module.real.endpoint]"
                ),
                [
                    reference(.variable, "outer"),
                    reference(.variable, "inner"),
                    reference(.moduleCall, "real"),
                    reference(.moduleOutput, "real", "endpoint")
                ]
            ),
            (
                "for binds its body and filter, not its collection",
                output("{ for key, value in value.items : key => value.id if value.enabled }"),
                [reference(.resource, "value", "items")]
            ),
            (
                "comments and strings",
                """
                output "o" {
                  # var.commented module.fake.output
                  value = "var.quoted ${local.real} module.fake.output" // example_bucket.commented
                }
                """,
                [reference(.local, "real")]
            ),
            (
                "dynamic block with its default iterator",
                """
                resource "example_bucket" "logs" {
                  dynamic "rule" {
                    for_each = rule.seeds
                    labels   = [rule.key]
                    content {
                      action = rule.value
                      target = local.target
                    }
                  }
                }
                """,
                [reference(.resource, "rule", "seeds"), reference(.local, "target")]
            ),
            (
                "dynamic block with an explicit iterator",
                """
                resource "example_bucket" "logs" {
                  dynamic "rule" {
                    for_each = var.rules
                    iterator = item
                    content {
                      action = item.value
                    }
                  }
                }
                """,
                [reference(.variable, "rules")]
            ),
            (
                "provider positions, lifecycle paths, and action triggers",
                """
                resource "example_bucket" "logs" {
                  provider = example.secondary
                  name     = local.bucket_name
                  lifecycle {
                    ignore_changes       = [tags, example_tag.name]
                    replace_triggered_by = [example_marker.trigger.id]
                    action_trigger {
                      events  = [after_create]
                      actions = [action.example_action.notify[var.notify_index]]
                    }
                  }
                  depends_on = [module.network]
                }

                module "worker" {
                  source    = "./worker"
                  providers = { example = example.secondary }
                }
                """,
                [
                    reference(.local, "bucket_name"),
                    reference(.resource, "example_marker", "trigger"),
                    reference(.variable, "notify_index"),
                    reference(.moduleCall, "network")
                ]
            ),
            (
                "provider names outside selector positions",
                """
                locals {
                  provider  = var.provider_config
                  providers = local.provider_settings
                }

                module "worker" {
                  source   = "./worker"
                  provider = var.provider_input
                }
                """,
                [
                    reference(.variable, "provider_config"),
                    reference(.local, "provider_settings"),
                    reference(.variable, "provider_input")
                ]
            ),
            (
                "provider selectors in check, ephemeral, action, and import blocks",
                """
                check "health" {
                  data "example_endpoint" "probe" {
                    provider = example.secondary
                    url      = var.url
                  }
                }

                ephemeral "example_token" "session" {
                  provider = example.secondary
                }

                action "example_action" "notify" {
                  provider = example.secondary
                  config {
                    message = var.message
                  }
                }

                import {
                  to       = example_bucket.logs
                  id       = "logs"
                  provider = example.secondary
                }
                """,
                [
                    reference(.variable, "url"),
                    reference(.variable, "message"),
                    reference(.resource, "example_bucket", "logs")
                ]
            ),
            (
                "variable type constraint",
                """
                variable "pools" {
                  type    = list(example_type.shape)
                  default = local.fallback
                  validation {
                    condition = length(var.pools) > 0
                  }
                }
                """,
                [reference(.local, "fallback"), reference(.variable, "pools")]
            ),
            (
                "moved, import, and removed addresses",
                """
                moved {
                  from = module.legacy.example_bucket.logs
                  to   = module.storage.example_bucket.logs
                }

                moved {
                  from = example_queue.pool["green"]
                  to   = resource.example_queue.jobs["blue"]
                }

                import {
                  for_each = var.bucket_ids
                  to       = example_bucket.imported[each.key]
                  id       = "logs-${each.value}"
                }

                removed {
                  from = example_bucket.legacy
                }
                """,
                [
                    reference(.moduleCall, "legacy"),
                    reference(.moduleCall, "storage"),
                    reference(.resource, "example_queue", "pool"),
                    reference(.resource, "example_queue", "jobs"),
                    reference(.variable, "bucket_ids"),
                    reference(.resource, "example_bucket", "imported")
                ]
            ),
            (
                "removed addresses keep only a module call they continue past",
                """
                removed {
                  from = module.storage.example_bucket.legacy
                }

                removed {
                  from = module.archive
                }

                removed {
                  from = example_bucket.retired
                }
                """,
                [reference(.moduleCall, "storage")]
            ),
            (
                "terraform block",
                """
                terraform {
                  required_version = ">= 1.10"
                  required_providers {
                    example = {
                      source                = "example/example"
                      configuration_aliases = [example.secondary]
                    }
                  }
                }
                """,
                []
            ),
            (
                "top-level attribute",
                """
                stray = var.ignored
                output "o" {
                  value = var.kept
                }
                """,
                [reference(.variable, "kept")]
            )
        ]

        for row in rows {
            XCTAssertEqual(try Set(terraformArtifact(in: row.source).references), row.expected, row.name)
        }
    }

    func testUnicodeAndLineEndingsPreserveRanges() throws {
        // Each emoji is one Character but two UTF-16 units, so offsets read in the wrong unit
        // shift every later slice and line number.
        let source = """
        # 🚀🚀🚀🚀🚀🚀🚀🚀 émoji ahead of every declaration
        variable "naïve_größe" {
          type = map(object({
            größe = number
          }))
        }

        locals {
          café = "☕"
          ñ    = 1
        }
        """
        let expected = try [
            TerraformCodeMapDeclaration(
                kind: .variable,
                blockType: "variable",
                labels: ["naïve_größe"],
                lineNumber: 2,
                attributes: [TerraformOutlineAttribute(name: "type", valueText: "map(object({\n    größe = number\n  }))")]
            ),
            TerraformCodeMapDeclaration(kind: .local, blockType: "locals", labels: ["café"], lineNumber: 9),
            TerraformCodeMapDeclaration(kind: .local, blockType: "locals", labels: ["ñ"], lineNumber: 10)
        ]

        for (name, variant) in [("LF", source), ("CRLF", source.replacingOccurrences(of: "\n", with: "\r\n"))] {
            XCTAssertEqual(try terraformArtifact(in: variant).declarations, expected, name)
        }
    }

    private func terraformArtifact(in source: String) throws -> TerraformCodeMapArtifact {
        let outcome = try CodeMapSyntaxArtifactBuilder.build(
            source: CodeMapFixtureRunner.makeSourceSnapshot(content: source),
            language: .terraform
        )
        guard case let .ready(artifact) = outcome, let terraform = artifact.terraform else {
            XCTFail("Expected a ready Terraform artifact, got \(outcome)")
            return TerraformCodeMapArtifact(declarations: [], references: [])
        }
        return terraform
    }

    /// A file whose only declaration is an output with `expression` as its value.
    private func output(_ expression: String) -> String {
        """
        output "o" {
          value = \(expression)
        }
        """
    }

    private func reference(_ kind: TerraformReferenceKind, _ parts: String...) throws -> TerraformCodeMapReference {
        try TerraformCodeMapReference(kind: kind, parts: parts)
    }
}
