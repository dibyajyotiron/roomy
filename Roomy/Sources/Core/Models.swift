import Foundation

/// How safe something is to remove. Every screen colours and locks items by this.
enum SafetyClass: String, Codable, CaseIterable {
    case clean      // rebuilt automatically
    case user       // your files: goes to the Trash
    case appdata    // belongs to an app: manage it from the app
    case app        // an installed app: use the Uninstaller
    case system     // macOS: never removable
    case hidden     // macOS won't let apps see it

    var label: String {
        switch self {
        case .clean: "Safe to clean"
        case .user: "Your files"
        case .appdata: "App data"
        case .app: "App"
        case .system: "System"
        case .hidden: "Hidden by macOS"
        }
    }
    var removable: Bool { self == .clean || self == .user }
    var ifRemoved: String {
        switch self {
        case .clean: "Rebuilt automatically when needed. Nothing personal is lost."
        case .user: "Moves to the Trash, so you can put it back. Check it isn't the only copy."
        case .appdata: "The app that owns it may lose settings, downloads or stop working."
        case .app: "Use the Uninstaller so the app's leftovers go too."
        case .system: "macOS needs it. Roomy shows it so you know where space goes, but never removes it."
        case .hidden: "Grant Full Disk Access so Roomy can see what's here."
        }
    }
}

struct DiskInfo: Codable, Hashable {
    var name = "Macintosh HD"
    var total: Int64 = 0
    var used: Int64 = 0
    var free: Int64 = 0
    var purgeable: Int64 = 0
}

struct CleanItem: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    var bytes: Int64
    var count: Int = 1
    var note: String?
    var review = false        // listed, never pre-selected
    var held: String?         // in use: shown, never selectable
    var why: String?
    var command: [String]?    // removed with the tool's own command instead of the Trash
    /// Found by Mole and removed only by Mole's own clean, which applies its protections at removal time.
    /// Roomy never removes these paths itself: a ledger line can name a folder Mole only cleans inside.
    var byMole: Bool? = nil
    /// Found by Roomy's own rules (`RoomyRules`): the bundle ID of the app it belongs to. Re-checked at removal.
    var app: String? = nil
}

struct CleanCategory: Codable, Identifiable, Hashable {
    var id: String { key }
    var key: String
    var title: String
    var note: String
    var safe = true
    var items: [CleanItem] = []
    var held: [CleanItem] = []
    var kept: [CleanItem] = []      // locked: listed so you know where space goes
    var checkedEmpty: [String] = []
    var blocked: String?            // e.g. needs Full Disk Access
    var skipped: String?            // e.g. Docker isn't running
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

struct AppRecord: Codable, Identifiable, Hashable {
    var id: String { path }
    var name: String
    var bundleID: String
    var version: String
    var path: String
    var bytes: Int64
    var lastUsed: Date?
    var appStore: Bool
    var apple: Bool
    var related: [CleanItem] = []
    var previewedByMole = false
    var personalKept: [String] = []
    var relatedBytes: Int64 { related.reduce(0) { $0 + $1.bytes } }
}

struct LargeFile: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var bytes: Int64
    var lastOpened: Date?
    var modified: Date?
    var isPackage = false
    var insideAppData = false
}

struct LensNode: Codable, Identifiable, Hashable {
    var id: String { path + "|" + name }
    var name: String
    var title: String?
    var path: String
    var bytes: Int64
    var cls: SafetyClass
    var why: String
    var owner: String?
    var isDir = true
    var other = false
    var children: [LensNode]?
    var display: String { (title?.isEmpty == false ? title : nil) ?? name }
}

struct DuplicateGroup: Codable, Identifiable, Hashable {
    var id: String { hash }
    var hash: String
    var name: String
    var bytes: Int64
    var files: [String]       // oldest first; the first is kept
    var wasted: Int64 { bytes * Int64(max(0, files.count - 1)) }
}

struct PhotoGroup: Codable, Identifiable, Hashable {
    var id: String { files.first ?? UUID().uuidString }
    var files: [String]
}

struct ProtectionCheck: Codable, Identifiable, Hashable {
    var id: String { title }
    var title: String
    var on: Bool?
    var summary: String
    var detail: String
}


