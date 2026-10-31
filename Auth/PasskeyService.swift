import Foundation
import CryptoKit
import Security
import WebAuthn

public enum AccessError: LocalizedError {
    case invalidConfiguration, invalidCredential, expiredChallenge, capacity, storage, unknownCredential
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Configure a valid DNS name and HTTPS to use passkeys."
        case .invalidCredential: return "Could not verify the passkey."
        case .expiredChallenge: return "The request expired or was already used. Please try again."
        case .capacity: return "Too many pending requests. Please wait a few minutes."
        case .storage: return "Could not save the passkey."
        case .unknownCredential: return "This passkey is no longer authorized on this Mac."
        }
    }
}

public struct AccessIdentity: Equatable {
    public let host: String
    public let port: UInt16
    public var authority: String { port == 443 ? host : "\(host):\(port)" }
    public var origin: String { "https://\(authority)" }
    public init(host: String, port: UInt16) throws {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard port > 0, normalized.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), !normalized.allSatisfy({ $0.isNumber || $0 == "." }) else { throw AccessError.invalidConfiguration }
        self.host = normalized; self.port = port
    }
}

public struct StoredPasskey: Codable {
    public let id: String
    public let name: String
    public let publicKey: Data
    public var signCount: UInt32
    public let backupEligible: Bool
    public var backedUp: Bool
    public let createdAt: Date
    public var lastUsedAt: Date?
}

private struct CredentialDatabase: Codable {
    let schemaVersion: Int
    let relyingPartyID: String
    let userID: Data
    var credentials: [StoredPasskey]
}

private struct Challenge {
    enum Purpose { case registration(String), authentication }
    let bytes: [UInt8]
    let expiresAt: Date
    let purpose: Purpose
    let name: String
}

private struct CrossOriginContext: Decodable {
    let crossOrigin: Bool?
    let topOrigin: String?
}

@MainActor public final class PasskeyService {
    public let identity: AccessIdentity
    private let manager: WebAuthnManager
    private let file: URL
    private var database: CredentialDatabase
    private var pending: [String: Challenge] = [:]
    private let clock: () -> Date
    public var count: Int { database.credentials.count }
    private let algorithms = [PublicKeyCredentialParameters(alg: .algES256)]

