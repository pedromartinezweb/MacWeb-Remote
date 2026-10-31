import AppKit
import Network
import RemoteAuth

@MainActor extension AppDelegate {
    func handlePasskeys(_ request: Request, path: String, reply: @escaping (Response) -> Void) {
        guard let service = passkeyService, request.headers["host"] == service.identity.authority else {
            reply(.json(["error": "Open the configured DNS link to use passkeys."], status: 409)); return
        }
        if request.method == "GET", path == "/api/passkeys/list" {
            guard authenticated(request) else { reply(.json(["error": "Sign in first."], status: 401)); return }
            reply(.json(["keys": service.list()])); return
        }
        guard request.method == "POST", request.headers["origin"] == service.identity.origin else {
            reply(.json(["error": "Origin not allowed."], status: 403)); return
        }
        authenticationAttempts = authenticationAttempts.filter { Date().timeIntervalSince($0) < 60 }
        guard authenticationAttempts.count < 30 else { reply(.json(["error": "Wait a minute before trying again."], status: 429)); return }
        authenticationAttempts.append(Date())
        do {
            switch path {
            case "/api/passkeys/login/options": reply(.json(try service.beginAuthentication()))
            case "/api/passkeys/login/finish":
                let (id, data) = try passkeyPayload(request)
                let credentialID = try service.finishAuthentication(requestID: id, credentialJSON: data)
                reply(loginResponse(request: request, credentialID: credentialID))
            case "/api/passkeys/register/options":
                guard freshAuthorization(request), let id = sessionID(request) else { reply(.json(["error": "Sign in again before creating a passkey."], status: 401)); return }
                reply(.json(try service.beginRegistration(sessionID: id, name: request.json["name"] as? String ?? "My passkey")))
            case "/api/passkeys/register/finish":
                guard freshAuthorization(request), let session = sessionID(request) else { reply(.json(["error": "Sign in again before creating a passkey."], status: 401)); return }
                let (id, data) = try passkeyPayload(request)
                Task {
                    do {
                        _ = try await service.finishRegistration(requestID: id, sessionID: session, credentialJSON: data, authorizationIsCurrent: { self.freshAuthorization(request) })
                        reply(.json(["ok": true, "keys": service.list()]))
                    } catch { reply(.json(["error": "Could not register the passkey. Please try again."], status: 400)) }
                }
            case "/api/passkeys/revoke":
                guard freshAuthorization(request), let id = request.json["id"] as? String else { reply(.json(["error": "Sign in again before revoking a passkey."], status: 401)); return }
                try service.revoke(id: id)
                invalidateSessions(credentialID: id)
                reply(.json(["ok": true, "keys": service.list()]))
            default: reply(.json(["error": "Not found."], status: 404))
            }
        } catch {
            reply(.json(["error": "Could not verify the passkey request. Please try again."], status: 400))
        }
    }

    private func passkeyPayload(_ request: Request) throws -> (String, Data) {
        let value = request.json
        guard let id = value["requestID"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let credential = value["credential"] as? [String: Any] else { throw AccessError.invalidCredential }
        return (id, try JSONSerialization.data(withJSONObject: credential))
    }
    func invalidateSessions(credentialID: String) {
        sessions = sessions.filter { $0.value.credentialID != credentialID }
        // Stop existing video connections too; a revoked key must not retain a live view.
        server.closeStreams()
        input.releaseAll()
        restoreMonitors()
    }
    func revokePasskey(_ id: String) {
        do { try passkeyService?.revoke(id: id); invalidateSessions(credentialID: id); tick() }
        catch { dashboard.settingsMessage = "Could not revoke the passkey." }
    }
    func configureAccess() {
        guard let port = UInt16(dashboard.port), port > 0, IPv4Address(dashboard.address) != nil,
              let identity = try? AccessIdentity(host: dashboard.host, port: port) else {
            dashboard.settingsMessage = "Enter a valid DNS name, IPv4 address and port."; return
        }
        var updated = config!
        updated.accessHost = identity.host
        updated.bindAddress = dashboard.address
        updated.port = port
        dashboard.busy = true
        dashboard.settingsMessage = "Preparing local certificate…"
        let directory = support!
        Task {
            do {
                let value = updated
                let file = try await Task.detached { try LocalCertificate(directory: directory).prepare(host: identity.host, address: value.resolvedAddress, password: value.tlsPassword) }.value
                updated.certificateFile = file
                try NetworkConfiguration.save(updated, directory: directory)
                dashboard.settingsMessage = "Saved. Reopen MacWeb Remote to apply the settings. Export and trust the certificate on devices that will use passkeys. Your network or VPN DNS must resolve \(identity.host) to \(updated.resolvedAddress)."
            } catch { dashboard.settingsMessage = "Could not save HTTPS settings. Previous settings were preserved." }
            dashboard.busy = false
        }
    }
    func exportCertificate() {
        let file = support.appendingPathComponent("Certificates/MacWeb-Remote.mobileconfig")
        guard FileManager.default.fileExists(atPath: file.path) else {
            dashboard.settingsMessage = "Prepare HTTPS before exporting the certificate."; return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacWeb-Remote.mobileconfig"
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                try Data(contentsOf: file).write(to: destination, options: .atomic)
                dashboard.settingsMessage = "Certificate exported. Confirm installation and trust on the destination device."
            } catch { dashboard.settingsMessage = "Could not export the certificate." }
        }
    }
}
