import Foundation

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }
}

/// Stand-in for GetMoreRam's Keychain: only the anisette provisioning state (a random device
/// identifier and the ADI blob) is kept, in ~/.gmrcli/anisette.json. The Apple ID and password are
/// never stored.
public final class Keychain {
    public static let shared = Keychain()
    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gmrcli")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("anisette.json")
    }()
    private var store: [String: String]

    init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([String: String].self, from: d) {
            store = s
        } else {
            store = [:]
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(store) {
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public var identifier: String? {
        get { store["identifier"] }
        set { store["identifier"] = newValue; save() }
    }

    public var adiPb: String? {
        get { store["adiPb"] }
        set { store["adiPb"] = newValue; save() }
    }
}
