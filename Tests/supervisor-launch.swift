import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("expected supervisor path") }
let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
// The helper rejects this server before reading credentials or opening a VPN.
process.arguments = ["connect", "--user", "test", "--server", "invalid.example"]
process.standardInput = FileHandle.nullDevice
let output = Pipe()
process.standardOutput = output
process.standardError = output
try process.run()
let data = output.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
let text = String(decoding: data, as: UTF8.self)
guard text.contains("sudo:") || text.contains("uoa-proxy-helper:") else {
    fputs("supervisor did not reach sudo or the helper: \(text)", stderr)
    exit(1)
}
print("Foundation supervisor launch reached sudo")