    public init(identity: AccessIdentity, directory: URL, clock: @escaping () -> Date = Date.init) throws {
        self.identity = identity
        self.clock = clock
        manager = WebAuthnManager(configuration: .init(relyingPartyID: identity.host, relyingPartyName: "MacWeb Remote", relyingPartyOrigin: identity.origin))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suffix = SHA256.hash(data: Data(identity.host.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent("passkeys-\(suffix).json")
        if FileManager.default.fileExists(atPath: file.path) {
            let loaded = try JSONDecoder().decode(CredentialDatabase.self, from: Data(contentsOf: file))
            guard loaded.schemaVersion == 1, loaded.relyingPartyID == identity.host, loaded.userID.count == 32,
                  Set(loaded.credentials.map(\.id)).count == loaded.credentials.count else { throw AccessError.storage }
            database = loaded
        } else {
            database = CredentialDatabase(schemaVersion: 1, relyingPartyID: identity.host, userID: try Self.randomBytes(32), credentials: [])
            try persist(database)
        }
    }

    public func list() -> [[String: Any]] {
        database.credentials.map { credential in
            var result: [String: Any] = ["id": credential.id, "name": credential.name, "createdAt": ISO8601DateFormatter().string(from: credential.createdAt), "synced": credential.backupEligible]
            if let date = credential.lastUsedAt { result["lastUsedAt"] = ISO8601DateFormatter().string(from: date) }
            return result
        }
    }

    public func beginRegistration(sessionID: String, name: String) throws -> [String: Any] {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, !label.isEmpty, label.count <= 64 else { throw AccessError.invalidCredential }
        let options = manager.beginRegistration(user: .init(id: Array(database.userID), name: "Owner", displayName: "Owner of this Mac"), timeout: .seconds(120), publicKeyCredentialParameters: algorithms)
        var publicKey = try Self.object(options)
        publicKey["authenticatorSelection"] = ["residentKey": "required", "requireResidentKey": true, "userVerification": "required"]
        publicKey["excludeCredentials"] = database.credentials.map { ["type": "public-key", "id": $0.id] }
        let ticket = try reserve(bytes: options.challenge, purpose: .registration(sessionID), name: label)
        return ["requestID": ticket, "publicKey": publicKey]
    }

    public func finishRegistration(requestID: String, sessionID: String, credentialJSON: Data, authorizationIsCurrent: () -> Bool = { true }) async throws -> String {
        let challenge = try take(requestID)
        guard case .registration(let expectedSession) = challenge.purpose, expectedSession == sessionID else { throw AccessError.invalidCredential }
        let credential = try JSONDecoder().decode(RegistrationCredential.self, from: credentialJSON)
        try Self.checkClientContext(credential.attestationResponse.clientDataJSON)
        let canonicalID = Data(credential.rawID).base64URL
        guard credential.id.asString() == canonicalID, !database.credentials.contains(where: { $0.id == canonicalID }) else { throw AccessError.invalidCredential }
        let verified = try await manager.finishRegistration(challenge: challenge.bytes, credentialCreationData: credential, requireUserVerification: true, supportedPublicKeyAlgorithms: algorithms, confirmCredentialIDNotRegisteredYet: { _ in true })
        guard authorizationIsCurrent(), Data(base64Encoded: verified.id) == Data(credential.rawID), !database.credentials.contains(where: { $0.id == canonicalID }) else { throw AccessError.invalidCredential }
        var updated = database
        updated.credentials.append(StoredPasskey(id: canonicalID, name: challenge.name, publicKey: Data(verified.publicKey), signCount: verified.signCount, backupEligible: verified.backupEligible, backedUp: verified.isBackedUp, createdAt: clock(), lastUsedAt: nil))
        try commit(updated)
        return canonicalID
    }

    public func beginAuthentication() throws -> [String: Any] {
        let options = manager.beginAuthentication(timeout: .seconds(120), userVerification: .required)
        let ticket = try reserve(bytes: options.challenge, purpose: .authentication, name: "")
        return ["requestID": ticket, "publicKey": try Self.object(options)]
    }

    public func finishAuthentication(requestID: String, credentialJSON: Data) throws -> String {
        let challenge = try take(requestID)
        guard case .authentication = challenge.purpose else { throw AccessError.invalidCredential }
        let credential = try JSONDecoder().decode(AuthenticationCredential.self, from: credentialJSON)
        try Self.checkClientContext(credential.response.clientDataJSON)
        let id = Data(credential.rawID).base64URL
        guard credential.id.asString() == id, let index = database.credentials.firstIndex(where: { $0.id == id }),
              credential.response.userHandle.map({ Data($0) }) == database.userID else { throw AccessError.invalidCredential }
        let stored = database.credentials[index]
        let verified = try manager.finishAuthentication(credential: credential, expectedChallenge: challenge.bytes, credentialPublicKey: Array(stored.publicKey), credentialCurrentSignCount: stored.signCount, requireUserVerification: true)
        guard (verified.credentialDeviceType == .multiDevice) == stored.backupEligible else { throw AccessError.invalidCredential }
        var updated = database
        updated.credentials[index].signCount = verified.newSignCount
        updated.credentials[index].backedUp = verified.credentialBackedUp
        updated.credentials[index].lastUsedAt = clock()
        try commit(updated)
        return id
    }

    public func revoke(id: String) throws {
        guard database.credentials.contains(where: { $0.id == id }) else { throw AccessError.unknownCredential }
        var updated = database
        updated.credentials.removeAll { $0.id == id }
        try commit(updated)
        pending.removeAll()
    }

    private func reserve(bytes: [UInt8], purpose: Challenge.Purpose, name: String) throws -> String {
        pending = pending.filter { $0.value.expiresAt > clock() }
        guard pending.count < 64 else { throw AccessError.capacity }
        let id = try Self.randomBytes(32).base64URL
        pending[id] = Challenge(bytes: bytes, expiresAt: clock().addingTimeInterval(180), purpose: purpose, name: name)
        return id
    }
    private func take(_ id: String) throws -> Challenge {
        guard let challenge = pending.removeValue(forKey: id), challenge.expiresAt > clock() else { throw AccessError.expiredChallenge }
        return challenge
    }
    private func commit(_ updated: CredentialDatabase) throws {
        try persist(updated)
        database = updated
    }
    private func persist(_ value: CredentialDatabase) throws {
        let bytes = try JSONEncoder().encode(value)
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func checkClientContext(_ data: [UInt8]) throws {
        // The library owns origin/challenge/signature checks; reject unsupported iframe contexts here.
        let context = try JSONDecoder().decode(CrossOriginContext.self, from: Data(data))
        guard context.crossOrigin != true, context.topOrigin == nil else { throw AccessError.invalidCredential }
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw AccessError.invalidCredential }
        return result
    }
    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AccessError.storage }
        return data
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
