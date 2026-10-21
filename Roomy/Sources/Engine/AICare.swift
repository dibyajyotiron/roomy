import Foundation

/// What AI tools leave behind, sorted by the decision it needs:
/// clear (rebuilt or replaced), held (an open app uses it), review (only you can decide), kept (stays with the tool).
enum AICareEngine {
    struct Tool { var name: String; var app: String?; var process: String? }

    static let tools: [String: Tool] = [
        "claude": Tool(name: "Claude", app: "/Applications/Claude.app", process: "/Claude.app/Contents/"),
        "claudecode": Tool(name: "Claude Code", app: nil, process: "(^|/)claude( |$)"),
        "codex": Tool(name: "Codex", app: "/Applications/ChatGPT.app", process: "/Codex.app/|Application Support/Codex"),
        "chatgpt": Tool(name: "ChatGPT", app: "/Applications/ChatGPT.app", process: "/ChatGPT.app/Contents/MacOS/ChatGPT"),
        "cursor": Tool(name: "Cursor", app: "/Applications/Cursor.app", process: "/Cursor.app/Contents/MacOS/Cursor"),
        "windsurf": Tool(name: "Windsurf", app: "/Applications/Windsurf.app", process: "/Windsurf.app/"),
        "antigravity": Tool(name: "Antigravity", app: "/Applications/Antigravity.app", process: "/Antigravity.app/"),
        "lmstudio": Tool(name: "LM Studio", app: "/Applications/LM Studio.app", process: "/LM Studio.app/"),
        "ollama": Tool(name: "Ollama", app: "/Applications/Ollama.app", process: "ollama serve"),
        "opencode": Tool(name: "OpenCode", app: "/Applications/OpenCode.app", process: "/OpenCode.app/"),
        "openclaw": Tool(name: "OpenClaw", app: nil, process: "(^|/)openclaw( |$)"),
        "copilot": Tool(name: "GitHub Copilot CLI", app: nil, process: nil),
        "qoder": Tool(name: "Qoder", app: "/Applications/Qoder.app", process: "/Qoder.app/"),
        "huggingface": Tool(name: "Hugging Face", app: nil, process: nil),
    ]

    typealias Rule = (tool: String, path: String, label: String, why: String)

    static let cacheRules: [Rule] = [
        ("claude", "~/Library/Application Support/Claude/Cache", "Web cache", "Claude downloads these again when needed."),
        ("claude", "~/Library/Application Support/Claude/Code Cache", "Script cache", "Rebuilt the next time Claude opens."),
        ("claude", "~/Library/Application Support/Claude/GPUCache", "Graphics cache", "Rebuilt the next time Claude opens."),
        ("claude", "~/Library/Application Support/Claude/GraphiteDawnCache", "Graphics cache", "Rebuilt the next time Claude opens."),
        ("claude", "~/Library/Application Support/Claude/sentry", "Crash report queue", "Unsent crash reports."),
        ("claude", "~/Library/Logs/Claude", "Logs", "Diagnostic logs."),
        ("claudecode", "~/.claude/cache", "Cache", "Claude Code rebuilds it."),
        ("claudecode", "~/.claude/shell-snapshots", "Shell snapshots", "Recreated for each new session."),
        ("claudecode", "~/.claude/telemetry", "Unsent telemetry", "Usage events waiting to upload."),
        ("codex", "~/Library/Application Support/Codex/Cache", "Web cache", "Codex downloads these again when needed."),
        ("codex", "~/Library/Application Support/Codex/Code Cache", "Script cache", "Rebuilt the next time Codex opens."),
        ("codex", "~/Library/Application Support/Codex/GPUCache", "Graphics cache", "Rebuilt the next time Codex opens."),
        ("codex", "~/Library/Application Support/Codex/GraphiteDawnCache", "Graphics cache", "Rebuilt the next time Codex opens."),
        ("codex", "~/Library/Application Support/Codex/Crashpad", "Crash reports", "Old crash reports."),
        ("codex", "~/Library/Caches/com.openai.codex/Cache.db", "Download cache", "Rebuilt automatically."),
        ("codex", "~/Library/Caches/com.openai.codex/fsCachedData", "Download cache", "Rebuilt automatically."),
        ("codex", "~/.codex/cache", "Cache", "Codex rebuilds it."),
        ("codex", "~/.codex/.tmp", "Temporary files", "Left over from finished tasks."),
        ("codex", "~/.codex/tmp", "Temporary files", "Left over from finished tasks."),
        ("chatgpt", "~/Library/Caches/com.openai.chat", "Download cache", "Rebuilt automatically."),
        ("cursor", "~/Library/Application Support/Cursor/Cache", "Web cache", "Rebuilt the next time Cursor opens."),
        ("cursor", "~/Library/Application Support/Cursor/CachedData", "Compiled code cache", "Rebuilt the next time Cursor opens."),
        ("cursor", "~/Library/Application Support/Cursor/GPUCache", "Graphics cache", "Rebuilt the next time Cursor opens."),
        ("cursor", "~/Library/Application Support/Cursor/CachedProfilesData", "Profile cache", "Rebuilt the next time Cursor opens."),
        ("cursor", "~/Library/Application Support/Cursor/logs", "Logs", "Diagnostic logs."),
        ("cursor", "~/Library/Caches/Cursor", "Download cache", "Rebuilt automatically."),
        ("antigravity", "~/Library/Application Support/Antigravity/Cache", "Web cache", "Rebuilt automatically."),
        ("antigravity", "~/Library/Application Support/Antigravity/CachedData", "Compiled code cache", "Rebuilt automatically."),
        ("antigravity", "~/Library/Application Support/Antigravity/GPUCache", "Graphics cache", "Rebuilt automatically."),
        ("antigravity", "~/Library/Application Support/Antigravity/logs", "Logs", "Diagnostic logs."),
        ("lmstudio", "~/.lmstudio/.internal/staged-updates-app", "Downloaded update", "An app update LM Studio already installed."),
        ("lmstudio", "~/.lmstudio/server-logs", "Server logs", "Logs from the local model server."),
        ("opencode", "~/.cache/opencode", "Cache", "OpenCode rebuilds it."),
        ("opencode", "~/.local/share/opencode/log", "Logs", "Diagnostic logs."),
        ("qoder", "~/Library/Application Support/Qoder/Cache", "Web cache", "Rebuilt automatically."),
        ("huggingface", "~/.cache/huggingface/xet", "Download chunks", "Partial downloads; models stay."),
    ]

