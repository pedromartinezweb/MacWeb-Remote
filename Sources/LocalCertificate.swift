import Foundation
import CryptoKit

struct LocalCertificate {
    let directory: URL
    func prepare(host: String, address: String, password: String) throws -> String {
        let fm = FileManager.default
        let root = directory.appendingPathComponent("Certificates")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let caKey = root.appendingPathComponent("authority-v2.key")
        let caCert = root.appendingPathComponent("authority-v2.crt")
        if !fm.fileExists(atPath: caCert.path) {
            try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", caKey.path, "-out", caCert.path, "-days", "3650", "-subj", "/CN=MacWeb Remote Local Authority", "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0", "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-addext", "subjectKeyIdentifier=hash"])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
        }
        let generation = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: generation, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = generation.appendingPathComponent("server.key"), csr = generation.appendingPathComponent("server.csr"), cert = generation.appendingPathComponent("server.crt"), p12 = generation.appendingPathComponent("server.p12")
        try run(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", csr.path, "-subj", "/CN=MacWeb Remote"])
        let ext = generation.appendingPathComponent("extensions.conf")
        try "subjectAltName=DNS:\(host),IP:\(address),IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n".write(to: ext, atomically: true, encoding: .utf8)
        try run(["x509", "-req", "-in", csr.path, "-CA", caCert.path, "-CAkey", caKey.path, "-set_serial", "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(30).description, "-out", cert.path, "-days", "365", "-extfile", ext.path])
        let passFile = generation.appendingPathComponent("password.tmp")
        try Data(password.utf8).write(to: passFile)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passFile.path)
        defer { try? fm.removeItem(at: passFile) }
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-certfile", caCert.path, "-out", p12.path, "-passout", "file:" + passFile.path])
        for file in [key, p12] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try fm.copyItem(at: caCert, to: generation.appendingPathComponent("issuer.crt"))
        let der = root.appendingPathComponent("authority.cer")
        try run(["x509", "-in", caCert.path, "-outform", "DER", "-out", der.path])
        let identifier = "local.macwebremote.authority.\(SHA256.hash(data: try Data(contentsOf: der)).prefix(8).map { String(format: "%02x", $0) }.joined())"
        let payload: [String: Any] = ["PayloadType": "com.apple.security.root", "PayloadVersion": 1, "PayloadIdentifier": identifier + ".certificate", "PayloadUUID": UUID().uuidString, "PayloadDisplayName": "MacWeb Remote — certificado local", "PayloadContent": try Data(contentsOf: der)]
        let profile: [String: Any] = ["PayloadType": "Configuration", "PayloadVersion": 1, "PayloadIdentifier": identifier, "PayloadUUID": UUID().uuidString, "PayloadDisplayName": "MacWeb Remote — local HTTPS", "PayloadDescription": "Local certificate for HTTPS access to this Mac. Install only on trusted devices.", "PayloadContent": [payload]]
        try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0).write(to: root.appendingPathComponent("MacWeb-Remote.mobileconfig"), options: .atomic)
        return "Certificates/\(generation.lastPathComponent)/server.p12"
    }
    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Certificate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the local certificate."]) }
    }
}
