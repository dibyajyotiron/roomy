// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from Mole (github.com/tw93/mole @ b9361703158c): lib/core/base.sh bytes_to_human

public enum ByteFormat {
    /// Decimal units with Mole's rounding: "2.80GB", "44.5MB", "14KB", "512B".
    public static func human(_ bytes: Int64) -> String {
        if bytes < 0 { return "0B" }
        if bytes >= 1_000_000_000 {
            let scaled = (bytes * 100 + 500_000_000) / 1_000_000_000
            return "\(scaled / 100).\(pad2(scaled % 100))GB"
        }
        if bytes >= 1_000_000 {
            let scaled = (bytes * 10 + 500_000) / 1_000_000
            return "\(scaled / 10).\(scaled % 10)MB"
        }
        if bytes >= 1_000 { return "\((bytes + 500) / 1_000)KB" }
        return "\(bytes)B"
    }

    private static func pad2(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
