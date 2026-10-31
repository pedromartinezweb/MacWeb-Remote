import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor final class DashboardModel: ObservableObject {
    @Published var origin = ""
    @Published var localOrigin = ""
    @Published var qrLink = ""
    @Published var recoveryCode = ""
    @Published var running = false
    @Published var hasFrames = false
    @Published var capturing = false
    @Published var control = false
    @Published var monitorsOff = false
    @Published var message = "Starting server…"
    @Published var passkeys: [[String: Any]] = []
    @Published var host = ""
    @Published var address = ""
    @Published var port = "8787"
    @Published var settingsMessage = ""
    @Published var busy = false
    var copyLink: () -> Void = {}
    var requestCapture: () -> Void = {}
    var openScreenSettings: () -> Void = {}
    var requestControl: () -> Void = {}
    var createVirtual: () -> Void = {}
    var restoreDisplays: () -> Void = {}
    var configure: () -> Void = {}
    var exportCertificate: () -> Void = {}
    var revoke: (String) -> Void = { _ in }

    var qrImage: NSImage? {
        guard !qrLink.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(qrLink.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 220, height: 220))
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var settingsOpen = false
    @State private var showRecovery = false
    private let accent = Color(red: 0.34, green: 0.64, blue: 0.49)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text("MacWeb Remote").font(.system(size: 23, weight: .semibold))
                    Text("Your desktop, from any browser.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { settingsOpen = true } label: { Image(systemName: "gearshape").font(.system(size: 17)) }
                    .buttonStyle(.plain).help("Settings")
            }
            Divider()
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 17) {
                    Label(model.running ? "Server running" : "Server unavailable", systemImage: model.running ? "circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(model.running ? accent : .orange)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Access link").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(model.origin.isEmpty ? "Preparing address…" : model.origin)
                            .font(.system(size: 16, weight: .medium, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    }
                    Button(action: model.copyLink) { Label("Copy link", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.large).disabled(!model.running)
                    Text("Scan the QR code or open the link on another device.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Recovery code", isExpanded: $showRecovery) {
                        Text(model.recoveryCode).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(.top, 5)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 9) {
                    if let image = model.qrImage {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 184, height: 184).padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else { ProgressView().frame(width: 208, height: 208) }
                    Text(model.passkeys.isEmpty ? "First-time access" : "Passkey access").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    permission("Screen recording", enabled: model.capturing, action: model.requestCapture)
                    if !model.capturing {
                        Button("Open Screen Recording settings", action: model.openScreenSettings).controlSize(.small)
                    }
                }
                permission("Mouse and keyboard", enabled: model.control, action: model.requestControl)
                Spacer()
            }
            HStack {
                Label(model.monitorsOff ? "Physical displays disabled" : model.hasFrames ? "Desktop available" : "Waiting for screen recording", systemImage: model.monitorsOff ? "display.trianglebadge.exclamationmark" : "display")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if model.monitorsOff { Button("Restore displays", action: model.restoreDisplays) }
                else { Button("Virtual display", action: model.createVirtual) }
            }
            if !model.message.isEmpty { Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(30).frame(width: 680).background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $settingsOpen) { settings }
    }

    private func permission(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(name, systemImage: enabled ? "checkmark.circle.fill" : "circle").font(.system(size: 12)).foregroundStyle(enabled ? accent : .secondary)
            if !enabled { Button("Grant access", action: action).controlSize(.small) }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Settings").font(.title2.weight(.semibold)); Spacer(); Button("Close") { settingsOpen = false } }
            Form {
                TextField("DNS name", text: $model.host)
                TextField("Listen address", text: $model.address)
                TextField("HTTPS port", text: $model.port)
            }
            Text("Passkeys require this name and a trusted certificate. Your VPN DNS must also resolve the name to this Mac.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Prepare HTTPS and save", action: model.configure).disabled(model.busy)
                Button("Export certificate…", action: model.exportCertificate)
                if model.busy { ProgressView().controlSize(.small) }
            }
            if !model.settingsMessage.isEmpty { Text(model.settingsMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            Text("Passkeys").font(.headline)
            if model.passkeys.isEmpty { Text("No passkeys registered yet. Sign in through the browser and choose Create passkey.").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.passkeys.compactMap { item -> KeyRow? in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                return KeyRow(id: id, name: name)
            }) { item in
                HStack { Label(item.name, systemImage: "key"); Spacer(); Button("Revoke") { model.revoke(item.id) } }
            }
            if !model.localOrigin.isEmpty { Text("Recovery access by IP: \(model.localOrigin)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(26).frame(width: 570)
    }
    private struct KeyRow: Identifiable { let id: String; let name: String }
}
