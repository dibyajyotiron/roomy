import Foundation

/// One-time recovery for older Roomy builds. Current previews and cleans never edit Mole's settings.
enum MoleLegacySettings {
    static let absentMark = Data("ROOMY-NO-WHITELIST-FILE".utf8)

    static func recover(config: URL, support: URL) -> [String] {
        [("whitelist", "mole-whitelist.backup"), ("whitelist_optimize", "mole-whitelist-optimize.backup")].compactMap { name, backup in
            recover(file: config.appendingPathComponent(name), backup: support.appendingPathComponent(backup))
        }
    }

    /// Retain the backup on any error or external edit; never replace a keep list Roomy does not own.
    static func recover(file: URL, backup: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path) else { return nil }
        do {
            func readRegular(_ url: URL) throws -> Data? {
                let attrs: [FileAttributeKey: Any]
                do { attrs = try fm.attributesOfItem(atPath: url.path) }
                catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
                guard attrs[.type] as? FileAttributeType == .typeRegular else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                return try Data(contentsOf: url)
            }
            guard let saved = try readRegular(backup) else { return nil }
            let current = try readRegular(file)
            if current == saved || (current == nil && saved == absentMark) {
                try fm.removeItem(at: backup)
                return nil
            }
            guard let current, String(decoding: current, as: UTF8.self).contains("\n# Roomy:") else {
                return "An older Mole keep-list backup was preserved because the keep list changed. Review it before cleaning."
            }
            if saved == absentMark { try fm.removeItem(at: file) }
            else { try saved.write(to: file, options: .atomic) }
            guard try readRegular(file) == (saved == absentMark ? nil : saved) else { throw CocoaError(.fileWriteUnknown) }
            try fm.removeItem(at: backup)
            return nil
        } catch {
            return "Couldn't restore an older Mole keep list; its backup was preserved. Review it before cleaning."
        }
    }
}
