import Foundation

/// Runs command-line tools for the engines. GUI apps start with a minimal PATH, so the usual
/// Homebrew and system locations are added. stdout and stderr are merged, like the CLI tools print them.
enum Shell {
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static var baseEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath + ":" + (env["PATH"] ?? "")
        env["HOME"] = NSHomeDirectory()
        return env
    }

    static func which(_ tool: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct Result {
        var output: String
        var status: Int32
        var ok: Bool { status == 0 }
    }

    /// Runs `executable` (a full path or a name found on `searchPath`) and returns its output.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 600, input: String? = nil, directory: String? = nil) async -> Result {
        guard let exe = executable.hasPrefix("/") ? executable : which(executable) else {
            return Result(output: "", status: 127)
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = arguments
                p.environment = environment ?? baseEnvironment
                p.currentDirectoryURL = URL(fileURLWithPath: directory ?? NSHomeDirectory())
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                let inPipe = Pipe()
                p.standardInput = inPipe
                do { try p.run() } catch {
                    cont.resume(returning: Result(output: "", status: 126))
                    return
                }
                if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
                try? inPipe.fileHandleForWriting.close()
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: Result(output: String(decoding: data, as: UTF8.self), status: p.terminationStatus))
            }
        }
    }
}

// MARK: - Small regex helpers (the engines parse CLI text the same way the Python comp did)

extension String {
    func matches(_ pattern: String, options: NSRegularExpression.Options = []) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> [String?]? {
        matches(pattern, options: options).first
    }

    func contains(regex pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        firstMatch(pattern, options: options) != nil
    }

    func replacing(regex pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(location: 0, length: (self as NSString).length), withTemplate: template)
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
