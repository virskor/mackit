import Foundation
import Testing

@testable import Mackit

/// The crash collector's record writer.
///
/// The signal handler itself cannot be fired from a test — the signal would
/// kill the test runner — so what is covered here is the writer the signal
/// handler and the exception handler share. `capture` is called directly,
/// into a temporary directory, and the record is read back through the real
/// parser: the format is the contract between a process that is dying and
/// the app that reads its record later, so the round trip is the test.
///
/// Serialized: `configure` writes process-global state — the context block
/// every later capture reads its directory from — so two tests configuring
/// different directories at once would have one test's record land in the
/// other's directory.
@Suite(.serialized)
struct CrashCollectorTests {
    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-collector-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Frame addresses as the handler's buffer holds them.
    private func framePointers(_ addresses: [UInt64]) -> [UnsafeMutableRawPointer?] {
        addresses.map { UnsafeMutableRawPointer(bitPattern: Int($0)) }
    }

    @Test
    func captureWritesARecordTheStoreParses() throws {
        let directory = tempDirectory("signal")
        defer { try? FileManager.default.removeItem(at: directory) }
        CrashCollector.configure(directory: directory)

        let addresses: [UInt64] = [0x1000, 0x2000, 0x3000]
        let wrote = framePointers(addresses).withUnsafeBufferPointer { buffer in
            CrashCollector.capture(
                signal: SIGSEGV,
                faultAddress: 0xdead,
                frames: buffer.baseAddress,
                frameCount: buffer.count
            )
        }

        #expect(wrote)
        let entries = CrashLogStore.entries(in: directory)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.signal == SIGSEGV)
        #expect(entry.signalName == "SIGSEGV")
        #expect(entry.faultAddress == 0xdead)
        #expect(entry.frames == addresses)
        #expect(entry.isAgent == AppIdentity.currentProcessIsAgent)
        // The context the writer captured from the live process: version,
        // build and the image range the symbolizer needs.
        #expect(!entry.appVersion.isEmpty)
        #expect(entry.imageHeader ?? 0 > 0)
        #expect((entry.imageEnd ?? 0) > (entry.imageHeader ?? 0))
        // The range has to describe the image, not the address space: a
        // real crash once recorded a 4GB span because __PAGEZERO's size
        // inflated it, which made the symbolizer feed system frames to atos
        // and get confident nonsense back. No Mach-O image the app loads is
        // anywhere near a gigabyte, so the span is bounded here.
        #expect((entry.imageEnd ?? 0) - (entry.imageHeader ?? 0) < 1_000_000_000)
        #expect(entry.executablePath == Bundle.main.executablePath)
    }

    @Test
    func captureWritesAnExceptionRecordWithoutASignal() throws {
        let directory = tempDirectory("exception")
        defer { try? FileManager.default.removeItem(at: directory) }
        CrashCollector.configure(directory: directory)

        let wrote = "NSRangeException".withCString { name in
            "index 5 beyond bounds".withCString { reason in
                CrashCollector.capture(
                    signal: 0,
                    faultAddress: 0,
                    frames: nil,
                    frameCount: 0,
                    exceptionName: name,
                    exceptionReason: reason
                )
            }
        }

        #expect(wrote)
        let entry = try #require(CrashLogStore.entries(in: directory).first)
        #expect(entry.isException)
        #expect(entry.signal == 0)
        #expect(entry.exceptionName == "NSRangeException")
        #expect(entry.exceptionReason == "index 5 beyond bounds")
    }

    /// An exception reason is attacker-ish length prose; the record keeps it
    /// bounded so one pathological exception cannot write an unbounded file.
    @Test
    func captureBoundsTheExceptionReason() throws {
        let directory = tempDirectory("bounded")
        defer { try? FileManager.default.removeItem(at: directory) }
        CrashCollector.configure(directory: directory)

        let longReason = String(repeating: "x", count: 2000)
        let wrote = String(repeating: "N", count: 2000).withCString { name in
            longReason.withCString { reason in
                CrashCollector.capture(
                    signal: 0, faultAddress: 0, frames: nil, frameCount: 0,
                    exceptionName: name, exceptionReason: reason
                )
            }
        }

        #expect(wrote)
        let entry = try #require(CrashLogStore.entries(in: directory).first)
        #expect(entry.exceptionName?.count == 256)
        #expect(entry.exceptionReason?.count == 512)
    }

    /// A reason can carry newlines — it is prose, and the exception came
    /// from anywhere. The parser is line-oriented, so a reason line reading
    /// "time=1" would otherwise overwrite the record's own timestamp and
    /// leave the whole file unlistable.
    @Test
    func captureFlattensNewLinesInTheExceptionReason() throws {
        let directory = tempDirectory("newlines")
        defer { try? FileManager.default.removeItem(at: directory) }
        CrashCollector.configure(directory: directory)

        let before = Int64(time(nil))
        let reason = "bad index\ntime=1\nrole=agent"
        let wrote = "NSRangeException".withCString { name in
            reason.withCString { reason in
                CrashCollector.capture(
                    signal: 0, faultAddress: 0, frames: nil, frameCount: 0,
                    exceptionName: name, exceptionReason: reason
                )
            }
        }

        #expect(wrote)
        let entry = try #require(CrashLogStore.entries(in: directory).first)
        #expect(entry.exceptionReason == "bad index time=1 role=agent")
        // The record's own timestamp, not the injected one.
        #expect(abs(entry.date.timeIntervalSince1970 - Double(before)) < 10)
        #expect(entry.isAgent == AppIdentity.currentProcessIsAgent)
    }

    /// An exception with no reason at all: the record still identifies the
    /// exception, and the missing reason reads as nil rather than empty.
    @Test
    func captureWritesAnExceptionRecordWithoutAReason() throws {
        let directory = tempDirectory("no-reason")
        defer { try? FileManager.default.removeItem(at: directory) }
        CrashCollector.configure(directory: directory)

        let wrote = "NSGenericException".withCString { name in
            CrashCollector.capture(
                signal: 0, faultAddress: 0, frames: nil, frameCount: 0,
                exceptionName: name, exceptionReason: nil
            )
        }

        #expect(wrote)
        let entry = try #require(CrashLogStore.entries(in: directory).first)
        #expect(entry.isException)
        #expect(entry.exceptionName == "NSGenericException")
        #expect(entry.exceptionReason == nil)
        #expect(entry.signal == 0)
        #expect(entry.frames.isEmpty)
    }

    /// The file name carries the signal, so two different deaths from one
    /// pid cannot collide, and the epoch keeps the list sortable without
    /// parsing the record.
    @Test
    func recordFileNameCarriesTheDeath() throws {
        let directory = tempDirectory("name")
        defer { try? FileManager.default.removeItem(at: directory) }
        CrashCollector.configure(directory: directory)

        _ = framePointers([0x1]).withUnsafeBufferPointer { buffer in
            CrashCollector.capture(
                signal: SIGABRT, faultAddress: 0, frames: buffer.baseAddress, frameCount: 1
            )
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 1)
        #expect(names.first?.hasPrefix("crash-") == true)
        #expect(names.first?.hasSuffix("-6.txt") == true, "the signal number belongs in the name: \(names.first ?? "")")
    }

    /// Uninstalling before anything was installed must be a no-op, not a
    /// crash: the settings toggle and the launch-time arming both reach it.
    @Test
    func uninstallWithoutInstallIsANoOp() {
        CrashCollector.uninstall()
        #expect(!CrashCollector.isEnabled)
    }

    /// The monitored set is the line between "crashed" and "quit". A control
    /// signal in it would file a deliberate termination as a crash record;
    /// a fatal signal missing from it would lose the record entirely.
    @Test
    func monitoredSignalsCoverCrashesAndExcludeControlSignals() {
        for fatal in [SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGSYS, SIGQUIT] {
            #expect(CrashCollector.monitoredSignals.contains(fatal), "signal \(fatal) is not monitored")
        }
        for control in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] {
            #expect(!CrashCollector.monitoredSignals.contains(control), "signal \(control) is a quit, not a crash")
        }
    }
}
