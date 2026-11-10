import Foundation
import Security

/// Where Home Assistant is and the key to it. Filled in once by pairing: the address (found on the network), the
/// name its certificate is issued for (so the connection is verified even though it goes to an address, with no
/// internet DNS needed) and the access token (in the Keychain - it survives app updates).
final class Settings: ObservableObject {
    @Published private(set) var host: String = UserDefaults.standard.string(forKey: "haHost") ?? ""
    @Published private(set) var port: Int = UserDefaults.standard.object(forKey: "haPort") as? Int ?? 8123
    @Published private(set) var tlsName: String = UserDefaults.standard.string(forKey: "haTLSName") ?? ""
    /// the Keychain first; its copy in the app's settings if the Keychain came back empty (a new signature from the
    /// signer on the PC can lose Keychain access - on 2026-11-03 that made Haven ask to pair again)
    @Published private(set) var token: String = Settings.restoreToken()

    private static func restoreToken() -> String {
        if let t = Keychain.get("haToken"), !t.isEmpty {
            if UserDefaults.standard.string(forKey: "haTokenCopy") != t { UserDefaults.standard.set(t, forKey: "haTokenCopy") }
            return t
        }
        guard let t = UserDefaults.standard.string(forKey: "haTokenCopy"), !t.isEmpty else { return "" }
        Keychain.set("haToken", t)
        Log.shared.add("the Keychain had lost the key (new signature) - restored from the app's settings, no pairing needed", level: .warning)
        return t
    }

    var paired: Bool { !host.isEmpty && !token.isEmpty }
    var baseURL: URL? { URL(string: "https://\(host):\(port)") }

    /// a stable id for this Apple TV (the app's own, not the hardware's)
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }

    func save(host: String, port: Int, tlsName: String, token: String) {
        self.host = host; self.port = port; self.tlsName = tlsName; self.token = token
        UserDefaults.standard.set(host, forKey: "haHost")
        UserDefaults.standard.set(port, forKey: "haPort")
        UserDefaults.standard.set(tlsName, forKey: "haTLSName")
        Keychain.set("haToken", token)
        UserDefaults.standard.set(token.isEmpty ? nil : token, forKey: "haTokenCopy")
    }

    /// Home Assistant moved to another address (found again on the network): same token, same certificate name
    func move(host: String, port: Int) {
        self.host = host; self.port = port
        UserDefaults.standard.set(host, forKey: "haHost")
        UserDefaults.standard.set(port, forKey: "haPort")
    }

    func forget() { save(host: "", port: 8123, tlsName: "", token: "") }
}

enum Keychain {
    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Certificate check for an address: the chain must be valid (system roots) for the name the certificate is issued
/// for (learned at pairing). Before pairing (name unknown) only the chain is checked.
final class TrustDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    var tlsName: () -> String
    init(tlsName: @escaping () -> String) { self.tlsName = tlsName }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if Self.check(trust, name: tlsName()) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { Log.shared.add("TLS: the certificate isn't valid for \(tlsName().isEmpty ? "(any name)" : tlsName()) - refused", level: .error)
               completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    /// a name like "ha.example.com": the certificate must cover it (a wildcard "*.example.com" does)
    static func check(_ trust: SecTrust, name: String) -> Bool {
        let policy = SecPolicyCreateSSL(true, name.isEmpty ? nil : name as CFString)
        SecTrustSetPolicies(trust, policy)
        var err: CFError?
        return SecTrustEvaluateWithError(trust, &err)
    }
}
