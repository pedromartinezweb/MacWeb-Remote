import Foundation
import Testing
@testable import RemoteAuth

@Test func validatesGenericNames() throws {
    let identity = try AccessIdentity(host: "desktop.example.net", port: 8787)
    #expect(identity.origin == "https://desktop.example.net:8787")
    for invalid in ["192.168.0.6", "https://example.net", "example.net/path", "a..local", "-bad.local", "localhost"] {
        #expect(throws: (any Error).self) { try AccessIdentity(host: invalid, port: 8787) }
    }
}

@Test @MainActor func registrationRequiresBoundSessionAndConsumesChallenge() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = try PasskeyService(identity: AccessIdentity(host: "desktop.example.net", port: 8787), directory: directory)
    let options = try service.beginRegistration(sessionID: "authorized-session", name: "Test")
    let key = try #require(options["publicKey"] as? [String: Any])
    let selection = try #require(key["authenticatorSelection"] as? [String: Any])
    #expect(selection["userVerification"] as? String == "required")
    #expect(selection["residentKey"] as? String == "required")
    let requestID = try #require(options["requestID"] as? String)
    do {
        _ = try await service.finishRegistration(requestID: requestID, sessionID: "different-session", credentialJSON: Data("{}".utf8))
        Issue.record("Another session must not register a passkey")
    } catch {}
    do {
        _ = try await service.finishRegistration(requestID: requestID, sessionID: "authorized-session", credentialJSON: Data("{}".utf8))
        Issue.record("Consumed challenge must not be reusable")
    } catch AccessError.expiredChallenge {} catch { Issue.record("Unexpected replay error: \(error)") }
    #expect(service.count == 0)
}

@Test @MainActor func authenticationChallengeExpires() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var now = Date()
    let service = try PasskeyService(identity: AccessIdentity(host: "desktop.example.net", port: 8787), directory: directory, clock: { now })
    let options = try service.beginAuthentication()
    let requestID = try #require(options["requestID"] as? String)
    now = now.addingTimeInterval(181)
    #expect(throws: AccessError.expiredChallenge) { try service.finishAuthentication(requestID: requestID, credentialJSON: Data("{}".utf8)) }
}
