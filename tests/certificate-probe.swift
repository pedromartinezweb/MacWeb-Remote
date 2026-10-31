import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try LocalCertificate(directory: root).prepare(host: "desktop.example.net", address: "127.0.0.1", password: "test-only-password")
print(file)
