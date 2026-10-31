import Foundation
import CryptoKit
import Testing
@testable import RemoteAuth

private extension Data {
    var url64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
private struct TestAuthenticator {
    let key = P256.Signing.PrivateKey()
    let id = Data((0..<32).map(UInt8.init))
    let host = "desktop.example.net"
    var origin: String { "https://\(host):8787" }
    func client(_ challenge: String, type: String, origin: String? = nil, crossOrigin: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "challenge": challenge, "origin": origin ?? self.origin, "crossOrigin": crossOrigin])
    }
    func authenticationData(flags: UInt8 = 0x1d, host: String? = nil) -> Data {
        Data(SHA256.hash(data: Data((host ?? self.host).utf8))) + Data([flags,0,0,0,0])
    }
    func registration(challenge: String, origin: String? = nil, flags: UInt8 = 0x5d) throws -> Data {
        let publicKey = key.publicKey.x963Representation
        let cose = Data([0xa5,0x01,0x02,0x03,0x26,0x20,0x01,0x21,0x58,0x20]) + publicKey[1..<33] + Data([0x22,0x58,0x20]) + publicKey[33..<65]
        let auth = authenticationData(flags: flags) + Data(repeating:0,count:16) + Data([0,32]) + id + cose
        func text(_ value: String) -> Data { Data([0x60 + UInt8(value.utf8.count)]) + Data(value.utf8) }
        let attestation = Data([0xa3]) + text("fmt") + text("none") + text("authData") + Data([0x58,UInt8(auth.count)]) + auth + text("attStmt") + Data([0xa0])
        return try JSONSerialization.data(withJSONObject: ["id":id.url64,"rawId":id.url64,"type":"public-key","response":["clientDataJSON":try client(challenge,type:"webauthn.create",origin:origin).url64,"attestationObject":attestation.url64]])
    }
    func assertion(challenge: String, user: String, origin: String? = nil, flags: UInt8 = 0x1d, host: String? = nil, validSignature: Bool = true, crossOrigin: Bool = false) throws -> Data {
        let clientData = try client(challenge,type:"webauthn.get",origin:origin,crossOrigin:crossOrigin)
        let auth = authenticationData(flags:flags,host:host)
        let signature = try key.signature(for: auth + Data(SHA256.hash(data:clientData))).derRepresentation
        return try JSONSerialization.data(withJSONObject:["id":id.url64,"rawId":id.url64,"type":"public-key","response":["clientDataJSON":clientData.url64,"authenticatorData":auth.url64,"signature":validSignature ? signature.url64 : Data(repeating:0,count:signature.count).url64,"userHandle":user]])
    }
}

@Test @MainActor func signedCeremonyPersistsAndRevokes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let authenticator = TestAuthenticator()
    let identity = try AccessIdentity(host:authenticator.host,port:8787)
    let service = try PasskeyService(identity:identity,directory:directory)
    let options = try service.beginRegistration(sessionID:"owner",name:"Synchronized passkey")
    let publicKey = try #require(options["publicKey"] as? [String:Any])
    let challenge = try #require(publicKey["challenge"] as? String)
    let user = try #require((publicKey["user"] as? [String:Any])?["id"] as? String)
    let requestID = try #require(options["requestID"] as? String)
    let id = try await service.finishRegistration(requestID:requestID,sessionID:"owner",credentialJSON:authenticator.registration(challenge:challenge))
    #expect(service.count == 1)
    let reloaded = try PasskeyService(identity:identity,directory:directory)
    let login = try reloaded.beginAuthentication()
    let assertion = try authenticator.assertion(challenge:try #require((login["publicKey"] as? [String:Any])?["challenge"] as? String),user:user)
    let loginID = try #require(login["requestID"] as? String)
    #expect(try reloaded.finishAuthentication(requestID:loginID,credentialJSON:assertion) == id)
    #expect(throws: AccessError.expiredChallenge) { try reloaded.finishAuthentication(requestID:loginID,credentialJSON:assertion) }
    try reloaded.revoke(id:id)
    #expect(try PasskeyService(identity:identity,directory:directory).count == 0)
}

@Test @MainActor func signedAssertionsRejectInvalidSecurityProperties() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let authenticator = TestAuthenticator()
    let service = try PasskeyService(identity:AccessIdentity(host:authenticator.host,port:8787),directory:directory)
    let registration = try service.beginRegistration(sessionID:"owner",name:"Test")
    let options = try #require(registration["publicKey"] as? [String:Any])
    let user = try #require((options["user"] as? [String:Any])?["id"] as? String)
    _ = try await service.finishRegistration(requestID:try #require(registration["requestID"] as? String),sessionID:"owner",credentialJSON:authenticator.registration(challenge:try #require(options["challenge"] as? String)))
    for mutation in ["origin","rp","signature","uv","user","iframe","challenge"] {
        let login = try service.beginAuthentication()
        let challenge = try #require((login["publicKey"] as? [String:Any])?["challenge"] as? String)
        let assertion = try authenticator.assertion(challenge:mutation == "challenge" ? "wrong" : challenge,user:mutation == "user" ? Data(repeating:1,count:32).url64 : user,origin:mutation == "origin" ? "https://other.example.net" : nil,flags:mutation == "uv" ? 0x19 : 0x1d,host:mutation == "rp" ? "other.example.net" : nil,validSignature:mutation != "signature",crossOrigin:mutation == "iframe")
        #expect(throws: (any Error).self, "Must reject \(mutation)") { try service.finishAuthentication(requestID:try #require(login["requestID"] as? String),credentialJSON:assertion) }
    }
}
