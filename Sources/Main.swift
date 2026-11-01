import AppKit
import NativeBridge
import RemoteAuth
import CryptoKit
import Security
import SwiftUI
import Network

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let capture = ScreenCapture()
    let input = RemoteInput()
    let remoteDisplay = RemoteDisplay()
    lazy var server = HTTPServer(frames: capture.frames)
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let dashboard = DashboardModel()
    var config: ServerConfig!
    var support: URL!
    struct Session { let expires: Date; let created: Date; let credentialID: String?; let origin: String }
    var sessions: [String: Session] = [:]
    var passkeyService: PasskeyService?
    var authenticationAttempts: [Date] = []
    var operationPending = false
    var latestError: String?
    var timer: Timer?
    var monitorsOffSince: Date?
    var lastHeartbeat = Date()
    var currentQuality: Float = 0.65
    let encoder = JSONEncoder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        setupWindow()
        do {
            support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacWebRemote")
            config = try ServerConfig.load(directory: support)
            passkeyService = try PasskeyService(identity: config.identity, directory: support)
            dashboard.host = try config.identity.host
            dashboard.address = config.resolvedAddress
            dashboard.port = String(config.port)
            server.stateChanged = { [weak self] error in self?.latestError = "Could not start the server: \(error)"; self?.dashboard.running = false }
            server.handler = { [weak self] request, reply in self?.handle(request, reply:reply) }
            try server.start(address:config.resolvedAddress, port:config.port, p12:Data(contentsOf:support.appendingPathComponent(config.certificateFile ?? "server.p12")), password:config.tlsPassword)
            dashboard.running = true
            dashboard.message = "Encrypted HTTPS connection. Keep this Mac awake."
            if CGPreflightScreenCaptureAccess() { Task { await self.startCapture(id:CGMainDisplayID()) } }
        } catch { latestError = error.localizedDescription; dashboard.message = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats:true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick()
        NSApplication.shared.activate(ignoringOtherApps:true)
    }
    func setupWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 630), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MacWeb Remote"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        dashboard.copyLink = { [weak self] in self?.copyLink() }
        dashboard.requestCapture = { [weak self] in self?.requestScreen() }
        dashboard.openScreenSettings = { [weak self] in self?.openScreenSettings() }
        dashboard.requestControl = { [weak self] in self?.requestInput() }
        dashboard.createVirtual = { [weak self] in self?.createVirtual() }
        dashboard.restoreDisplays = { [weak self] in self?.restoreMonitors() }
        dashboard.configure = { [weak self] in self?.configureAccess() }
        dashboard.exportCertificate = { [weak self] in self?.exportCertificate() }
        dashboard.revoke = { [weak self] id in self?.revokePasskey(id) }
        window.contentView = NSHostingView(rootView: DashboardView(model: dashboard))
        window.makeKeyAndOrderFront(nil)
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"desktopcomputer",accessibilityDescription:"MacWeb Remote")
        let menu = NSMenu()
        for (name, action) in [("Open MacWeb Remote",#selector(showWindow)),("Copy link",#selector(copyLink)),("Restore displays",#selector(restoreMonitors)),("Quit",#selector(quit))] {
            let item = NSMenuItem(title:name,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
    }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title:title,target:self,action:action) }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true) }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    @objc func copyLink() {
        guard config != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dashboard.qrLink,forType:.string)
    }
    @objc func requestScreen() {
        Task {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            // ScreenCaptureKit is authoritative; the preflight result may be stale after a grant.
            await startCapture(id: CGMainDisplayID())
            if !capture.isRunning { openScreenSettings() }
        }
    }
    func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard config != nil, !capture.isRunning, CGPreflightScreenCaptureAccess() else { return }
        Task { await startCapture(id: CGMainDisplayID()) }
    }
    @objc func requestInput() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func createVirtual() { Task { do { try await self.ensureVirtual() } catch { self.latestError = error.localizedDescription } } }
    @objc func restoreMonitors() {
        do { try remoteDisplay.restorePhysicalDisplays(); monitorsOffSince = nil; latestError = nil }
        catch { latestError = error.localizedDescription }
    }
    func ensureVirtual() async throws {
        guard !operationPending else { throw NSError(domain:"Display",code:1,userInfo:[NSLocalizedDescriptionKey:"A display change is already in progress."]) }
        operationPending = true; defer { operationPending = false }
        try remoteDisplay.create(withWidth:1440,height:900)
        try await Task.sleep(nanoseconds:600_000_000)
        try await capture.start(displayID:remoteDisplay.displayID,quality:currentQuality)
    }
    func startCapture(id: CGDirectDisplayID) async {
        guard !operationPending else { return }
        operationPending = true; defer { operationPending = false }
        do { try await capture.start(displayID:id,quality:currentQuality); latestError = nil }
        catch {
            latestError = "Screen recording could not start: \(error.localizedDescription). Enable MacWeb Remote in System Settings → Privacy & Security → Screen Recording, then quit and reopen the app. If it is already enabled after an update, remove the old entry and add this app again."
        }
    }
    func tick() {
        let screen = CGPreflightScreenCaptureAccess(), control = AXIsProcessTrusted()
        if screen, !capture.isRunning, !operationPending, latestError == nil { Task { await self.startCapture(id:CGMainDisplayID()) } }
        if Date().timeIntervalSince(lastHeartbeat) > 15 { input.releaseAll() }
        if monitorsOffSince != nil, Date().timeIntervalSince(lastHeartbeat) > 30 { restoreMonitors() }
        let state = status()
        if let data = try? JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:support.appendingPathComponent("state.json"),options:.atomic)
        }
        sessions = sessions.filter { $0.value.expires > Date() }
        dashboard.origin = config?.displayOrigin ?? ""
        dashboard.localOrigin = config?.addressOrigin ?? ""
        dashboard.recoveryCode = config?.token ?? ""
        dashboard.qrLink = dashboard.origin + "/" + ((passkeyService?.count ?? 0) == 0 ? "#" + (config?.token ?? "") : "")
        dashboard.hasFrames = !capture.frames.read().0.isEmpty
        dashboard.capturing = capture.isRunning
        dashboard.control = control
        dashboard.monitorsOff = !remoteDisplay.disabledDisplays.isEmpty
        dashboard.message = latestError ?? capture.error ?? "Encrypted HTTPS connection · private access"
        dashboard.passkeys = passkeyService?.list() ?? []
    }
    func status() -> [String: Any] {
        let (frame, serial, time) = capture.frames.read()
        return ["screenPermission":(capture.isRunning || CGPreflightScreenCaptureAccess()),"inputPermission":AXIsProcessTrusted(),"selectedDisplay":capture.selectedID,"virtualDisplay":remoteDisplay.displayID,"monitorsOff":!remoteDisplay.disabledDisplays.isEmpty,"frames":frame.isEmpty ? 0 : serial,"frameBytes":frame.count,"frameAge":frame.isEmpty ? -1 : Date().timeIntervalSince(time),"error":latestError ?? capture.error ?? "","busy":operationPending,"displays":capture.displays.map { ["id":$0.displayID,"width":$0.width,"height":$0.height,"virtual":$0.displayID == remoteDisplay.displayID] as [String:Any] }]
    }
    func sessionID(_ request: Request) -> String? {
        let matches = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("macweb_session=") }
        guard matches.count == 1 else { return nil }
        return String(matches[0].dropFirst("macweb_session=".count))
    }
    func authenticated(_ request: Request) -> Bool {
        guard let id = sessionID(request), let session = sessions[id] else { return false }
        return session.expires > Date() && session.origin == "https://" + (request.headers["host"] ?? "")
    }
    func freshAuthorization(_ request: Request) -> Bool {
        guard authenticated(request), let id = sessionID(request), let session = sessions[id] else { return false }
        return Date().timeIntervalSince(session.created) < 300
    }
    func loginResponse(request: Request, credentialID: String?) -> Response {
        let id = UUID().uuidString + UUID().uuidString
        sessions[id] = Session(expires: Date().addingTimeInterval(43200), created: Date(), credentialID: credentialID, origin: "https://" + (request.headers["host"] ?? ""))
        var response = Response.json(["ok": true])
        response.headers["Set-Cookie"] = "macweb_session=\(id); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=43200"
        return response
    }
    func handle(_ request: Request, reply: @escaping (Response)->Void) {
        let path = request.path.components(separatedBy:"?")[0]
        let host = request.headers["host"] ?? ""
        let allowedHosts = ["\(config.resolvedAddress):\(config.port)", "127.0.0.1:\(config.port)", "localhost:\(config.port)", (try? config.identity.authority) ?? ""]
        guard allowedHosts.contains(host) else { reply(.json(["error":"Host not allowed"],status:403)); return }
        if let origin = request.headers["origin"], origin != "https://\(host)" { reply(.json(["error":"Origin not allowed"],status:403)); return }
        if request.method == "GET", ["/","/app.js","/transport.js","/passkeys.js","/style.css","/manifest.webmanifest","/icon.png"].contains(path) {
            let name = path == "/" ? "index.html" : String(path.dropFirst())
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("Web"), let data = try? Data(contentsOf:root.appendingPathComponent(name)) else { reply(.json(["error":"Recurso ausente"],status:404)); return }
            let type = name.hasSuffix("png") ? "image/png" : name.hasSuffix("html") ? "text/html; charset=utf-8" : name.hasSuffix("js") ? "text/javascript; charset=utf-8" : name.hasSuffix("css") ? "text/css; charset=utf-8" : "application/manifest+json"
            reply(Response(type:type,body:data,headers:["Content-Security-Policy":"default-src 'self'; img-src 'self' blob: data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"]))
            return
        }
        if path == "/api/auth/config", request.method == "GET" {
            reply(.json(["origin": (try? config.identity.origin) ?? "", "availableHere": host == (try? config.identity.authority), "hasPasskeys": (passkeyService?.count ?? 0) > 0])); return
        }
        if request.method == "POST", request.headers["content-type"]?.hasPrefix("application/json") != true { reply(.json(["error": "JSON is required"], status: 400)); return }
        if path.hasPrefix("/api/passkeys/") { handlePasskeys(request, path: path, reply: reply); return }
        if path == "/api/login", request.method == "POST" {
            authenticationAttempts = authenticationAttempts.filter { Date().timeIntervalSince($0) < 60 }
            guard authenticationAttempts.count < 12 else { reply(.json(["error":"Wait a minute before trying again."],status:429)); return }
            authenticationAttempts.append(Date())
            let given = request.json["token"] as? String ?? ""
            let lhs = Array(SHA256.hash(data:Data(given.utf8))), rhs = Array(SHA256.hash(data:Data(config.token.utf8)))
            let difference = zip(lhs,rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
            guard difference == 0 else { reply(.json(["error":"Incorrect code"],status:401)); return }
            reply(loginResponse(request: request, credentialID: nil)); return
        }
        guard authenticated(request) else { reply(.json(["error":"Sign in to access this Mac."],status:401)); return }
        if request.method == "GET" {
            switch path {
            case "/api/status": var value = status(); value["canRegisterPasskey"] = freshAuthorization(request); reply(.json(value))
            case "/api/frame":
                let (data,serial,_) = capture.frames.read()
                if data.isEmpty { reply(.json(["error":"Waiting for screen recording"],status:503)) }
                else {
                    let after = URLComponents(string: request.path)?.queryItems?.first { $0.name == "after" }?.value
                    let headers = ["X-Frame-Serial": String(serial)]
                    if after == String(serial) { reply(Response(status:204, headers:headers)) }
                    else { reply(Response(type:"image/jpeg",body:data,headers:headers)) }
                }
            case "/api/stream": reply(Response(type:"multipart/x-mixed-replace; boundary=frame",stream:true,expiresAt:Date().addingTimeInterval(3600)))
            default: reply(.json(["error":"Not found"],status:404))
            }
            return
        }
        guard request.method == "POST", request.headers["content-type"]?.hasPrefix("application/json") == true else { reply(.json(["error":"JSON is required"],status:400)); return }
        switch path {
        case "/api/heartbeat": lastHeartbeat = Date(); reply(.json(["ok":true]))
        case "/api/input":
            do {
                let applied = try input.applyRequest(request.json, displayID: capture.selectedID)
                reply(.json(["ok":true, "applied":applied]))
            }
            catch InputError.permission { reply(.json(["error":"Enable Accessibility access on this Mac."],status:403)) }
            catch { reply(.json(["error":"Invalid input"],status:400)) }
        case "/api/display":
            guard remoteDisplay.disabledDisplays.isEmpty else { reply(.json(["error":"Restore physical displays before switching displays."],status:409)); return }
            guard let id = request.json["id"] as? UInt32 else { reply(.json(["error":"Invalid display"],status:400)); return }
            Task { await self.startCapture(id:id); reply(.json(self.status())) }
        case "/api/virtual":
            Task {
                do { try await self.ensureVirtual(); self.latestError = nil; reply(.json(self.status())) }
                catch { reply(.json(["error":error.localizedDescription],status:409)) }
            }
        case "/api/monitors":
            if request.json["off"] as? Bool == true {
                guard capture.selectedID == remoteDisplay.displayID, remoteDisplay.displayID != 0, !capture.frames.read().0.isEmpty else { reply(.json(["error":"Activate the virtual display and check its video first."],status:409)); return }
                do { try remoteDisplay.disablePhysicalDisplays(); monitorsOffSince = Date(); lastHeartbeat = Date(); reply(.json(status())) }
                catch { reply(.json(["error":error.localizedDescription],status:409)) }
            } else { restoreMonitors(); reply(.json(status())) }
        case "/api/quality":
            let name = request.json["quality"] as? String ?? "balanced"
            currentQuality = ["low":Float(0.4),"balanced":0.65,"high":0.85][name] ?? 0.65
            Task { await self.startCapture(id:self.capture.selectedID); reply(.json(self.status())) }
        case "/api/logout":
            sessions.removeAll(); server.closeStreams(); input.releaseAll(); restoreMonitors()
            var response = Response.json(["ok":true]); response.headers["Set-Cookie"] = "macweb_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"; reply(response)
        default: reply(.json(["error":"Not found"],status:404))
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        input.releaseAll(); restoreMonitors(); server.stop()
        Task { await self.capture.stop(); NSApplication.shared.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

@main struct MacWebRemote {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
