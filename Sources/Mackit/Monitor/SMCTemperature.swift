import Foundation
import IOKit

/// CPU temperature read from the System Management Controller (SMC).
///
/// macOS exposes no public API for a numeric CPU temperature, so this reads
/// the SMC through IOKit.
///
/// The path is private but alive: verified on macOS 27 (Apple Silicon M2),
/// where the AppleSMC service opens and its sensor keys answer — the M2's
/// table answers with 8 of 14 keys, all `flt `-typed floats in the 71–86°C
/// band under load, and the six absent keys report a kext error that the
/// average skips. Keys that answer with nothing usable are skipped per key;
/// when no key answers at all the read is nil and the caller keeps its
/// public-API fallback (`ProcessInfo.thermalState`).
///
/// What the number means:
/// - **Intel**: the first sensor in `TC0P` (proximity), `TC0D` (diode),
///   `TC0H` (heatsink), `TC0E`, `TC0F` (filtered), `TCAD` (package) order
///   that answers with a plausible value (0 < °C ≤ 110).
/// - **Apple Silicon**: the average of the chip family's sensor table, the
///   GPU sensors included.
///
/// Only the Apple Silicon path has been verified against real hardware (an
/// M2 on macOS 27). The Intel path — key order and sp78 decoding — is covered
/// by unit tests, but no Intel machine was available to run it on; a wrong
/// assumption there degrades to nil, exactly like any other unanswered key.
///
/// Selection and filtering are a pure function over an injected key reader,
/// so the logic is unit-testable without an SMC; `readCPU()` is the thin
/// IOKit shell around it.
enum SMCTemperature {
    /// One key's answer: the byte count, the fourcc data type ("sp78",
    /// "flt ", …) and the raw bytes.
    typealias KeyValue = (size: UInt32, type: UInt32, bytes: [UInt8])

    /// Reads one SMC key. Injectable so tests can drive the selection and
    /// filtering logic; the real reader returns nil for any key that does
    /// not answer — absent on this machine, or refused.
    typealias KeyReader = (_ key: String) -> KeyValue?

