import Foundation
import SystemConfiguration
import Network
import Security
import RemoteAuth

struct ServerConfig: Codable {
    var token: String
    var tlsPassword: String
    var port: UInt16
    var accessHost: String?
    var bindAddress: String?
    var certificateFile: String?
    static func load(directory: URL) throws -> ServerConfig {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("config.json")
        if fm.fileExists(atPath: file.path) {
            let value = try JSONDecoder().decode(ServerConfig.self, from: Data(contentsOf: file))
            guard value.port > 0, IPv4Address(value.resolvedAddress) != nil else { throw AccessError.invalidConfiguration }
            _ = try value.identity
            return value
        }
        func secret() throws -> String {
            var data = Data(count: 32)
            let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            guard result == errSecSuccess else { throw AccessError.storage }
            return data.map { String(format: "%02x", $0) }.joined()
        }
        var config = ServerConfig(token: try secret(), tlsPassword: try secret(), port: 8787)
        config.certificateFile = try LocalCertificate(directory: directory).prepare(host: config.identity.host, address: config.resolvedAddress, password: config.tlsPassword)
        try NetworkConfiguration.save(config, directory: directory)
        return config
    }
    var resolvedAddress: String { bindAddress ?? NetworkConfiguration.primaryIPv4() ?? "127.0.0.1" }
    var identity: AccessIdentity { get throws { try AccessIdentity(host: accessHost ?? NetworkConfiguration.localName(), port: port) } }
    var addressOrigin: String { "https://\(resolvedAddress):\(port)" }
    var displayOrigin: String { certificateFile == nil ? addressOrigin : ((try? identity.origin) ?? addressOrigin) }
}

enum NetworkConfiguration {
    static func localName() -> String {
        (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "macweb-remote").lowercased() + ".local"
    }
    static func primaryIPv4() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MacWebRemote" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = global["PrimaryService"] as? String,
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
              let addresses = state["Addresses"] as? [String] else { return nil }
        return addresses.first(where: { IPv4Address($0) != nil })
    }
    static func save(_ config: ServerConfig, directory: URL) throws {
        let file = directory.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let backup = directory.appendingPathComponent("config-before-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try JSONEncoder().encode(config).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
