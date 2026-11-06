import Foundation
// Stand-in for Roomy: runs the helper with the given args, then lives for N seconds and exits (or crashes).
let a = CommandLine.arguments
if a[3] == "twice" {
    for percent in [60, 90] {
        let child = Process(); child.executableURL = URL(fileURLWithPath: a[1]); child.arguments = ["set", String(percent)]
        try! child.run(); child.waitUntilExit()
        guard child.terminationStatus == 0 else { exit(child.terminationStatus) }
    }
    Thread.sleep(forTimeInterval: 1)
    exit(0)
}
let p = Process(); p.executableURL = URL(fileURLWithPath: a[1]); p.arguments = Array(a[4...])
let out = Pipe(); p.standardOutput = out
try! p.run(); p.waitUntilExit()
print(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "exit=\(p.terminationStatus)")
fflush(stdout)
Thread.sleep(forTimeInterval: Double(a[2])!)
if a[3] == "crash" { abort() }