    /// Reads the CPU temperature from the SMC, or nil when no key answers
    /// with a usable value.
    ///
    /// One connection per call, opened and closed per read (measured at a few
    /// milliseconds for the whole read): a connection held across samples
    /// would be shared mutable state, and the sampler runs on the main actor.
    static func readCPU() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }
        return cpuTemperature(
            isAppleSilicon: isAppleSilicon,
            brand: brandString(),
            readKey: realReader(connection)
        )
    }

    /// The decision logic: pick the key set from the CPU, read through
    /// `readKey`, filter, and reduce. An empty brand selects no sensor
    /// table on Apple Silicon.
    static func cpuTemperature(
        isAppleSilicon: Bool,
        brand: String,
        readKey: KeyReader
    ) -> Double? {
        if isAppleSilicon {
            guard let keys = siliconKeys(brand: brand) else { return nil }
            return averageTemperature(keys: keys, readKey: readKey)
        }
        return intelTemperature(readKey: readKey)
    }

    /// Whether this binary runs on Apple Silicon. A compile-time check, not
    /// a runtime probe: the app is built per architecture.
    private static var isAppleSilicon: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    /// The CPU brand string ("Apple M2 Max", "Intel Core i7…"), read through
    /// sysctl. Empty when unreadable, which selects no sensor table.
    static func brandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        guard result == 0 else { return "" }
        // The buffer is NUL-terminated; decode only up to it.
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The real reader for an open connection: key info first (the kext
    /// reports each key's size and type), then the bytes.
    private static func realReader(_ connection: io_connect_t) -> KeyReader {
        { key in
            guard let info = keyInfo(of: key, connection: connection) else { return nil }
            guard let bytes = keyBytes(of: key, size: info.size, connection: connection) else { return nil }
            return (info.size, info.type, bytes)
        }
    }

    // MARK: - Intel

    /// SMC keys carrying the CPU temperature, in the order the first
    /// plausible answer wins: proximity (the air around the CPU) first, then
    /// the diode (the core itself), the heatsink, and the rest.
    private static let intelKeys = ["TC0P", "TC0D", "TC0H", "TC0E", "TC0F", "TCAD"]

    private static func intelTemperature(readKey: KeyReader) -> Double? {
        for key in intelKeys {
            guard let value = readKey(key), let temperature = decode(value) else { continue }
            // A reading of exactly 0 or a wild value means the key exists but
            // carries no usable signal on this machine; the next key is tried.
            if temperature > 0, temperature <= maxTemperature {
                return temperature
            }
        }
        return nil
    }

    // MARK: - Apple Silicon

    /// The sensor tables, per chip family — the key lists the community
    /// reads on each family. The GPU sensors each family carries are
    /// included.
    ///
    /// The early M1 has no usable SMC sensor set of its own and gets its own
    /// shorter table. An unknown family — a chip newer than this build —
    /// reads nothing rather than guessing at keys that may mean something
    /// else on it.
    private static let baseM1Keys = ["Tc0a", "Tc0b", "Tc0x", "Tc0z", "Tc7a", "Tc7b",
                                     "Tc7x", "Tc7z", "Tc8a", "Tc8b", "Tc9a", "Tc9b", "Tc9x", "Tc9z"]
    private static let siliconTables: [String: [String]] = [
        "m1": ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P",
               "Tp0X", "Tp0b", "Tg05", "Tg0D", "Tg0L", "Tg0T"],
        "m2": ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D",
               "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tg0f", "Tg0j"],
        "m3": ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B",
               "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
               "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
        "m4": ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D",
               "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        "m5": ["Te04", "Te08", "Te0C", "Te0R", "Tp00", "Tp04", "Tp0C", "Tp0G",
               "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y"]
    ]

    /// The sensor table for a chip brand string ("Apple M2 Max", "Apple M1",
    /// …). The base M1 has its own table; every other family's Pro / Max /
    /// Ultra variants share one.
    private static func siliconKeys(brand: String) -> [String]? {
        let name = brand.lowercased().filter { $0 != " " && $0 != "\n" }
        guard !name.isEmpty else { return nil }
        // Newest family first: a brand string names only one.
        guard let family = ["m5", "m4", "m3", "m2", "m1"].first(where: { name.contains($0) }) else {
            return nil
        }
        let isBaseM1 = family == "m1" && !["pro", "max", "ultra"].contains(where: name.contains)
        return isBaseM1 ? baseM1Keys : siliconTables[family]
    }

    /// The average of every sensor that answers with a plausible value.
    /// Below `minTemperature` a sensor is treated as absent rather than as a
    /// cold reading. Defensive rather than observed: on the machine this was
    /// verified against, absent keys fail at key-info with the kext's error
    /// byte instead of answering near zero — but a sensor that *did* answer
    /// zero would drag the average down silently, and the filter costs
    /// nothing.
    private static func averageTemperature(keys: [String], readKey: KeyReader) -> Double? {
        var sum = 0.0
        var count = 0
        for key in keys {
            guard let value = readKey(key), let temperature = decode(value) else { continue }
            if temperature >= minTemperature, temperature <= maxTemperature {
                sum += temperature
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }

    // MARK: - Value decoding

    /// A reading above this is rejected as a sensor error, not a hot CPU.
    private static let maxTemperature = 110.0
    /// A reading below this on Apple Silicon means an absent sensor.
    private static let minTemperature = 20.0

    /// Decodes a key's value by its data type: the fixed-point "sp" family
    /// (sp78 is the common temperature type), 32-bit float, and the plain
    /// integer types.
    ///
    /// The type fourcc is always four characters, and Apple pads the short
    /// ones with a space — the float type is `flt `, not `flt`. Matching the
    /// exact string silently drops every float reading, which is what the
    /// Apple Silicon sensor tables return (verified on an M2: every
    /// answering key is `flt `).
    static func decode(_ value: KeyValue) -> Double? {
        let type = fourccString(value.type)
        if type.hasPrefix("sp") {
            return decodeFixedPoint(type, bytes: value.bytes)
        }
        if type.hasPrefix("flt"), value.bytes.count >= 4 {
            // Native little-endian IEEE-754 single, as the kext stores it.
            return Double(Float(bitPattern: littleEndianUInt32(value.bytes.prefix(4))))
        }
        switch type {
        case "ui8": return value.bytes.first.map(Double.init)
        case "ui16": return bigEndianUInt(value.bytes.prefix(2)).map(Double.init)
        case "ui32": return bigEndianUInt(value.bytes.prefix(4)).map(Double.init)
        case "si8": return value.bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16": return bigEndianInt(value.bytes.prefix(2)).map(Double.init)
        case "si32": return bigEndianInt(value.bytes.prefix(4)).map(Double.init)
        default: return nil
        }
    }

    /// An "sp" fixed-point value: `spXY` is a signed 16-bit number with `Y`
    /// fractional bits (sp78 → 1/256, sp96 → 1/64, sp5a → 1/1024). `Y` is a
    /// hex digit, so the divisor is 2^Y.
    private static func decodeFixedPoint(_ type: String, bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2, let fractionBits = Int(String(type.last ?? " "), radix: 16),
              fractionBits < 16 else {
            return nil
        }
        let raw = Int16(bitPattern: bigEndianUInt16(bytes.prefix(2)))
        return Double(raw) / Double(1 << fractionBits)
    }

    // MARK: - IOKit plumbing

    /// The kext's selector for the SMC user client method.
    private static let kernelIndexSMC: UInt32 = 2
    /// SMC commands carried in the record's `data8` field.
    private static let commandReadKeyInfo: UInt8 = 9
    private static let commandReadBytes: UInt8 = 5

    /// One key's size and data type.
    private static func keyInfo(
        of key: String,
        connection: io_connect_t
    ) -> (size: UInt32, type: UInt32)? {
        var record = SMCRecord()
        defer { record.deallocate() }
        record.key = fourcc(key)
        record.data8 = commandReadKeyInfo
        guard let reply = record.send(to: connection) else { return nil }
        return (reply.keyInfoSize, reply.keyInfoType)
    }

    /// One key's raw bytes.
    private static func keyBytes(
        of key: String,
        size: UInt32,
        connection: io_connect_t
    ) -> [UInt8]? {
        // The record's tail is 32 bytes; a key claiming more is not a key
        // this reader can carry.
        guard size > 0, size <= 32 else { return nil }
        var record = SMCRecord()
        defer { record.deallocate() }
        record.key = fourcc(key)
        record.keyInfoSize = size
        record.data8 = commandReadBytes
        guard let reply = record.send(to: connection) else { return nil }
        return Array(reply.bytes.prefix(Int(size)))
    }

    /// The kext's parameter record.
    ///
    /// Handled as raw bytes rather than a Swift struct: the 32 inline bytes
    /// at the tail are data, and a Swift Array field would put a heap
    /// pointer there instead.
    private struct SMCRecord {
        /// The kext's commands succeed with a result byte of 0.
        private static let success: UInt8 = 0

        private let buffer: UnsafeMutableRawPointer

        init() {
            buffer = UnsafeMutableRawPointer.allocate(
                byteCount: Offset.size, alignment: 8
            )
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Offset.size)
        }

        func deallocate() {
            buffer.deallocate()
        }

        var key: UInt32 {
            get { buffer.load(fromByteOffset: Offset.key, as: UInt32.self) }
            set { buffer.storeBytes(of: newValue, toByteOffset: Offset.key, as: UInt32.self) }
        }

        var keyInfoSize: UInt32 {
            get { buffer.load(fromByteOffset: Offset.keyInfoSize, as: UInt32.self) }
            set { buffer.storeBytes(of: newValue, toByteOffset: Offset.keyInfoSize, as: UInt32.self) }
        }

        var data8: UInt8 {
            get { buffer.load(fromByteOffset: Offset.data8, as: UInt8.self) }
            set { buffer.storeBytes(of: newValue, toByteOffset: Offset.data8, as: UInt8.self) }
        }

        /// The record's reply, copied out of the reply buffer before it is
        /// released.
        struct Reply {
            let keyInfoSize: UInt32
            let keyInfoType: UInt32
            let bytes: [UInt8]
        }

        /// Sends one call and returns the reply, or nil when the kext
        /// rejects it. A key that does not exist on this machine answers
        /// with the kext's error byte (132 observed), which lands here.
        func send(to connection: io_connect_t) -> Reply? {
            let reply = SMCRecord()
            defer { reply.deallocate() }
            var replySize = size_t(Offset.size)
            let status = IOConnectCallStructMethod(
                connection,
                kernelIndexSMC,
                buffer,
                size_t(Offset.size),
                reply.buffer,
                &replySize
            )
            guard status == KERN_SUCCESS else { return nil }
            // The kext reports how much of the reply it filled; a short
            // write is a malformed answer, and decoding it anyway would
            // read zeros as data.
            guard replySize == size_t(Offset.size) else { return nil }
            // The kext answers 0 on success and an error code in its own
            // byte: the call can return a success status while the answer is
            // a refusal.
            guard reply.buffer.load(fromByteOffset: Offset.result, as: UInt8.self) == SMCRecord.success else {
                return nil
            }
            let tail = UnsafeRawBufferPointer(
                start: reply.buffer.advanced(by: Offset.bytes),
                count: Offset.bytesCount
            )
            return Reply(
                keyInfoSize: reply.buffer.load(fromByteOffset: Offset.keyInfoSize, as: UInt32.self),
                keyInfoType: reply.buffer.load(fromByteOffset: Offset.keyInfoType, as: UInt32.self),
                bytes: Array(tail)
            )
        }

        /// The kext's record layout, byte for byte — the C layout of
        /// AppleSMC.kext's parameter record, cross-checked against a working
        /// read on a macOS 27 Apple Silicon machine.
        ///
        /// These are named constants, NOT offsets derived from a Swift
        /// struct: Swift's struct layout packs away the C struct's tail
        /// padding (a nested `KeyInfoData` occupies 9 bytes where C reserves
        /// 12), so a derived `data8` lands at 39 instead of 42 — inside the
        /// record's padding, where the kext reads a zero command and every
        /// call fails. Deriving the offsets silently broke the reader once
        /// already; the constants are the fix.
        private enum Offset {
            static let key = 0
            static let keyInfoSize = 28
            static let keyInfoType = 32
            static let result = 40
            static let data8 = 42
            static let bytes = 48
            static let bytesCount = 32
            static let size = 80
        }
    }

    // MARK: - Four-character codes

    /// Packs a four-character key ("Tp09") the way the kext expects: the
    /// characters big-endian in one UInt32.
    static func fourcc(_ key: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            code = code << 8 | UInt32(byte)
        }
        return code
    }

    /// Unpacks a data type ("sp78") back to its characters, for the decode
    /// dispatch. Undecodable bytes become an empty string, which matches no
    /// type.
    static func fourccString(_ code: UInt32) -> String {
        var bytes = [UInt8]()
        for shift in [24, 16, 8, 0] {
            let byte = UInt8(truncatingIfNeeded: code >> UInt32(shift))
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Byte-order helpers

/// Big-endian readers for the SMC's wire values. Sizes are clamped to the
/// available bytes: a short read decodes what is there rather than trapping
/// on an out-of-bounds index.

private func bigEndianUInt16(_ bytes: some Sequence<UInt8>) -> UInt16 {
    var value: UInt16 = 0
    for byte in bytes.prefix(2) {
        value = value << 8 | UInt16(byte)
    }
    return value
}

private func littleEndianUInt32(_ bytes: some Sequence<UInt8>) -> UInt32 {
    var value: UInt32 = 0
    for byte in bytes.prefix(4) {
        value = value >> 8 | UInt32(byte) << 24
    }
    return value
}

private func bigEndianUInt(_ bytes: some Sequence<UInt8>) -> UInt? {
    var value: UInt = 0
    var count = 0
    for byte in bytes.prefix(MemoryLayout<UInt>.size) {
        value = value << 8 | UInt(byte)
        count += 1
    }
    return count > 0 ? value : nil
}

private func bigEndianInt(_ bytes: some Sequence<UInt8>) -> Int? {
    var value: UInt = 0
    var count = 0
    for byte in bytes.prefix(MemoryLayout<Int>.size) {
        value = value << 8 | UInt(byte)
        count += 1
    }
    guard count > 0 else { return nil }
    let bits = count * 8
    let signBit = UInt(1) << UInt(bits - 1)
    if value & signBit != 0 {
        return Int(value) - (Int(1) << bits)
    }
    return Int(value)
}
