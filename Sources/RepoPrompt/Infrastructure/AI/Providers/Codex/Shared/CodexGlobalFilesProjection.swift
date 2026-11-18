import CryptoKit
import Darwin
import Foundation

enum CodexGlobalFilesProjection {
    enum Failure: Error, LocalizedError {
        case sourceUnreadable(URL, String)
        case manifestInvalid(URL, String)
        case unownedDestination(URL)
        case modifiedDestination(URL)
        case unsupportedDestination(URL, String)
        case inspectionFailed(URL, String)
        case destinationMutationFailed(URL, String)
        case manifestMutationFailed(URL, String)

        var errorDescription: String? {
            switch self {
            case let .sourceUnreadable(url, detail):
                "RepoPrompt could not read the global Codex file at `\(url.path)` (\(detail)). Its managed copy was not changed."
            case let .manifestInvalid(url, detail):
                "RepoPrompt could not use its Codex global file projection manifest at `\(url.path)` (\(detail)). No managed global Codex file that this manifest covers was changed. Preserve anything needed, move or remove the manifest, and try again."
            case let .unownedDestination(url):
                "RepoPrompt found an unowned global Codex file at `\(url.path)`. It was preserved. Preserve anything needed, move or remove the file, and try again."
            case let .modifiedDestination(url):
                "RepoPrompt found a modified managed global Codex file at `\(url.path)`. It was preserved. Preserve anything needed, move or remove the file, and try again."
            case let .unsupportedDestination(url, kind):
                "RepoPrompt found a \(kind) at managed global Codex file path `\(url.path)`. It was preserved. Preserve anything needed, move or remove the entry, and try again."
            case let .inspectionFailed(url, detail):
                "RepoPrompt could not inspect Codex global file state at `\(url.path)` (\(detail))."
            case let .destinationMutationFailed(url, detail):
                "RepoPrompt could not update the managed global Codex file at `\(url.path)` (\(detail)). Other managed global Codex files may already have been updated. Try again. If RepoPrompt then reports an unowned file, move or remove it and try again."
            case let .manifestMutationFailed(url, detail):
                "RepoPrompt could not update its Codex global file projection manifest at `\(url.path)` (\(detail)). Managed global Codex files may already have been updated. Try again. If RepoPrompt then reports an unowned file, move or remove it and try again."
            }
        }
    }

    private struct ProjectedFile {
        let name: String
    }

    /// Files that share one ownership manifest. Every action in a set is planned before any is
    /// applied, so a conflict on one file blocks every change in its set.
    private struct FileSet {
        let files: [ProjectedFile]
        let manifestName: String
    }

    private struct SourceSnapshot {
        let data: Data
        let hash: String
    }

    private enum DestinationSnapshot {
        case missing
        case regular(hash: String)
        case symbolicLink
        case unsupported(String)
    }

    private enum DestinationAction {
        case none
        case write(Data)
        case remove
    }

    private struct ProjectionAction {
        let file: ProjectedFile
        let destination: URL
        let action: DestinationAction
        let desiredHash: String?
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let projectedFileHashes: [String: String]
    }

    /// A build rejects a manifest that names a file outside its own set, and then every Codex launch
    /// it makes fails. Builds of different versions share one profile, so a set's names never grow:
    /// a newly projected file gets a new set and a new manifest, which older builds never read.
    private static let instructionFiles = FileSet(
        files: [ProjectedFile(name: "AGENTS.override.md"), ProjectedFile(name: "AGENTS.md")],
        manifestName: ".repoprompt-agents-projection.json"
    )
    private static let hookFiles = FileSet(
        files: [ProjectedFile(name: "hooks.json")],
        manifestName: ".repoprompt-hooks-projection.json"
    )
    // Instructions reconcile and commit before hooks are read, so a hooks failure leaves the
    // instruction copies as they would be without hooks. A failing set stops every set after it.
    private static let fileSets = [instructionFiles, hookFiles]
    private static let lock = NSLock()

    static func prepare(
        ordinaryCodexHome: URL,
        managedCodexHome: URL,
        fileManager: FileManager = .default
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        for fileSet in fileSets {
            try reconcile(
                fileSet,
                ordinaryCodexHome: ordinaryCodexHome,
                managedCodexHome: managedCodexHome,
                fileManager: fileManager
            )
        }
    }

    private static func reconcile(
        _ fileSet: FileSet,
        ordinaryCodexHome: URL,
        managedCodexHome: URL,
        fileManager: FileManager
    ) throws {
        let files = fileSet.files
        let sourceSnapshots = try Dictionary(uniqueKeysWithValues: files.map { file in
            let source = ordinaryCodexHome.appendingPathComponent(file.name)
            return try (file.name, sourceSnapshot(at: source))
        })
        let manifestURL = managedCodexHome.appendingPathComponent(fileSet.manifestName)
        let previousManifest = try loadManifest(at: manifestURL, allowedNames: Set(files.map(\.name)))

        let actions = try files.map { file in
            let destination = managedCodexHome.appendingPathComponent(file.name)
            let destinationSnapshot = try destinationSnapshot(at: destination)
            return try projectionAction(
                file: file,
                destination: destination,
                source: sourceSnapshots[file.name] ?? nil,
                destinationSnapshot: destinationSnapshot,
                manifestHash: previousManifest?.projectedFileHashes[file.name]
            )
        }

        for action in actions {
            try apply(action, fileManager: fileManager)
        }

        let projectedFileHashes = Dictionary(uniqueKeysWithValues: actions.compactMap { action in
            action.desiredHash.map { (action.file.name, $0) }
        })
        try commitManifest(projectedFileHashes, at: manifestURL, fileManager: fileManager)
    }

