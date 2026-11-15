import Darwin

/// The sysctl reads shared by the hardware and system information samplers.
///
/// Both helpers go through `sysctlbyname`, a public interface that has
/// existed since well before the macOS 14 floor. A key that is absent on the
/// running machine returns nil rather than an error, which is how callers
/// fall back to "—" without enumerating hardware differences themselves.
enum Sysctl {
    /// Reads a string-type sysctl; returns nil when the key does not exist.
    static func string(_ name: String) -> String? {
        var size = size_t(0)
        // The first pass asks only for the length: if the length cannot be
        // obtained, the buffer size is not guessed.
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // The kernel appends \0 at the end of the value; decode as UTF-8 up
        // to the terminator.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads an integer-type sysctl.
    ///
    /// The buffer is given as 8 bytes: sysctl integer values come in both
    /// 4-byte and 8-byte sizes; too small and the kernel rejects it with
    /// ENOMEM; too large and the kernel fills per the actual size and writes
    /// back the real length, so either way it can be read.
    static func int(_ name: String) -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
