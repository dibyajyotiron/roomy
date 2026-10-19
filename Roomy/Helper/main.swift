// roomy-fan: the only part of Roomy that runs as root. You install it yourself from Status (one administrator
// prompt) into /Library/PrivilegedHelperTools. It takes exactly two commands and touches nothing but the fans:
//   roomy-fan auto        hand the fans back to macOS
//   roomy-fan set <0-100> hold every fan at that share of the way from its minimum to its maximum speed
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
// The file is setuid root; make the real user root too, so the SMC accepts writes.
guard setuid(0) == 0 else { fail("roomy-fan must be installed as root to control the fans", 77) }
let smc = SMC()
guard smc.isOpen else { fail("Couldn't reach the System Management Controller", 2) }

switch (args.first, args.count) {
case ("auto", 1):
    exit(smc.automatic() ? 0 : 1)
case ("set", 2):
    guard let pct = Int(args[1]), (0...100).contains(pct) else { fail("usage: roomy-fan set <0-100>", 64) }
    exit(smc.setFans(fraction: Double(pct) / 100) ? 0 : 1)
default:
    fail("usage: roomy-fan auto | set <0-100>", 64)
}