    private static func sourceSnapshot(at url: URL) throws -> SourceSnapshot? {
        var metadata = Darwin.stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &metadata)
        }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return nil
            }
            throw Failure.inspectionFailed(url, posixErrorDescription())
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return SourceSnapshot(data: data, hash: hash(data))
        } catch {
            throw Failure.sourceUnreadable(url, error.localizedDescription)
        }
    }

    private static func destinationSnapshot(at url: URL) throws -> DestinationSnapshot {
        var metadata = Darwin.stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return .missing
            }
            throw Failure.inspectionFailed(url, posixErrorDescription())
        }

        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            do {
                return try .regular(hash: hash(Data(contentsOf: url)))
            } catch {
                throw Failure.inspectionFailed(url, error.localizedDescription)
            }
        case S_IFLNK:
            return .symbolicLink
        case S_IFDIR:
            return .unsupported("directory")
        default:
            return .unsupported("non-regular filesystem entry")
        }
    }

    private static func loadManifest(at url: URL, allowedNames: Set<String>) throws -> Manifest? {
        switch try destinationSnapshot(at: url) {
        case .missing:
            return nil
        case .symbolicLink:
            throw Failure.manifestInvalid(url, "the manifest is a symbolic link")
        case let .unsupported(kind):
            throw Failure.manifestInvalid(url, "the manifest is a \(kind)")
        case .regular:
            break
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        } catch {
            throw Failure.manifestInvalid(url, error.localizedDescription)
        }
        guard manifest.schemaVersion == 1 else {
            throw Failure.manifestInvalid(url, "unsupported schema version \(manifest.schemaVersion)")
        }

        guard Set(manifest.projectedFileHashes.keys).isSubset(of: allowedNames) else {
            throw Failure.manifestInvalid(url, "the manifest contains an unknown filename")
        }
        guard manifest.projectedFileHashes.values.allSatisfy(isValidHash) else {
            throw Failure.manifestInvalid(url, "the manifest contains an invalid SHA-256 hash")
        }
        return manifest
    }

    private static func projectionAction(
        file: ProjectedFile,
        destination: URL,
        source: SourceSnapshot?,
        destinationSnapshot: DestinationSnapshot,
        manifestHash: String?
    ) throws -> ProjectionAction {
        switch destinationSnapshot {
        case .missing:
            if let source {
                return ProjectionAction(file: file, destination: destination, action: .write(source.data), desiredHash: source.hash)
            }
            return ProjectionAction(file: file, destination: destination, action: .none, desiredHash: nil)
        case .symbolicLink:
            throw Failure.unsupportedDestination(destination, "symbolic link")
        case let .unsupported(kind):
            throw Failure.unsupportedDestination(destination, kind)
        case let .regular(destinationHash):
            guard let manifestHash else {
                throw Failure.unownedDestination(destination)
            }
            guard destinationHash == manifestHash else {
                if let source, destinationHash == source.hash {
                    return ProjectionAction(file: file, destination: destination, action: .none, desiredHash: source.hash)
                }
                throw Failure.modifiedDestination(destination)
            }
            guard let source else {
                return ProjectionAction(file: file, destination: destination, action: .remove, desiredHash: nil)
            }
            let action: DestinationAction = destinationHash == source.hash ? .none : .write(source.data)
            return ProjectionAction(file: file, destination: destination, action: action, desiredHash: source.hash)
        }
    }

    private static func apply(_ projection: ProjectionAction, fileManager: FileManager) throws {
        do {
            switch projection.action {
            case .none:
                return
            case let .write(data):
                try data.write(to: projection.destination, options: .atomic)
            case .remove:
                try fileManager.removeItem(at: projection.destination)
            }
        } catch {
            throw Failure.destinationMutationFailed(projection.destination, error.localizedDescription)
        }
    }

    private static func commitManifest(
        _ projectedFileHashes: [String: String],
        at url: URL,
        fileManager: FileManager
    ) throws {
        do {
            if projectedFileHashes.isEmpty {
                if case .missing = try destinationSnapshot(at: url) {
                    return
                }
                try fileManager.removeItem(at: url)
                return
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Manifest(schemaVersion: 1, projectedFileHashes: projectedFileHashes))
            try data.write(to: url, options: .atomic)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.manifestMutationFailed(url, error.localizedDescription)
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidHash(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}
