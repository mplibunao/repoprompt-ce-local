# Terraform codemaps get their own artifact payload and tuple format

Status: accepted, 2026-10-28
Sources: `docs/ledgers/2026-10-28-terraform-codemaps.md`

## Context

Codemap artifacts are content-addressed and persisted. Their schema version is global, so a new persisted field invalidates every language's saved artifacts. The artifact models code: classes, interfaces, aliases, enums, functions, and the type names they declare and reference. Terraform has none of these. It declares variables, outputs, locals, resources, data sources, and module calls, and its names are scoped to a module folder: `project_id` in one folder is unrelated to `project_id` in another.

Graph contributions are persisted without paths in each root's manifest, and several producers rebuild them: the binding engine, the live overlay, the manifest writer, and the clean-manifest check. All of them must produce identical contributions.

## Decision

`CodeMapSyntaxArtifact` gains an optional `terraform` payload of declarations and references. The global `artifactSchemaVersion` goes from 1 to 2, which rebuilds every language's saved artifacts once, and the artifact container's version and summary layout change with it.

Terraform contribution names use one codec: `tf1:` followed by a compact canonical JSON array of strings, validated by decoding and exact re-encoding. Contributions hold unqualified tuples taken from source; the graph qualifies them by folder when it builds a snapshot, so a moved file reuses its artifact and contribution.

## Alternatives considered

- Encode Terraform declarations as classes and type names: no rebuild, but outlines would mislabel them, graph links would depend on unrelated filtering such as dropping classes with no members, and folder scoping would still need its own mechanism.
- A schema version per language: no rebuild for other languages, but a more complicated common artifact and container contract, with no evidence yet that the rebuild cost matters.

## Consequences

Terraform outlines and graph facts have an explicit model, and links are scoped by folder without changing how other languages match. Every user pays one cold rebuild of all codemaps after upgrading. A later change to Terraform extraction still bumps the pipeline versions, as for any language; the `tf1` prefix versions only the contribution encoding. Revisit if another language needs a payload of its own.
