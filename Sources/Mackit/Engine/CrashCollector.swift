import Darwin
import Foundation

/// Self-collected crash logs: when either process dies on a fatal signal or
/// an uncaught Objective-C exception, write one plain-text record into
/// Application Support and then let the process die as it would have anyway.
///
/// macOS already writes its own report into DiagnosticReports, but that
/// report exists only while ReportCrash is allowed to run and survives only
/// until the directory is cleared — which Mackit's own crash-reporter cleanup
/// rule offers to do. This is the app's own record instead: always written
/// when the setting is on, attributed to the process and build that died,
/// and collected under the same Application Support folder as the settings.
/// The system report still lands; this is in addition to it, never instead
/// of it.
///
/// The signal handler is the delicate part, and its constraints are the
/// reason the writer below looks the way it does:
///
///   - Only async-signal-safe calls: `open`, `write`, `close`, `backtrace`,
///     `raise`, `signal`, `time`, `getpid`, `strlen`, `strnlen`. No `malloc`
///     (the process may have died inside it, holding its lock), no
///     Objective-C messaging, no Swift runtime entry points that could
///     allocate, retain or trap.
///   - The numbers are formatted by hand rather than through `snprintf`:
///     Swift cannot call C variadic functions at all, and the `withVaList`
///     bridge around `vsnprintf` boxes its arguments — an allocation, which
///     is exactly what a signal handler must not do.
///   - No Swift collections are passed by value here — an array copy is an
///     allocation. The frame buffer and the static context are preallocated
///     storage that the handler only reads from and writes into by index.
///   - No logging from the handler: `os_log` is not async-signal-safe
///     either. Lifecycle is logged from `install` / `uninstall` instead.
///
/// Everything the handler writes that is not a raw number is captured at
/// `configure` time — in a normal context, from `Bundle.main` and the dyld
/// image table — into one raw C block. The handler's job is then reduced to
/// formatting numbers and moving bytes.
///
/// The one crash class this cannot promise: a stack overflow kills the
/// process on the guard page, and the handler needs stack to run. An
/// alternate signal stack would cover it, but `sigaltstack` is per-thread
/// and the crash can land on any of the walk's worker threads, so the
/// guarantee could not be kept honestly. That crash still produces the
/// system's own report — which is the designed fallback for every case
/// this misses.
enum CrashCollector {
    /// How many frames a record keeps. The top frames of a signal backtrace
    /// are the handler and the signal trampoline; 64 leaves the crashing
    /// function and its callers visible while keeping the record bounded.
    static let maxFrames = 64

    /// The fatal signals that carry a crash rather than a request.
    ///
    /// `SIGILL` and `SIGTRAP` are where Swift's own runtime errors land —
    /// force-unwrapping nil, a failed precondition, `fatalError` — so they
    /// are the most valuable ones here. `SIGABRT` covers the Swift runtime's
    /// aborts and uncaught Objective-C exceptions. `SIGPIPE`, `SIGTERM`,
    /// `SIGINT` and `SIGHUP` are deliberately absent: they are control
    /// signals, and a process ending on them did not crash.
    static let monitoredSignals: [Int32] = [SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGSYS, SIGQUIT]

    /// Signals whose `siginfo` carries a meaningful fault address. For the
    /// others `si_addr` is either zero or unrelated memory, and writing it
    /// would read as evidence.
    private static let addressBearingSignals: Set<Int32> = [SIGILL, SIGBUS, SIGFPE, SIGSEGV]

    /// An uncaught Objective-C exception aborts the process, which also runs
    /// the `SIGABRT` handler: without this window one exception would leave
    /// two records, one of them a bare abort with no exception name. The
    /// exception handler records the time it wrote, and the abort that
    /// follows it within the window writes nothing.
    private static let exceptionDedupeWindow: Int64 = 2

    // MARK: - Static context

    /// Fixed offsets of the context strings inside the raw block. One block
    /// rather than six Swift arrays: the handler must not touch storage that
    /// could allocate, retain or bounds-check into a trap.
    private enum Offset {
        static let directory = 0
        static let executable = 1024
        static let version = 2048
        static let build = 2112
        static let os = 2176
        static let role = 2304
        static let total = 2336
    }