    static let keptRules: [Rule] = [
        ("claude", "~/Library/Application Support/Claude/vm_bundles", "Sandbox virtual machine", "The Linux VM Claude runs code in. Claude downloads and updates it; turn the feature off in Claude to remove it."),
        ("claude", "~/Library/Application Support/Claude/Partitions", "Signed-in web data", "Sign-ins, local storage and settings for Claude's windows. Removing it signs you out."),
        ("claude", "~/Library/Application Support/Claude/claude-code-vm", "Claude Code for the sandbox", "The version the sandbox uses right now."),
        ("claudecode", "~/.claude/plugins", "Plugins", "Installed plugins and their settings."),
        ("claudecode", "~/.claude/skills", "Skills", "Your skills."),
        ("codex", "~/.codex/thread_history_1.sqlite", "Chat index", "Codex's index of every chat. Removing it breaks chat history; remove chats instead."),
        ("codex", "~/.codex/plugins", "Plugins", "Installed plugins."),
        ("codex", "~/.codex/packages", "Helper packages", "Helpers Codex installed and still uses."),
        ("codex", "~/.codex/memories", "Memories", "What Codex remembers about you."),
        ("codex", "~/.codex/skills", "Skills", "Your skills."),
        ("codex", "~/Library/Application Support/Codex/Default", "Signed-in web data", "Sign-ins and settings."),
        ("codex", "~/Library/Application Support/Codex/Partitions", "Signed-in web data", "Sign-ins and settings."),
        ("cursor", "~/Library/Application Support/Cursor/User", "Settings and workspace state", "Your settings and per-project history."),
        ("windsurf", "~/.codeium/database", "Code index", "Windsurf's search index of your projects. Rebuilding it takes a while."),
        ("windsurf", "~/.codeium/windsurf", "Settings and memories", "Windsurf's settings, memories and rules."),
        ("windsurf", "~/.codeium/ws-browser", "Built-in browser profile", "Sign-ins for Windsurf's browser."),
        ("antigravity", "~/.gemini/antigravity", "Agent data", "Antigravity's conversations and knowledge."),
        ("lmstudio", "~/.lmstudio/.internal/bundled-models", "Bundled models", "Models that ship with LM Studio."),
        ("lmstudio", "~/.lmstudio/models", "Your models", "Downloaded models. Remove them in LM Studio › My Models."),
        ("lmstudio", "~/.lmstudio/extensions/frameworks", "Runtime frameworks", "Shared libraries the runtimes need."),
        ("huggingface", "~/.cache/huggingface/hub", "Downloaded models", "Models downloaded by Python tools. Remove with `hf cache delete` so the index stays consistent."),
    ]

