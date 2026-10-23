// Fan readings and control through the System Management Controller.
// Ported and trimmed from Stats' SMC module (https://github.com/exelban/stats, SMC/smc.swift),
// Copyright © 2021 Serhiy Mytrovtsiy, MIT License — see LICENSES/Stats-MIT.txt.
import Foundation
import IOKit

/// A connection to AppleSMC. Reading needs no privileges; writing (fan control) needs root, so Roomy only writes from
/// its fan helper.
final class SMC {
    struct Value { var key: String; var size: UInt32 = 0; var type = ""; var bytes = [UInt8](repeating: 0, count: 32) }

    private struct KeyData {
        typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        struct Vers { var major: CUnsignedChar = 0; var minor: CUnsignedChar = 0; var build: CUnsignedChar = 0; var reserved: CUnsignedChar = 0; var release: CUnsignedShort = 0 }
        struct PLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: IOByteCount32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    var isOpen: Bool { conn != 0 }

    init() {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return }
        if IOServiceOpen(device, mach_task_self_, 0, &conn) != kIOReturnSuccess { conn = 0 }
        IOObjectRelease(device)
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ c: UInt32) -> String {
        String(bytes: [UInt8(c >> 24 & 0xff), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)], encoding: .ascii) ?? ""
    }

    private func call(_ input: inout KeyData, _ output: inout KeyData) -> kern_return_t {
        var size = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
    }

    func read(_ key: String) -> Value? {
        guard conn != 0, key.utf8.count == 4 else { return nil }
        var input = KeyData(), output = KeyData()
        input.key = Self.code(key)
        input.data8 = 9   // key info
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0, output.keyInfo.dataSize > 0 else { return nil }
        var v = Value(key: key, size: output.keyInfo.dataSize, type: Self.string(output.keyInfo.dataType))
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5   // read bytes
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        withUnsafeBytes(of: output.bytes) { raw in for i in 0..<min(Int(v.size), 32) { v.bytes[i] = raw[i] } }
        return v
    }

    @discardableResult
    func write(_ v: Value) -> Bool {
        guard conn != 0 else { return false }
        var input = KeyData(), output = KeyData()
        input.key = Self.code(v.key)
        input.data8 = 6   // write bytes
        input.keyInfo.dataSize = v.size
        withUnsafeMutableBytes(of: &input.bytes) { raw in for i in 0..<32 { raw[i] = v.bytes[i] } }
        // IOKit can succeed while the SMC itself refuses the write; its result byte says which.
        return call(&input, &output) == kIOReturnSuccess && output.result == 0
    }

    func writeRetrying(_ v: Value, attempts: Int = 10, delay: useconds_t = 50_000) -> Bool {
        for i in 0..<attempts {
            if write(v) { return true }
            if i < attempts - 1 { usleep(delay) }
        }
        return false
    }

    /// A numeric reading, whatever its SMC encoding.
    func number(_ key: String) -> Double? {
        guard let v = read(key) else { return nil }
        switch v.type {
        case "flt ": return Double(v.bytes.withUnsafeBytes { $0.load(as: Float.self) })
        case "fpe2": return Double((Int(v.bytes[0]) << 6) + (Int(v.bytes[1]) >> 2))
        case "ui8 ": return Double(v.bytes[0])
        case "ui16": return Double(UInt16(v.bytes[0]) << 8 | UInt16(v.bytes[1]))
        case "ui32": return Double(UInt32(v.bytes[0]) << 24 | UInt32(v.bytes[1]) << 16 | UInt32(v.bytes[2]) << 8 | UInt32(v.bytes[3]))
        default: return nil
        }
    }

    /// Every key the SMC knows, by index. Reading the list needs no privileges.
    func allKeys() -> [String] {
        guard let n = number("#KEY") else { return [] }
        var out: [String] = []
        for i in 0..<Int(n) {
            var input = KeyData(), output = KeyData()
            input.data8 = 8   // key at index
            input.data32 = UInt32(i)
            if call(&input, &output) == kIOReturnSuccess, output.result == 0 { out.append(Self.string(output.key)) }
        }
        return out
    }

    // MARK: temperatures

    struct Sensor: Hashable { var key: String; var celsius: Double }

    private lazy var temperatureKeys: [String] = allKeys().filter { $0.hasPrefix("T") && read($0)?.type == "flt " }

    /// Every temperature sensor reporting a plausible reading right now.
    func temperatures() -> [Sensor] {
        temperatureKeys.compactMap { k in number(k).flatMap { (5...130).contains($0) ? Sensor(key: k, celsius: $0) : nil } }
    }

    // MARK: fans

    struct Fan: Hashable { var id: Int; var rpm: Double; var min: Double; var max: Double; var manual: Bool }

    func fans() -> [Fan] {
        let count = Int(number("FNum") ?? 0)
        // On M1–M4, macOS's own thermal daemon keeps every fan in "forced" mode with targets it sets, so the mode key
        // says nothing about who is in charge. The test flag does: it's only set when an app has taken over.
        let takenOver = read("Ftst").map { $0.bytes[0] == 1 }
        return (0..<min(count, 4)).compactMap { i in
            guard let rpm = number("F\(i)Ac") else { return nil }
            return Fan(id: i, rpm: max(0, rpm), min: number("F\(i)Mn") ?? 0, max: number("F\(i)Mx") ?? 0,
                       manual: takenOver ?? ((read(modeKey(i))?.bytes[0] ?? 0) == 1))
        }
    }

    private lazy var lowerModeKey = read("F0md") != nil
    func modeKey(_ i: Int) -> String { lowerModeKey ? "F\(i)md" : "F\(i)Md" }

    /// Holds every fan at `fraction` of the way from its minimum to its maximum speed. Needs root.
    func setFans(fraction: Double) -> Bool {
        let f = Swift.max(0, Swift.min(1, fraction))
        var ok = true
        for fan in fans() {
            guard unlock(fan.id), var target = read("F\(fan.id)Tg") else { ok = false; continue }
            let rpm = fan.min + (fan.max - fan.min) * f
            if target.type == "flt " {
                withUnsafeBytes(of: Float(rpm)) { raw in for j in 0..<4 { target.bytes[j] = raw[j] } }
            } else if target.type == "fpe2" {
                let s = Int(rpm)
                target.bytes[0] = UInt8(s >> 6); target.bytes[1] = UInt8((s << 2) & 0xff)
            } else { ok = false; continue }
            ok = writeRetrying(target) && ok
        }
        return ok
    }

    /// Hands the fans back to macOS, the way Stats does: each fan's mode back to automatic and its target cleared while
    /// the override is still on (Apple silicon only takes fan writes then), and only then the override off, so macOS's
    /// thermal daemon takes over from a clean state. Clearing only the override left the fans forced at their last
    /// target, so after Max they could stay fast. On chips without the override key (Intel, M5) the mode alone does it.
    func automatic() -> Bool {
        let count = Swift.min(Int(number("FNum") ?? 0), 4)
        var override = read("Ftst")
        // A fan left forced with the override already off (an older Roomy cleared only the override, so Cool or Max
        // stayed held) can't be reset: these chips take fan writes only while the override is on. Take it back for a
        // moment, wait for macOS to let go (Stats waits 3 s too), reset the fans, then release it below.
        if var t = override, t.bytes[0] == 0, (0..<count).contains(where: { (read(modeKey($0))?.bytes[0] ?? 0) != 0 }) {
            t.bytes[0] = 1
            if writeRetrying(t, attempts: 100) { usleep(3_000_000); override = t }
        }
        let overridden = override.map { $0.bytes[0] != 0 } ?? true
        var ok = true
        for i in 0..<count {
            if var m = read(modeKey(i)), m.bytes[0] != 0 {
                m.bytes[0] = 0
                ok = (writeRetrying(m, attempts: 300, delay: 100_000) || !overridden) && ok
            }
            if var t = read("F\(i)Tg") {
                if t.type == "flt " { for j in 0..<4 { t.bytes[j] = 0 } }
                else if t.type == "fpe2" { t.bytes[0] = 0; t.bytes[1] = 0 }
                _ = writeRetrying(t, attempts: 20)
            }
        }
        if var t = override, t.bytes[0] != 0 {
            t.bytes[0] = 0
            ok = writeRetrying(t, attempts: 100) && ok
        }
        return ok
    }

    /// Puts one fan in manual mode. M1–M4 first need the test flag, after which thermalmonitord takes a few seconds
    /// to let go; M5 and later accept the mode directly.
    private func unlock(_ id: Int) -> Bool {
        guard var m = read(modeKey(id)) else { return false }
        m.bytes[0] = 1
        if var t = read("Ftst") {
            if t.bytes[0] != 1 {
                t.bytes[0] = 1
                guard writeRetrying(t, attempts: 100) else { return false }
                usleep(3_000_000)
            }
            return writeRetrying(m, attempts: 300, delay: 100_000)
        }
        return writeRetrying(m, attempts: 20)
    }
}
