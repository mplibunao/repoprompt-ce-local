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

        XCTAssertEqual(try declarations(in: source), try [
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
            case declarations([TerraformCodeMapDeclaration])
        }
        let repairedVariable = try TerraformCodeMapDeclaration(
            kind: .variable,
            blockType: "variable",
            labels: ["name"],
            lineNumber: 1,
            attributes: [TerraformOutlineAttribute(name: "type", valueText: "string")]
        )
        let heredocLocal = try TerraformCodeMapDeclaration(
            kind: .local,
            blockType: "locals",
            labels: ["greeting"],
            lineNumber: 2
        )
        let rows: [(name: String, source: String, expected: Expected)] = [
            ("broken braces", "variable \"name\" {\n  type = string\n", .invalidSyntax),
            ("broken template", "locals {\n  greeting = \"${name\"\n}\n", .invalidSyntax),
            ("repaired content", "variable \"name\" {\n  type = string\n}\n", .declarations([repairedVariable])),
            ("empty file", "", .declarations([])),
            ("comment-only file", "# note\n// note\n/* note */\n", .declarations([])),
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
                .declarations([heredocLocal])
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
            case let .ready(artifact): artifact.terraform.map { .declarations($0.declarations) }
            default: nil
            }
            XCTAssertEqual(observed, row.expected, "\(row.name): \(outcome)")
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
            XCTAssertEqual(try declarations(in: variant), expected, name)
        }
    }

    private func declarations(in source: String) throws -> [TerraformCodeMapDeclaration] {
        let outcome = try CodeMapSyntaxArtifactBuilder.build(
            source: CodeMapFixtureRunner.makeSourceSnapshot(content: source),
            language: .terraform
        )
        guard case let .ready(artifact) = outcome, let terraform = artifact.terraform else {
            XCTFail("Expected a ready Terraform artifact, got \(outcome)")
            return []
        }
        return terraform.declarations
    }
}