struct OutdatedCask: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var installed: String
    var current: String
}

struct Artifact: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var kind: String
    var project: String
    var bytes: Int64
    var ageDays: Int
}

struct MaintenanceTask: Codable, Identifiable, Hashable {
    var id: String { title }
    var title: String
    var steps: [Step]
    struct Step: Codable, Hashable { var text: String; var state: String; var unverifiable: Bool }
    var unverifiable: Bool { steps.contains { $0.unverifiable } }
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var title: String
    var bytes: Int64
    var items: Int
    var simulated: Bool
    /// What couldn't be removed, with the reason.
    var failures: [String]? = nil
    /// The part that went to the Trash (space returns when the Trash is emptied).
    var trashed: Int64? = nil
    /// What was removed, "path — size", newest cleans keep up to 500 lines.
    var removed: [String]? = nil
}

// MARK: AI Cleanup & Care

struct AITool: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var appPath: String?
    var isOpen: Bool
    var bytes: Int64
}

struct AIItem: Codable, Identifiable, Hashable {
    var id: String { path }
    var tool: String
    var name: String
    var path: String
    var bytes: Int64
    var why: String
    var held: String?
}

struct AIChats: Codable, Identifiable, Hashable {
    var id: String { path }
    var tool: String
    var name: String
    var path: String
    var how: String
    var files: [ChatFile]
    struct ChatFile: Codable, Hashable { var path: String; var bytes: Int64; var modified: Date }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    func older(than days: Int) -> [ChatFile] { files.filter { Date().timeIntervalSince($0.modified) > Double(days) * 86400 } }
}

struct Worktree: Codable, Identifiable, Hashable {
    var id: String { path }
    var tool: String
    var name: String
    var project: String
    var path: String
    var bytes: Int64
    var modified: Date?
    var locked: Bool
    var why: String
    var repoRoot: String?
}

struct CLITool: Codable, Identifiable, Hashable {
    var id: String { path }
    var tool: String
    var name: String
    var path: String
    var bytes: Int64
    var lastUsed: Date
    var uninstall: [String]
    var idleDays: Int { Int(Date().timeIntervalSince(lastUsed) / 86400) }
}

struct AICare: Codable, Hashable {
    var tools: [AITool] = []
    var clear: [AIItem] = []
    var held: [AIItem] = []
    var review: [AIItem] = []
    var kept: [AIItem] = []
    var chats: [AIChats] = []
    var worktrees: [Worktree] = []
    var cliTools: [CLITool] = []
    var notFound: [String] = []

    /// Everything Roomy lets you select: caches and old versions, generated files, worktrees without
    /// uncommitted changes and idle tools. Chats are left out: they only count once you pick an age.
    var cleanable: Int64 {
        (clear + review).reduce(0) { $0 + $1.bytes }
            + worktrees.filter { !$0.locked }.reduce(0) { $0 + $1.bytes }
            + cliTools.filter { $0.idleDays >= 30 }.reduce(0) { $0 + $1.bytes }
    }
}

// MARK: Storage (System Settings categories, explained)

struct StorageSegment: Codable, Identifiable, Hashable {
    var id: String { key }
    var key: String
    var name: String
    var bytes: Int64?
    var what: String
    var versusApple: String?
    var locked = false
    var needsAccess = false
    var children: [StorageItem] = []
}

struct StorageItem: Codable, Identifiable, Hashable {
    var id: String { name + path }
    var name: String
    var path: String
    var bytes: Int64?
    var cls: SafetyClass
    var why: String
    var action: StorageAction?
    var children: [StorageItem]?
}

enum StorageAction: Codable, Hashable {
    case uninstall(appPath: String)
    case open(route: String)
    case evict
    case diskMap
    case grantAccess
    case openApp(name: String)
    // Saved snapshots name the Disk Map action by its earlier name.
    private enum CodingKeys: String, CodingKey { case uninstall, open, evict, diskMap = "spaceLens", grantAccess, openApp }
}

struct StorageReport: Codable, Hashable {
    var segments: [StorageSegment] = []
    var hiddenBytes: Int64 = 0
    /// Whether the scan that measured this had Full Disk Access (nil for reports saved before this was recorded).
    var measuredWithAccess: Bool? = nil
}
