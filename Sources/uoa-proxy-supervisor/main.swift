import Darwin
import Foundation

private let helperPath = "/Library/PrivilegedHelperTools/nz.ac.auckland.uoa-proxy/uoa-proxy-helper"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("uoa-proxy-supervisor: \(message)\n".utf8))
    exit(64)
}

let forwarded = Array(CommandLine.arguments.dropFirst())
guard forwarded.count == 5,
      forwarded[0] == "connect",
      forwarded[1] == "--user",
      forwarded[3] == "--server" else {
    fail("invalid command")
}

// The privileged helper owns the OpenConnect process group and watches the
// daemon's stdin pipe for EOF. It performs cleanup without a PID lookup.
let arguments = ["/usr/bin/sudo", "-n", helperPath] + forwarded
let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
var mutableArgv = argv
execv("/usr/bin/sudo", &mutableArgv)
fail("exec failed: \(String(cString: strerror(errno)))")