    static func isOpen(_ id: String) async -> Bool {
        guard let p = tools[id]?.process else { return false }
        return await Shell.run("/usr/bin/pgrep", ["-f", p], timeout: 10).ok
    }

    static func scan() async -> AICare {
        var open: [String: Bool] = [:]
        for id in tools.keys { open[id] = await isOpen(id) }
        let updater = await Shell.run("/usr/bin/pgrep", ["-f", "Sparkle|Autoupdate"], timeout: 10).ok
        var care = AICare()

        let rulePaths = (cacheRules + keptRules).map { Paths.expand($0.path) }.filter { FileManager.default.fileExists(atPath: $0) }
        var versionRules: [Rule] = oldClaudeBundles() + oldLMStudioRuntimes()
        let sizes = await diskSizes(rulePaths + versionRules.map { Paths.expand($0.path) })

        for r in cacheRules {
            guard let b = sizes[Paths.expand(r.path)], b >= 4096 else { continue }
            var it = AIItem(tool: r.tool, name: r.label, path: r.path, bytes: b, why: r.why)
            if open[r.tool] == true { it.held = "\(tools[r.tool]!.name) is open. Cleared after you quit it."; care.held.append(it) } else { care.clear.append(it) }
        }
        let staging = "~/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle"
        if Paths.isDir(staging) {
            var it = AIItem(tool: "codex", name: "Update download", path: staging, bytes: diskSize(staging), why: "A Codex update waiting to install.")
            if updater || open["codex"] == true { it.held = "The updater is using it. Cleared after the update finishes."; care.held.append(it) } else { care.clear.append(it) }
        }
        for r in versionRules {
            guard let b = sizes[Paths.expand(r.path)], b >= 4096 else { continue }
            var it = AIItem(tool: r.tool, name: r.label, path: Paths.short(r.path), bytes: b, why: r.why)
            if open[r.tool] == true { it.held = "\(tools[r.tool]!.name) is open. Removed after you quit it."; care.held.append(it) }
            else if r.tool == "lmstudio" { care.review.append(it) } else { care.clear.append(it) }
        }
        versionRules.removeAll()
        let vsc = Paths.children("~/.vscode/extensions").filter { Paths.name($0).hasPrefix("anthropic.claude-code-") }.sorted {
            $0.matches(#"\d+"#).prefix(3).compactMap { Int($0[0] ?? "") }.lexicographicallyPrecedes($1.matches(#"\d+"#).prefix(3).compactMap { Int($0[0] ?? "") })
        }
        // Only what VS Code itself has let go: a folder its extensions.json no longer lists, or one it marked obsolete.
        // Without that file Roomy can't tell which copy VS Code loads, so nothing is offered.
        let vscIndex = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Paths.expand("~/.vscode/extensions/extensions.json"))))) as? [[String: Any]]
        let vscLoaded = Set((vscIndex ?? []).compactMap { $0["relativeLocation"] as? String })
        let vscObsolete = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Paths.expand("~/.vscode/extensions/.obsolete"))))) as? [String: Any]).map { Set($0.keys) } ?? []
        for q in vsc.dropLast() where vscIndex != nil && (!vscLoaded.contains(Paths.name(q)) || vscObsolete.contains(Paths.name(q))) {
            care.clear.append(AIItem(tool: "claudecode", name: "VS Code extension \(Paths.name(q).components(separatedBy: "-")[2])", path: Paths.short(q),
                                     bytes: diskSize(q), why: "VS Code installed a newer one and no longer loads this."))
        }
        // Codex keeps every helper release it ever downloaded; only the newest is used. Older ones are safe to remove
        // even while Codex is open, unless a running process still loads one.
        let running = await Shell.run("/bin/ps", ["-Ao", "command="], timeout: 10).output
        for pkg in Paths.children("~/.codex/packages") where Paths.isDir(pkg + "/releases") {
            let releases = Paths.children(pkg + "/releases").filter(Paths.isDir).sorted { Paths.name($0).compare(Paths.name($1), options: .numeric) == .orderedAscending }
            for old in releases.dropLast() {
                let version = Paths.name(old).components(separatedBy: "-").first ?? Paths.name(old)
                var it = AIItem(tool: "codex", name: "Old \(Paths.name(pkg)) \(version)", path: Paths.short(old), bytes: diskSize(old),
                                why: "Replaced by \(Paths.name(releases.last!).components(separatedBy: "-").first ?? "a newer release"). Codex no longer uses it.")
                if running.contains(Paths.expand(old)) { it.held = "Still running. Removed after Codex quits."; care.held.append(it) } else { care.clear.append(it) }
            }
        }
        if Paths.isDir("~/.cache/codex-runtimes") {
            care.held.append(AIItem(tool: "codex", name: "Codex runtime", path: "~/.cache/codex-runtimes", bytes: diskSize("~/.cache/codex-runtimes"),
                                    why: "The runtime Codex runs tools with.", held: "In use by Codex. Checked again after Codex quits."))
        }
        // Chats: listed with an age picker, nothing selected until you pick an age
        func chats(_ tool: String, _ name: String, _ root: String, _ pattern: String, _ how: String, filter: (String) -> Bool = { _ in true }) {
            let files = walk(root, pattern: pattern).filter { filter($0.path) }
            if !files.isEmpty { care.chats.append(AIChats(tool: tool, name: name, path: root, how: how, files: files)) }
        }
        chats("codex", "Codex chats", "~/.codex/sessions", #"^rollout-.*\.jsonl(\.zst)?$"#, "Moved to the Trash, so you can put them back.")
        chats("codex", "Archived Codex chats", "~/.codex/archived_sessions", #"\.jsonl(\.zst)?$"#, "Chats you already archived in Codex. Moved to the Trash.")
        chats("claudecode", "Claude Code chats", "~/.claude/projects", #"\.jsonl$"#, "Moved to the Trash. `claude --resume` stops listing them.")
        chats("cursor", "Cursor agent transcripts", "~/.cursor/projects", #"\.jsonl$"#, "Moved to the Trash.") { $0.contains("/agent-transcripts/") }

        for (p, label) in [("~/.codex/generated_images", "Images Codex made"), ("~/.codex/visualizations", "Visualizations Codex made")] where Paths.exists(p) {
            care.review.append(AIItem(tool: "codex", name: label, path: p, bytes: diskSize(p), why: "Files Codex created for you. They go to the Trash, so you can put them back."))
        }
        for r in keptRules {
            if let b = sizes[Paths.expand(r.path)], b >= 1_000_000 { care.kept.append(AIItem(tool: r.tool, name: r.label, path: r.path, bytes: b, why: r.why)) }
        }
        care.worktrees = await worktrees()
        care.cliTools = cliTools()

        var footprint: [String: Int64] = [:]
        for i in care.clear + care.held + care.review + care.kept { footprint[i.tool, default: 0] += i.bytes }
        for c in care.chats { footprint[c.tool, default: 0] += c.bytes }
        for w in care.worktrees { footprint[w.tool, default: 0] += w.bytes }
        for t in care.cliTools { footprint[t.tool, default: 0] += t.bytes }
        care.tools = footprint.keys.sorted { footprint[$0]! > footprint[$1]! }.map { id in
            AITool(id: id, name: tools[id]?.name ?? id, appPath: tools[id]?.app.flatMap { Paths.exists($0) ? $0 : nil }, isOpen: open[id] ?? false, bytes: footprint[id]!)
        }
        care.notFound = ["ollama", "windsurf", "huggingface"].filter { footprint[$0] == nil }.map { tools[$0]!.name }
        for k in [\AICare.clear, \.held, \.review, \.kept] { care[keyPath: k].sort { $0.bytes > $1.bytes } }
        return care
    }

    static func walk(_ root: String, pattern: String) -> [AIChats.ChatFile] {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: Paths.expand(root)),
                                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]) else { return [] }
        var out: [AIChats.ChatFile] = []
        for case let u as URL in e where u.lastPathComponent.contains(regex: pattern, options: []) {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey])
            out.append(.init(path: u.path, bytes: Int64(v?.totalFileAllocatedSize ?? 0), modified: v?.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// Claude Desktop keeps earlier bundled Claude Code builds; the active one is in .sdk-version.
    static func oldClaudeBundles() -> [Rule] {
        let root = Paths.expand("~/Library/Application Support/Claude/claude-code")
        let active = (try? String(contentsOfFile: Paths.expand("~/Library/Application Support/Claude/claude-code-vm/.sdk-version"), encoding: .utf8))?.trimmed ?? ""
        let vers = Paths.children(root).map(Paths.name).filter { $0.contains(regex: #"^\d+\.\d+\.\d+$"#, options: []) }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        let keep = Set([vers.last ?? "", active])
        return vers.filter { !keep.contains($0) }.map { ("claude", root + "/" + $0, "Claude Code \($0)", "An earlier build bundled with Claude. \(active.isEmpty ? vers.last ?? "" : active) is in use.") }
    }

    /// LM Studio keeps every runtime it downloaded; the newest of each family stays.
    static func oldLMStudioRuntimes() -> [Rule] {
        let root = Paths.expand("~/.lmstudio/extensions/backends")
        var fam: [String: [String]] = [:]
        for n in Paths.children(root).map(Paths.name) {
            if let m = n.firstMatch(#"^(.*)-(\d+(?:\.\d+)+)$"#), let f = m[1] { fam[f, default: []].append(n) }
        }
        var out: [Rule] = []
        for (f, names) in fam {
            let sorted = names.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            let label = f.hasPrefix("llama.cpp") ? "llama.cpp" : f.hasPrefix("mlx") ? "MLX" : f
            let newest = sorted.last!.components(separatedBy: "-").last!
            for n in sorted.dropLast() {
                out.append(("lmstudio", root + "/" + n, "\(label) runtime \(n.components(separatedBy: "-").last!)",
                            "Replaced by \(newest). LM Studio can also remove it in Settings › Runtimes."))
            }
        }
        return out
    }

    /// Codex and Claude Code worktrees. Clean ones can go with `git worktree remove`; ones with changes stay locked.
    static func worktrees() async -> [Worktree] {
        var roots: [(String, String, String?)] = []
        for task in Paths.children("~/.codex/worktrees") where Paths.isDir(task) {
            for repo in Paths.children(task) where Paths.isDir(repo) { roots.append(("codex", repo, nil)) }
        }
        for base in ["~/Desktop", "~/Documents", "~/Developer", "~/Projects", "~/code"] where Paths.isDir(base) {
            let r = await Shell.run("/usr/bin/find", [Paths.expand(base), "-maxdepth", "5", "-type", "d", "-path", "*/.claude/worktrees", "-prune"], timeout: 120)
            for wt in r.output.split(separator: "\n").map(String.init) {
                for n in Paths.children(wt) where Paths.isDir(n) { roots.append(("claudecode", n, Paths.parent(Paths.parent(wt)))) }
            }
        }
        let sizes = await diskSizes(roots.map(\.1))
        var out: [Worktree] = []
        for (tool, p, repo) in roots {
            let st = await Shell.run("git", ["-C", p, "--no-optional-locks", "status", "--porcelain"], timeout: 30)
            let project = repo.map(Paths.name) ?? Paths.name(p)
            let name = tool == "codex" ? Paths.name(Paths.parent(p)) : Paths.name(p)
            var w = Worktree(tool: tool, name: name, project: project, path: Paths.short(p), bytes: sizes[p] ?? 0, modified: Paths.mtime(p), locked: false, why: "", repoRoot: repo)
            if !st.ok {
                w.why = "Git no longer knows this worktree, so its changes can't be checked. Look inside before removing it."
            } else if !st.output.trimmed.isEmpty {
                let n = st.output.trimmed.split(separator: "\n").count
                w.locked = true; w.why = "\(n) uncommitted change\(n > 1 ? "s" : ""). Commit or discard them first."
            } else {
                w.why = "No uncommitted changes. Removed with `git worktree remove`, so the branch stays in the repository."
            }
            out.append(w)
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func cliTools() -> [CLITool] {
        var cands: [(String, String, [String], [String])] = [
            ("copilot", "/opt/homebrew/Caskroom/copilot-cli", ["~/.copilot"], ["brew", "uninstall", "copilot-cli"]),
            ("opencode", "~/.opencode", ["~/.local/share/opencode"], []),
        ]
        for nv in Paths.children("~/.nvm/versions/node") {
            for (id, pkg, state, cmd) in [("openclaw", "openclaw", "~/.openclaw", "openclaw"), ("claudecode", "@anthropic-ai/claude-code", "~/.claude/projects", "@anthropic-ai/claude-code"),
                                         ("codex", "@openai/codex", "~/.codex/sessions", "@openai/codex")] {
                let p = nv + "/lib/node_modules/" + pkg
                if Paths.isDir(p) { cands.append((id, p, [state], ["npm", "uninstall", "-g", cmd])) }
            }
        }
        return cands.compactMap { (id, pkg, state, cmd) in
            guard Paths.exists(pkg) else { return nil }
            let last = state.compactMap { Paths.mtime($0) }.max() ?? Paths.mtime(pkg) ?? Date()
            return CLITool(tool: id, name: tools[id]?.name ?? id, path: Paths.short(Paths.expand(pkg)), bytes: diskSize(pkg), lastUsed: last, uninstall: cmd)
        }.sorted { $0.idleDays > $1.idleDays }
    }
}
