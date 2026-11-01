import Foundation

/// A unique, persistent identifier for the current *machine* (not per-user).
/// The ID is written once to:
///     ~/Library/Application Support/com.repoprompt/device-id
struct DeviceIdentity {
    static let shared = DeviceIdentity() // singleton

    /// 128-bit UUID rendered as a string (e.g. "7F2C…A1")
    let id: String

    private init() {
        let fm = FileManager.default
        let baseDir = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("com.repoprompt", isDirectory: true)
        let fileURL = baseDir.appendingPathComponent("device-id")

        #if DEBUG
            print("DeviceIdentity: Looking for device ID at: \(fileURL.path)")
        #endif

        // Create directory if missing
        try? fm.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true
        )

        // Load or create the identifier
        if let data = try? Data(contentsOf: fileURL),
           let str = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty
        {
            id = str
            #if DEBUG
                print("DeviceIdentity: Loaded existing device ID: \(str)")
            #endif
        } else {
            let newID = UUID().uuidString
            try? newID.data(using: .utf8)?
                .write(to: fileURL, options: [.atomic])
            id = newID
            #if DEBUG
                print("DeviceIdentity: Created new device ID: \(newID)")
            #endif
        }
    }
}
