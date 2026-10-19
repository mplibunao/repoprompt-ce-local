import CryptoKit
import Foundation

package enum DomainWorkspaceStoragePath {
    package static func directoryName(name: String, id: UUID) -> String {
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Workspace-\(safeName)-\(id.uuidString)"
    }
}

package struct DomainContextIdentity: Codable, Hashable {
    package let workspaceID: UUID
    package let contextID: UUID

    package init(workspaceID: UUID, contextID: UUID) {
        self.workspaceID = workspaceID
        self.contextID = contextID
    }
}

package struct DomainRevisionState: Codable, Equatable {
    package let workingRevision: UInt64
    package let savedRevision: UInt64
    package let dirtyRevision: UInt64?

    package init(workingRevision: UInt64, savedRevision: UInt64, dirtyRevision: UInt64?) {
        self.workingRevision = workingRevision
        self.savedRevision = savedRevision
        self.dirtyRevision = dirtyRevision
    }

    package static let initial = DomainRevisionState(
        workingRevision: 0,
        savedRevision: 0,
        dirtyRevision: nil
    )
}

package enum DomainAuthorityHealth: Codable, Equatable {
    case writable
    case externalConflict(reason: String)
    case degradedReadOnly(reason: String)
    case removed

    package var acceptsMutations: Bool {
        if case .writable = self { return true }
        return false
    }

    package var reason: String? {
        switch self {
        case .writable:
            nil
        case let .externalConflict(reason), let .degradedReadOnly(reason):
            reason
        case .removed:
            "workspace_removed"
        }
    }
}

package enum DomainWorkspaceTabLocation: String, Codable, Equatable, Hashable, Sendable {
    case composed
    case stashed
}

package struct DomainProtectedAgentIdentity: Codable, Equatable, Hashable, Sendable {
    package let tabID: UUID
    package let location: DomainWorkspaceTabLocation
    package let activeAgentSessionID: UUID?
    package let isPinned: Bool

    package init(
        tabID: UUID,
        location: DomainWorkspaceTabLocation,
        activeAgentSessionID: UUID?,
        isPinned: Bool
    ) {
        self.tabID = tabID
        self.location = location
        self.activeAgentSessionID = activeAgentSessionID
        self.isPinned = isPinned
    }

    package var requiresProtection: Bool {
        activeAgentSessionID != nil || isPinned
    }
}

package struct DomainContextMetadata: Codable, Equatable {
    package let identity: DomainContextIdentity
    package let name: String
    package let activeAgentSessionID: UUID?
    package let activeChatSessionID: UUID?
    package let documentBytes: Data
    package let contentDigest: String

    package init(
        identity: DomainContextIdentity,
        name: String,
        activeAgentSessionID: UUID?,
        activeChatSessionID: UUID?,
        documentBytes: Data,
        contentDigest: String
    ) {
        self.identity = identity
        self.name = name
        self.activeAgentSessionID = activeAgentSessionID
        self.activeChatSessionID = activeChatSessionID
        self.documentBytes = documentBytes
        self.contentDigest = contentDigest
    }
}

package struct DomainWorkspaceMetadata: Codable, Equatable {
    package let workspaceID: UUID
    package let schemaVersion: Int
    package let name: String
    package let repoPaths: [String]
    package let customStoragePath: URL?
    package let isSystemWorkspace: Bool
    package let isHiddenInMenus: Bool
    package let consolidatedIntoWorkspaceID: UUID?
    package let isEphemeral: Bool
    package let activeContextID: UUID?
    package let contexts: [DomainContextMetadata]
    package let agentIdentityClaims: [DomainProtectedAgentIdentity]

    package init(
        workspaceID: UUID,
        schemaVersion: Int,
        name: String,
        repoPaths: [String],
        customStoragePath: URL?,
        isSystemWorkspace: Bool,
        isHiddenInMenus: Bool,
        consolidatedIntoWorkspaceID: UUID? = nil,
        isEphemeral: Bool,
        activeContextID: UUID?,
        contexts: [DomainContextMetadata],
        agentIdentityClaims: [DomainProtectedAgentIdentity] = []
    ) {
        self.workspaceID = workspaceID
        self.schemaVersion = schemaVersion
        self.name = name
        self.repoPaths = repoPaths
        self.customStoragePath = customStoragePath
        self.isSystemWorkspace = isSystemWorkspace
        self.isHiddenInMenus = isHiddenInMenus
        self.consolidatedIntoWorkspaceID = consolidatedIntoWorkspaceID
        self.isEphemeral = isEphemeral
        self.activeContextID = activeContextID
        self.contexts = contexts
        self.agentIdentityClaims = agentIdentityClaims
    }
}

