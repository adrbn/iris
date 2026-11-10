import ActivityKit
import Foundation
import Security

/// Compiled into the app AND the widget extension (scripts/install.sh): the Live Activity type and
/// the last known glasses state the widgets read.
struct GlassesActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var battery: Int
        var charging: Bool
        var connected: Bool
    }
    var name: String
}

/// Shared through a keychain access group: the wildcard dev profile allows TEAM.*, while an App
/// Group would need the developer portal.
struct GlassesSnapshot: Codable, Equatable {
    var name: String
    var battery: Int?
    var charging: Bool
    var connected: Bool
    var date = Date()

    static let accessGroup = teamPrefix + "com.adrbn.iris.shared"

    /// "TEAMID." of whoever signed this build, read back from the default keychain access group
    /// (the first one in the entitlements), so a re-signed IPA shares under its own team.
    private static let teamPrefix: String = {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "iris.team-probe",
                                    kSecReturnAttributes as String: true]
        var out: AnyObject?
        if SecItemCopyMatching(probe as CFDictionary, &out) == errSecItemNotFound {
            SecItemAdd(probe as CFDictionary, &out)
        }
        let group = (out as? [String: Any])?[kSecAttrAccessGroup as String] as? String ?? ""
        return group.split(separator: ".").first.map { $0 + "." } ?? ""
    }()
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "iris.snapshot",
                                               kSecAttrAccessGroup as String: accessGroup]

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        SecItemDelete(Self.query as CFDictionary)
        var add = Self.query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> GlassesSnapshot? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(GlassesSnapshot.self, from: data)
    }
}