    /// The context block, allocated once by `configure`. `nil` means no
    /// record can be written, and every capture fails quietly.
    ///
    /// `nonisolated(unsafe)`: the pointer is only ever *replaced* on the main
    /// actor (in `configure`) and only ever *read* from a signal handler,
    /// which is not an actor context at all — there is no isolation to give
    /// it that would mean anything there.
    nonisolated(unsafe) private static var contextBlock: UnsafeMutableRawPointer?

    /// The main executable's image range in this process: the mach header's
    /// runtime address and the end of its last segment. Captured by
    /// `configure` from the dyld image table. A frame inside the range can
    /// be symbolized against our own binary; outside it the frame belongs to
    /// a system image the record says nothing about (see `Symbolicator`).
    nonisolated(unsafe) private static var imageHeader: UInt64 = 0
    nonisolated(unsafe) private static var imageEnd: UInt64 = 0

    /// The frame buffer `backtrace` fills. Preallocated for the same reason
    /// as the context block: the handler must not allocate.
    nonisolated(unsafe) private static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: maxFrames)

    /// When the uncaught-exception handler last wrote, as epoch seconds.
    nonisolated(unsafe) private static var lastExceptionEpoch: Int64 = 0

    /// Whether the handlers are currently armed.
    nonisolated(unsafe) private(set) static var isEnabled = false

    // MARK: - Enabling

    /// Reads the shared preference. Default on: a diagnostic utility that
    /// loses its own crash logs to a setting the user never touched is worse
    /// than one that writes a small file the user can switch off.
    @MainActor
    static var preferenceEnabled: Bool {
        SharedStore.loadSettings()["collectCrashLogs"] as? Bool ?? true
    }

    /// Arms or disarms collection according to the shared preference.
    @MainActor
    static func applyStoredPreference() {
        setEnabled(preferenceEnabled)
    }

    /// Arms collection (installing the handlers) or disarms it (restoring
    /// the default dispositions). Disarming never touches records already
    /// written: turning collection off stops future writes, it is not a
    /// delete.
    static func setEnabled(_ enabled: Bool) {
        if enabled {
            configure(directory: AppDirectories.crashLogs)
            install()
        } else {
            uninstall()
        }
    }

    /// Captures the static context and makes sure the records directory
    /// exists.
    ///
    /// Separate from `install` on purpose: tests (and the writer they drive)
    /// need the context without a process-wide signal-handler side effect,
    /// and the directory has to exist before any handler could run.
    static func configure(directory: URL) {
        if contextBlock == nil {
            contextBlock = UnsafeMutableRawPointer.allocate(
                byteCount: Offset.total, alignment: 16
            )
        }
        guard let block = contextBlock else {
            MackitLog.ui.error("crash collection context could not be allocated")
            return
        }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let info = Bundle.main.infoDictionary ?? [:]
        store(directory.path, at: Offset.directory, capacity: 1024, in: block)
        store(
            Bundle.main.executablePath ?? "",
            at: Offset.executable, capacity: 1024, in: block
        )
        store(
            info["CFBundleShortVersionString"] as? String ?? "0",
            at: Offset.version, capacity: 64, in: block
        )
        store(
            info["CFBundleVersion"] as? String ?? "0",
            at: Offset.build, capacity: 64, in: block
        )
        store(
            ProcessInfo.processInfo.operatingSystemVersionString,
            at: Offset.os, capacity: 128, in: block
        )
        store(
            AppIdentity.currentProcessIsAgent ? "agent" : "app",
            at: Offset.role, capacity: 32, in: block
        )
        captureImageRange()
    }

    /// Installs the handlers. Idempotent: a second call is a no-op, so the
    /// launch-time arming and a later settings change cannot stack handlers.
    static func install() {
        guard !isEnabled else { return }
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = crashSignalHandler
        action.sa_flags = Int32(SA_SIGINFO)
        sigemptyset(&action.sa_mask)
        for monitoredSignal in monitoredSignals {
            sigaction(monitoredSignal, &action, nil)
        }
        NSSetUncaughtExceptionHandler(crashExceptionHandler)
        isEnabled = true
        MackitLog.ui.info(
            "crash collection armed (\(AppIdentity.currentProcessIsAgent ? "agent" : "app", privacy: .public))"
        )
    }

    /// Restores the default disposition for every monitored signal and
    /// removes the uncaught-exception handler. Deliberately does not chain
    /// to whatever handler was installed before: a foreign handler called
    /// from inside our own could deadlock, and nothing in this app or its
    /// dependencies installs one.
    static func uninstall() {
        guard isEnabled else { return }
        for monitoredSignal in monitoredSignals {
            signal(monitoredSignal, SIG_DFL)
        }
        NSSetUncaughtExceptionHandler(nil)
        isEnabled = false
        MackitLog.ui.info("crash collection disarmed")
    }

    // MARK: - Writing

    /// Writes one record and reports whether it landed.
    ///
    /// The one writer both handlers share, so the format cannot drift
    /// between the signal and the exception path. `frames` is a pointer plus
    /// a count rather than an array: the signal handler owns a preallocated
    /// buffer, and an array parameter would copy it — an allocation, which
    /// is exactly what a signal handler must not do.
    ///
    /// Returns false rather than throwing when the context is missing or the
    /// file cannot be opened: a crash handler that fails must still let the
    /// process die, and there is nobody left to report the failure to.
    static func capture(
        signal: Int32,
        faultAddress: UInt64,
        frames: UnsafePointer<UnsafeMutableRawPointer?>?,
        frameCount: Int,
        exceptionName: UnsafePointer<CChar>? = nil,
        exceptionReason: UnsafePointer<CChar>? = nil
    ) -> Bool {
        guard let block = contextBlock else { return false }
        let now = Int64(time(nil))
        var path = [CChar](repeating: 0, count: 1200)
        let pathLength = path.withUnsafeMutableBufferPointer { buffer -> Int in
            var index = 0
            appendCString(
                block.advanced(by: Offset.directory).assumingMemoryBound(to: CChar.self),
                to: buffer, at: &index
            )
            appendLiteral("/crash-", to: buffer, at: &index)
            appendDecimal(now, to: buffer, at: &index)
            appendLiteral("-", to: buffer, at: &index)
            appendDecimal(Int64(getpid()), to: buffer, at: &index)
            appendLiteral("-", to: buffer, at: &index)
            appendDecimal(Int64(signal), to: buffer, at: &index)
            appendLiteral(".txt", to: buffer, at: &index)
            return index
        }
        guard pathLength > 0, pathLength < path.count else { return false }
        // O_NOFOLLOW: the records directory is user-writable, and a planted
        // symlink at the record's name would otherwise have the handler
        // truncate and write through it. A crash's file name is not
        // predictable enough to make that a practical attack, but the flag
        // costs nothing and the handler is the one place the app writes
        // with no chance to check first.
        let fd = open(&path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode_t(0o644))
        guard fd >= 0 else { return false }
        defer { close(fd) }

        writeLiteral(fd, "mackit-crash-log v1\n")
        writeLiteral(fd, "time=")
        writeDecimal(fd, now)
        writeLiteral(fd, "\n")
        writeLiteral(fd, "pid=")
        writeDecimal(fd, Int64(getpid()))
        writeLiteral(fd, "\n")
        writeContextString(fd, "role=", Offset.role, block)
        writeContextString(fd, "version=", Offset.version, block)
        writeContextString(fd, "build=", Offset.build, block)
        writeContextString(fd, "os=", Offset.os, block)
        writeContextString(fd, "executable=", Offset.executable, block)
        writeLiteral(fd, "image-header=")
        writeHex(fd, imageHeader)
        writeLiteral(fd, "\n")
        writeLiteral(fd, "image-end=")
        writeHex(fd, imageEnd)
        writeLiteral(fd, "\n")

        if let exceptionName {
            // An exception record has no signal: the abort that follows it
            // is a consequence, not the cause.
            writeLiteral(fd, "exception=")
            writeBounded(fd, exceptionName, 256)
            writeLiteral(fd, "\n")
            if let exceptionReason {
                writeLiteral(fd, "exception-reason=")
                writeBounded(fd, exceptionReason, 512)
                writeLiteral(fd, "\n")
            }
        } else {
            writeLiteral(fd, "signal=")
            writeDecimal(fd, Int64(signal))
            writeLiteral(fd, "\n")
            writeLiteral(fd, "signal-name=")
            writeSignalName(fd, signal)
            writeLiteral(fd, "\n")
            if addressBearingSignals.contains(signal) {
                writeLiteral(fd, "fault-address=")
                writeHex(fd, faultAddress)
                writeLiteral(fd, "\n")
            }
        }

        if let frames {
            for index in 0..<frameCount {
                guard let frame = frames[index] else { continue }
                writeLiteral(fd, "frame=")
                writeHex(fd, UInt64(UInt(bitPattern: frame)))
                writeLiteral(fd, "\n")
            }
        }
        return true
    }

    // MARK: - Signal handling

    /// The fatal-signal path: gather what only this moment knows (the
    /// backtrace, the fault address), write the record, then die.
    ///
    /// Not private: the C handler at the bottom of this file is the only
    /// caller, and it lives outside this type.
    static func handleSignal(_ signal: Int32, _ info: UnsafeMutablePointer<siginfo_t>?) {
        if signal == SIGABRT, Int64(time(nil)) - lastExceptionEpoch < exceptionDedupeWindow {
            reRaise(signal)
            return
        }
        let frameCount = backtrace(&frames, Int32(maxFrames))
        let faultAddress = info.map {
            UInt64(UInt(bitPattern: $0.pointee.si_addr))
        } ?? 0
        _ = capture(
            signal: signal,
            faultAddress: faultAddress,
            frames: &frames,
            frameCount: Int(frameCount)
        )
        reRaise(signal)
    }

    /// Ends the process the way the signal asked.
    ///
    /// Restoring the default disposition and re-raising, rather than
    /// returning or calling `_exit`: a handler that returns would leave the
    /// process running in an undefined state, and one that exits directly
    /// would swallow the system's own crash report. The signal is blocked
    /// while its own handler runs, so the raised copy stays pending and is
    /// delivered with the default disposition the moment the handler
    /// returns — the death is exactly the one that would have happened
    /// without any handler at all.
    private static func reRaise(_ signal: Int32) {
        // Qualified with the module: the parameter shadows the libc
        // function's name inside this scope.
        Darwin.signal(signal, SIG_DFL)
        raise(signal)
    }

    /// The uncaught-exception path. Unlike the signal handler this runs in
    /// an ordinary thread context mid-exception-propagation, so Foundation
    /// calls are acceptable — but the record still goes through the same
    /// bounded C writer, and the strings are still copied into fixed
    /// buffers: an exception reason can be a whole paragraph.
    ///
    /// Not private, for the same reason as `handleSignal`.
    static func handleException(_ exception: NSException) {
        lastExceptionEpoch = Int64(time(nil))
        var localFrames = [UnsafeMutableRawPointer?](repeating: nil, count: maxFrames)
        let frameCount = backtrace(&localFrames, Int32(maxFrames))
        exception.name.rawValue.withCString { name in
            (exception.reason ?? "").withCString { reason in
                _ = capture(
                    signal: 0,
                    faultAddress: 0,
                    frames: &localFrames,
                    frameCount: Int(frameCount),
                    exceptionName: name,
                    exceptionReason: reason
                )
            }
        }
    }

    // MARK: - Raw writing helpers

    /// Writes a literal's bytes. A string literal is static storage, so this
    /// is a `write` over constant memory.
    private static func writeLiteral(_ fd: Int32, _ text: StaticString) {
        _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
    }

    /// Writes one context string as `key=value\n`, reading it straight out
    /// of the raw block.
    private static func writeContextString(
        _ fd: Int32, _ key: StaticString, _ offset: Int, _ block: UnsafeMutableRawPointer
    ) {
        writeLiteral(fd, key)
        let value = block.advanced(by: offset).assumingMemoryBound(to: CChar.self)
        _ = write(fd, value, strlen(value))
        writeLiteral(fd, "\n")
    }

    /// Writes a C string truncated to `limit` bytes, with newlines flattened
    /// to spaces.
    ///
    /// The exception path passes attacker-ish length reasons through here,
    /// and the length is not the only hazard: the parser is line-oriented,
    /// so a reason carrying "time=1" on its own line would overwrite the
    /// record's own timestamp and leave the whole file unlistable.
    /// Flattening keeps the record parseable whatever the exception said.
    ///
    /// The buffer is a fixed size rather than `limit`-sized: a
    /// runtime-sized Swift array is a heap allocation, and this helper
    /// shares the writer's no-allocation discipline.
    private static func writeBounded(_ fd: Int32, _ text: UnsafePointer<CChar>, _ limit: Int) {
        let bound = min(limit, 512)
        var buffer = [CChar](repeating: 0, count: 513)
        let length = buffer.withUnsafeMutableBufferPointer { buffer -> Int in
            var index = 0
            var position = 0
            while position < bound, text[position] != 0 {
                var byte = text[position]
                if byte == 10 || byte == 13 { byte = 32 } // '\n' / '\r'
                appendByte(byte, to: buffer, at: &index)
                position += 1
            }
            return index
        }
        _ = write(fd, &buffer, length)
    }

    /// Writes "0x" followed by the value's hex digits, lower case, no
    /// leading zeros.
    private static func writeHex(_ fd: Int32, _ value: UInt64) {
        var buffer = [CChar](repeating: 0, count: 34)
        let length = buffer.withUnsafeMutableBufferPointer { buffer -> Int in
            var index = 0
            appendByte(48, to: buffer, at: &index) // '0'
            appendByte(120, to: buffer, at: &index) // 'x'
            appendHex(value, to: buffer, at: &index)
            return index
        }
        _ = write(fd, &buffer, length)
    }

    /// Writes the decimal spelling of `value`, with a leading minus when it
    /// is negative.
    private static func writeDecimal(_ fd: Int32, _ value: Int64) {
        var buffer = [CChar](repeating: 0, count: 32)
        let length = buffer.withUnsafeMutableBufferPointer { buffer -> Int in
            var index = 0
            appendDecimal(value, to: buffer, at: &index)
            return index
        }
        _ = write(fd, &buffer, length)
    }

    // MARK: - Bounded appending
    //
    // The record's numbers are formatted by hand rather than through
    // `snprintf`: Swift cannot call C variadic functions at all, and the
    // `withVaList` bridge around `vsnprintf` boxes its arguments — an
    // allocation, which is exactly what a signal handler must not do. Every
    // helper below writes into a caller-owned buffer and allocates nothing.

    /// Appends one byte, keeping the buffer's terminating zero intact.
    private static func appendByte(
        _ byte: CChar, to buffer: UnsafeMutableBufferPointer<CChar>, at index: inout Int
    ) {
        guard index < buffer.count - 1 else { return }
        buffer[index] = byte
        index += 1
    }

    /// Appends a C string, bounded by the buffer.
    private static func appendCString(
        _ bytes: UnsafePointer<CChar>, to buffer: UnsafeMutableBufferPointer<CChar>, at index: inout Int
    ) {
        var position = 0
        while bytes[position] != 0 {
            appendByte(bytes[position], to: buffer, at: &index)
            position += 1
        }
    }

    /// Appends a literal's bytes. A literal is static storage, so this reads
    /// constant memory.
    private static func appendLiteral(
        _ text: StaticString, to buffer: UnsafeMutableBufferPointer<CChar>, at index: inout Int
    ) {
        let bytes = text.utf8Start
        for position in 0..<text.utf8CodeUnitCount {
            appendByte(CChar(bitPattern: bytes[position]), to: buffer, at: &index)
        }
    }

    /// Appends the decimal spelling of `value`. The digits are produced
    /// least-significant first and reversed in place.
    private static func appendDecimal(
        _ value: Int64, to buffer: UnsafeMutableBufferPointer<CChar>, at index: inout Int
    ) {
        let negative = value < 0
        var magnitude = negative ? ~UInt64(bitPattern: value) &+ 1 : UInt64(value)
        if negative {
            appendByte(45, to: buffer, at: &index) // '-'
        }
        let firstDigit = index
        repeat {
            appendByte(CChar(48 + Int(magnitude % 10)), to: buffer, at: &index)
            magnitude /= 10
        } while magnitude > 0
        reverse(buffer, from: firstDigit, to: index - 1)
    }

    /// Appends the hex digits of `value`, lower case, no leading zeros.
    private static func appendHex(
        _ value: UInt64, to buffer: UnsafeMutableBufferPointer<CChar>, at index: inout Int
    ) {
        var magnitude = value
        let firstDigit = index
        repeat {
            let digit = magnitude & 0xf
            appendByte(CChar(digit < 10 ? 48 + Int(digit) : 87 + Int(digit)), to: buffer, at: &index)
            magnitude >>= 4
        } while magnitude > 0
        reverse(buffer, from: firstDigit, to: index - 1)
    }

    /// Reverses `buffer[from...to]` in place.
    private static func reverse(
        _ buffer: UnsafeMutableBufferPointer<CChar>, from: Int, to: Int
    ) {
        var low = from
        var high = to
        while low < high {
            let swap = buffer[low]
            buffer[low] = buffer[high]
            buffer[high] = swap
            low += 1
            high -= 1
        }
    }

    private static func writeSignalName(_ fd: Int32, _ signal: Int32) {
        switch signal {
        case SIGILL: writeLiteral(fd, "SIGILL")
        case SIGTRAP: writeLiteral(fd, "SIGTRAP")
        case SIGABRT: writeLiteral(fd, "SIGABRT")
        case SIGBUS: writeLiteral(fd, "SIGBUS")
        case SIGFPE: writeLiteral(fd, "SIGFPE")
        case SIGSEGV: writeLiteral(fd, "SIGSEGV")
        case SIGSYS: writeLiteral(fd, "SIGSYS")
        case SIGQUIT: writeLiteral(fd, "SIGQUIT")
        default:
            writeLiteral(fd, "SIG")
            writeDecimal(fd, Int64(signal))
        }
    }

    // MARK: - Context capture

    /// Copies `value` into the raw block as a C string, truncated to the
    /// slot's capacity.
    private static func store(
        _ value: String, at offset: Int, capacity: Int, in block: UnsafeMutableRawPointer
    ) {
        let destination = block.advanced(by: offset).assumingMemoryBound(to: CChar.self)
        let bytes = Array(value.utf8.prefix(capacity - 1))
        for (index, byte) in bytes.enumerated() {
            destination[index] = CChar(bitPattern: byte)
        }
        destination[bytes.count] = 0
    }

    /// Records the main executable's runtime image range.
    ///
    /// The load address is the mach header's own address — what `atos -l`
    /// wants — and the extent comes from walking the segment commands, which
    /// is a plain read of memory the kernel already mapped. All of it runs
    /// here, in a normal context; the handler only reads the two numbers.
    ///
    /// The extent is rebased onto the lowest file-backed segment's vmaddr
    /// before it is added to the header address: a PIE image's vmaddrs start
    /// at a large base (0x100000000 on arm64), so adding the raw extent to
    /// the runtime header would overshoot the image by that base — verified
    /// against a real crash, whose range then swallowed the shared cache's
    /// frames. `__PAGEZERO` — the 4GB placeholder the linker puts first —
    /// carries no file content and is skipped: its size would inflate the
    /// extent past the entire address space.
    private static func captureImageRange() {
        guard let header = _dyld_get_image_header(0) else { return }
        let base = UInt64(UInt(bitPattern: header))
        let commands = UnsafeRawPointer(header).advanced(
            by: MemoryLayout<mach_header_64>.size
        )
        var vmaddrBase: UInt64?
        var extent: UInt64 = 0
        var offset = 0
        for _ in 0..<header.pointee.ncmds {
            let command = commands.advanced(by: offset).assumingMemoryBound(to: load_command.self)
            guard command.pointee.cmdsize > 0 else { break }
            if command.pointee.cmd == LC_SEGMENT_64 {
                let segment = commands.advanced(by: offset).assumingMemoryBound(
                    to: segment_command_64.self
                )
                // Not `continue`: the offset advance at the end of the loop
                // body has to run for every command, and skipping it would
                // re-read this one forever.
                if segment.pointee.filesize > 0 {
                    let vmaddr = UInt64(segment.pointee.vmaddr)
                    vmaddrBase = min(vmaddrBase ?? vmaddr, vmaddr)
                    extent = max(extent, vmaddr + UInt64(segment.pointee.vmsize))
                }
            }
            offset += Int(command.pointee.cmdsize)
        }
        guard let vmaddrBase, extent > vmaddrBase else { return }
        imageHeader = base
        imageEnd = base + (extent - vmaddrBase)
    }
}

/// The C signal handler. A global function rather than a closure because it
/// is handed to `sigaction` as a C function pointer.
private func crashSignalHandler(
    _ signal: Int32,
    _ info: UnsafeMutablePointer<siginfo_t>?,
    _ context: UnsafeMutableRawPointer?
) {
    CrashCollector.handleSignal(signal, info)
}

/// The uncaught-exception handler, installed through
/// `NSSetUncaughtExceptionHandler`.
private func crashExceptionHandler(_ exception: NSException) {
    CrashCollector.handleException(exception)
}