package struct DomainWorkspaceDocument: Codable, Equatable {
    package let workspaceID: UUID
    package let fileURL: URL
    package let documentBytes: Data
    package let contentDigest: String
    package let metadata: DomainWorkspaceMetadata
    /// The summary fields `metadata` lacks, parsed from `documentBytes` in the same pass. They are
    /// derived from the bytes, so the coded form leaves them out and decoding derives them again.
    let summaryFields: DomainWorkspaceSummaryFields

    private init(
        workspaceID: UUID,
        fileURL: URL,
        documentBytes: Data,
        contentDigest: String,
        metadata: DomainWorkspaceMetadata,
        summaryFields: DomainWorkspaceSummaryFields
    ) {
        self.workspaceID = workspaceID
        self.fileURL = fileURL
        self.documentBytes = documentBytes
        self.contentDigest = contentDigest
        self.metadata = metadata
        self.summaryFields = summaryFields
    }

    package static func decode(documentBytes: Data, fileURL: URL) throws -> DomainWorkspaceDocument {
        let decoded = try DomainWorkspaceDocumentDecoder.decode(from: documentBytes)
        return DomainWorkspaceDocument(
            workspaceID: decoded.metadata.workspaceID,
            fileURL: fileURL,
            documentBytes: documentBytes,
            contentDigest: DomainContentDigest.sha256(documentBytes),
            metadata: decoded.metadata,
            summaryFields: decoded.summaryFields
        )
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case fileURL
        case documentBytes
        case contentDigest
        case metadata
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let documentBytes = try container.decode(Data.self, forKey: .documentBytes)
        try self.init(
            workspaceID: container.decode(UUID.self, forKey: .workspaceID),
            fileURL: container.decode(URL.self, forKey: .fileURL),
            documentBytes: documentBytes,
            contentDigest: container.decode(String.self, forKey: .contentDigest),
            metadata: container.decode(DomainWorkspaceMetadata.self, forKey: .metadata),
            summaryFields: (try? DomainWorkspaceDocumentDecoder.decode(from: documentBytes).summaryFields) ?? .empty
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(documentBytes, forKey: .documentBytes)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encode(metadata, forKey: .metadata)
    }
}

/// One compose or stashed tab of a workspace document, as listed without decoding the document's
/// app models. It is discovery information: it doesn't prove that the app decode keeps the tab.
package struct DomainTabSummary: Equatable, Hashable {
    package let tabID: UUID
    package let location: DomainWorkspaceTabLocation
    package let name: String
    package let activeAgentSessionID: UUID?
    package let activeChatSessionID: UUID?
    package let isPinned: Bool
    /// The stash wrapper's own ID, when the wrapper carries a valid one.
    package let stashID: UUID?
    /// When the wrapper says the tab was stashed, when it carries a numeric date.
    package let stashedAt: Date?
    /// SHA-256 of the tab's JSON object serialized with sorted keys, the digest
    /// `DomainContextMetadata.contentDigest` uses for compose tabs.
    package let contentDigest: String
    /// SHA-256 of the tab's stored `selection` value serialized the same way.
    package let selectionDigest: String
}

/// The summary fields of a workspace document that `DomainWorkspaceMetadata` doesn't carry.
struct DomainWorkspaceSummaryFields: Equatable {
    let dateModified: Date
    let lastUsed: Date
    let composeTabs: [DomainTabSummary]
    let stashedTabs: [DomainTabSummary]

    static let empty = DomainWorkspaceSummaryFields(
        dateModified: .distantPast,
        lastUsed: .distantPast,
        composeTabs: [],
        stashedTabs: []
    )
}

/// A workspace as the catalog lists it: identity, display metadata, tab summaries, and authority
/// state, without the document bytes or any decoded app model. It is deliberately not `Codable`, so
/// no encoder or save path can accept it in place of a complete document.
package struct DomainWorkspaceSummary: Equatable, Identifiable {
    package let workspaceID: UUID
    package let schemaVersion: Int
    package let name: String
    package let repoPaths: [String]
    package let customStoragePath: URL?
    package let isSystemWorkspace: Bool
    package let isHiddenInMenus: Bool
    package let consolidatedIntoWorkspaceID: UUID?
    package let isEphemeral: Bool
    /// A numeric date in the document, read the way `JSONDecoder` does by default; a missing or
    /// invalid one reads as `Date.distantPast`, so every read of the same bytes agrees.
    package let dateModified: Date
    package let lastUsed: Date
    package let activeContextID: UUID?
    package let composeTabs: [DomainTabSummary]
    package let stashedTabs: [DomainTabSummary]
    package let fileURL: URL
    package let contentDigest: String
    package let revisions: DomainRevisionState
    package let health: DomainAuthorityHealth

    package var id: UUID {
        workspaceID
    }

    package init(document: DomainWorkspaceDocument, revisions: DomainRevisionState, health: DomainAuthorityHealth) {
        let metadata = document.metadata
        workspaceID = document.workspaceID
        schemaVersion = metadata.schemaVersion
        name = metadata.name
        repoPaths = metadata.repoPaths
        customStoragePath = metadata.customStoragePath
        isSystemWorkspace = metadata.isSystemWorkspace
        isHiddenInMenus = metadata.isHiddenInMenus
        consolidatedIntoWorkspaceID = metadata.consolidatedIntoWorkspaceID
        isEphemeral = metadata.isEphemeral
        dateModified = document.summaryFields.dateModified
        lastUsed = document.summaryFields.lastUsed
        activeContextID = metadata.activeContextID
        composeTabs = document.summaryFields.composeTabs
        stashedTabs = document.summaryFields.stashedTabs
        fileURL = document.fileURL
        contentDigest = document.contentDigest
        self.revisions = revisions
        self.health = health
    }
}

package struct DomainContextSnapshot: Codable, Equatable {
    package let metadata: DomainContextMetadata
    package let revisions: DomainRevisionState
    package let health: DomainAuthorityHealth
}

package struct DomainWorkspaceSnapshot: Codable, Equatable {
    package let document: DomainWorkspaceDocument
    package let revisions: DomainRevisionState
    package let health: DomainAuthorityHealth
    package let contexts: [DomainContextSnapshot]

    package var summary: DomainWorkspaceSummary {
        DomainWorkspaceSummary(document: document, revisions: revisions, health: health)
    }
}

package struct DomainWorkspaceCatalogSnapshot: Equatable {
    package let runtimeIdentity: DomainRuntimeIdentity
    package let isBootstrapped: Bool
    package let publicationSequence: UInt64
    package let catalogRevision: UInt64
    package let health: DomainAuthorityHealth
    package let workspaces: [DomainWorkspaceSnapshot]

    package init(
        runtimeIdentity: DomainRuntimeIdentity,
        isBootstrapped: Bool,
        publicationSequence: UInt64,
        catalogRevision: UInt64,
        health: DomainAuthorityHealth,
        workspaces: [DomainWorkspaceSnapshot]
    ) {
        self.runtimeIdentity = runtimeIdentity
        self.isBootstrapped = isBootstrapped
        self.publicationSequence = publicationSequence
        self.catalogRevision = catalogRevision
        self.health = health
        self.workspaces = workspaces
    }
}

package enum DomainWorkspaceEventKind: String, Codable {
    case bootstrapped
    case workspaceCreated
    case workspaceDeleted
    case workingStateCommitted
    case savedDocumentCommitted
    case externalReloaded
    case externalConflict
    case degraded
    case routingChanged
    case operationDeduplicated
}

package struct DomainWorkspaceEvent: Codable, Equatable {
    package let runtimeID: UUID
    package let sequence: UInt64
    package let catalogRevision: UInt64
    package let kind: DomainWorkspaceEventKind
    package let workspaceID: UUID?
    package let contextID: UUID?
    package let operationID: UUID?
    package let origin: DomainCommandOrigin?
    package let revisions: DomainRevisionState?
    package let timestamp: Date
    package let diagnostic: String?
}

package struct DomainWorkspaceSnapshotSubscription {
    package let snapshot: DomainWorkspaceCatalogSnapshot
    package let events: AsyncStream<DomainWorkspaceEvent>
}

/// The catalog as summaries. It never carries document bytes, so a reader that lists workspaces
/// doesn't receive every workspace's full document.
package struct DomainWorkspaceSummaryCatalogSnapshot: Equatable {
    package let runtimeIdentity: DomainRuntimeIdentity
    package let isBootstrapped: Bool
    package let publicationSequence: UInt64
    package let catalogRevision: UInt64
    package let health: DomainAuthorityHealth
    package let workspaces: [DomainWorkspaceSummary]
}

package struct DomainWorkspaceSummarySubscription {
    package let snapshot: DomainWorkspaceSummaryCatalogSnapshot
    package let events: AsyncStream<DomainWorkspaceEvent>
}

package enum DomainWorkspaceDocumentError: Error, Equatable {
    case invalidTopLevel
    case missingWorkspaceID
    case futureSchema(Int)
    case invalidContext(UUID?)
}

package enum DomainContentDigest {
    package static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum DomainWorkspaceDocumentDecoder {
    static let maximumSupportedSchemaVersion = 1
    /// `ComposeTabState` decodes a missing name as "T1", so summaries name such a tab the same way.
    private static let defaultTabName = "T1"

    static func decode(
        from data: Data
    ) throws -> (metadata: DomainWorkspaceMetadata, summaryFields: DomainWorkspaceSummaryFields) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DomainWorkspaceDocumentError.invalidTopLevel
        }
        guard let idString = object["id"] as? String, let workspaceID = UUID(uuidString: idString) else {
            throw DomainWorkspaceDocumentError.missingWorkspaceID
        }
        let schemaVersion = (object["schemaVersion"] as? NSNumber)?.intValue ?? 1
        guard schemaVersion <= maximumSupportedSchemaVersion else {
            throw DomainWorkspaceDocumentError.futureSchema(schemaVersion)
        }
        var contextIDs = Set<UUID>()
        var agentIdentityClaims: [DomainProtectedAgentIdentity] = []
        var composeTabSummaries: [DomainTabSummary] = []
        let contexts = try ((object["composeTabs"] as? [Any]) ?? []).map { raw -> DomainContextMetadata in
            guard let context = raw as? [String: Any],
                  let contextIDString = context["id"] as? String,
                  let contextID = UUID(uuidString: contextIDString)
            else {
                throw DomainWorkspaceDocumentError.invalidContext(nil)
            }
            guard contextIDs.insert(contextID).inserted else {
                throw DomainWorkspaceDocumentError.invalidContext(contextID)
            }
            agentIdentityClaims.append(DomainProtectedAgentIdentity(
                tabID: contextID,
                location: .composed,
                activeAgentSessionID: (context["activeAgentSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                isPinned: context["isPinned"] as? Bool ?? false
            ))
            let bytes = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
            let contentDigest = DomainContentDigest.sha256(bytes)
            try composeTabSummaries.append(tabSummary(
                tab: context,
                tabID: contextID,
                location: .composed,
                stashWrapper: nil,
                contentDigest: contentDigest
            ))
            return DomainContextMetadata(
                identity: DomainContextIdentity(workspaceID: workspaceID, contextID: contextID),
                name: context["name"] as? String ?? "Untitled",
                activeAgentSessionID: (context["activeAgentSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                activeChatSessionID: (context["activeChatSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                documentBytes: bytes,
                contentDigest: contentDigest
            )
        }
        // WorkspaceModel treats stashed tabs as recoverable compatibility data: malformed arrays
        // decode as empty and composed/stashed ID collisions are removed during normalization.
        // Mirror that behavior for identity claims instead of making the whole workspace unreadable.
        // A stashed tab gets a claim unless an earlier tab already claimed its ID. Summaries list
        // every stashed entry that has a tab ID, colliding ones included, so the gateway's tab-loss
        // check sees the entries an app decode would drop or reject.
        var stashedTabSummaries: [DomainTabSummary] = []
        for raw in (object["stashedTabs"] as? [Any]) ?? [] {
            guard let stashed = raw as? [String: Any],
                  let tab = stashed["tab"] as? [String: Any],
                  let tabIDString = tab["id"] as? String,
                  let tabID = UUID(uuidString: tabIDString)
            else { continue }
            if contextIDs.insert(tabID).inserted {
                agentIdentityClaims.append(DomainProtectedAgentIdentity(
                    tabID: tabID,
                    location: .stashed,
                    activeAgentSessionID: (tab["activeAgentSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                    isPinned: tab["isPinned"] as? Bool ?? false
                ))
            }
            try stashedTabSummaries.append(tabSummary(
                tab: tab,
                tabID: tabID,
                location: .stashed,
                stashWrapper: stashed,
                contentDigest: digest(of: tab)
            ))
        }
        let customStoragePath: URL? = if let raw = object["customStoragePath"] as? String {
            URL(string: raw) ?? URL(fileURLWithPath: raw)
        } else {
            nil
        }
        let metadata = DomainWorkspaceMetadata(
            workspaceID: workspaceID,
            schemaVersion: schemaVersion,
            name: object["name"] as? String ?? "Untitled Workspace",
            repoPaths: object["repoPaths"] as? [String] ?? [],
            customStoragePath: customStoragePath,
            isSystemWorkspace: object["isSystemWorkspace"] as? Bool ?? false,
            isHiddenInMenus: object["isHiddenInMenus"] as? Bool ?? false,
            consolidatedIntoWorkspaceID: (object["consolidatedIntoWorkspaceID"] as? String)
                .flatMap(UUID.init(uuidString:)),
            isEphemeral: object["ephemeralFlag"] as? Bool ?? false,
            activeContextID: (object["activeComposeTabID"] as? String).flatMap(UUID.init(uuidString:)),
            contexts: contexts,
            agentIdentityClaims: agentIdentityClaims
        )
        let summaryFields = DomainWorkspaceSummaryFields(
            dateModified: date(object["dateModified"]) ?? .distantPast,
            lastUsed: date(object["lastUsed"]) ?? .distantPast,
            composeTabs: composeTabSummaries,
            stashedTabs: stashedTabSummaries
        )
        return (metadata, summaryFields)
    }

    private static func tabSummary(
        tab: [String: Any],
        tabID: UUID,
        location: DomainWorkspaceTabLocation,
        stashWrapper: [String: Any]?,
        contentDigest: String
    ) throws -> DomainTabSummary {
        try DomainTabSummary(
            tabID: tabID,
            location: location,
            name: tab["name"] as? String ?? defaultTabName,
            activeAgentSessionID: (tab["activeAgentSessionID"] as? String).flatMap(UUID.init(uuidString:)),
            activeChatSessionID: (tab["activeChatSessionID"] as? String).flatMap(UUID.init(uuidString:)),
            isPinned: tab["isPinned"] as? Bool ?? false,
            stashID: (stashWrapper?["id"] as? String).flatMap(UUID.init(uuidString:)),
            stashedAt: date(stashWrapper?["stashedAt"]),
            contentDigest: contentDigest,
            selectionDigest: digest(of: tab["selection"] ?? NSNull())
        )
    }

    private static func digest(of value: Any) throws -> String {
        try DomainContentDigest.sha256(JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed]
        ))
    }

    /// `JSONEncoder`'s default date form: seconds since the reference date. A JSON boolean also
    /// arrives as an `NSNumber`, and `JSONDecoder` rejects it as a date, so this does too.
    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }
}
