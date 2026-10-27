import Foundation
import Testing

@testable import Mackit

/// The symbolicator's pure logic and its refusals.
///
/// `atos`'s output format is verified against the real tool, not against a
/// guess — the fixtures below are the shapes it actually prints for the
/// Mackit binary, and its failure path is exercised against the stripped
/// `/usr/bin/atos`. What is covered: which frames belong to our own image
/// (the boundary is what decides whether an address can be resolved at
/// all), how its output maps back onto the frames, and every condition
/// under which the symbolicator refuses rather than produce wrong symbols.
struct SymbolicatorTests {
    private func entry(
        executablePath: String = "/nonexistent/Mackit",
        appVersion: String = "9.9.9",
        build: String = "9",
        imageHeader: UInt64? = 0x1000,
        imageEnd: UInt64? = 0x3000,
        frames: [UInt64] = [0x1000, 0x5000, 0x2000]
    ) -> CrashLogEntry {
        CrashLogEntry(
            id: "crash-1-1-11.txt",
            fileURL: URL(fileURLWithPath: "/tmp/crash-1-1-11.txt"),
            date: Date(timeIntervalSince1970: 1760000000),
            pid: 1,
            isAgent: false,
            appVersion: appVersion,
            build: build,
            osVersion: "Version 15.0.1",
            executablePath: executablePath,
            signal: 11,
            signalName: "SIGSEGV",
            faultAddress: nil,
            frames: frames,
            imageHeader: imageHeader,
            imageEnd: imageEnd,
            exceptionName: nil,
            exceptionReason: nil
        )
    }

    /// The boundary is the whole rule: the header itself is in the image, the
    /// end is not, and a frame below the header belongs to something mapped
    /// before us.
    @Test
    func framesInImageKeepsOnlyTheOwnImageFrames() {
        let frames: [UInt64] = [0x1000, 0x5000, 0xffff, 0x1001, 0x2fff, 0x3000]

        let own = Symbolicator.framesInImage(frames, header: 0x1000, end: 0x3000)

        #expect(own == [0x1000, 0x1001, 0x2fff])
    }

    /// atos prints one line per input address, in order, as
    /// `symbol (in binary) (file:line)`. The fixtures below are the shapes
    /// the real tool produces for the Mackit binary — including the
    /// data-symbol form with a "+ 0" offset instead of a file and line.
    @Test
    func parseOutputMapsEachLineToAFrame() {
        let output = """
        main (in Mackit) (MackitApp.swift:0)
        _swift_FORCE_LOAD_$_swiftos_$_Mackit (in Mackit) + 0

        """

        let parsed = Symbolicator.parseOutput(output)

        #expect(parsed.count == 2)
        #expect(parsed[0] == "main (in Mackit) (MackitApp.swift:0)")
        #expect(parsed[1] == "_swift_FORCE_LOAD_$_swiftos_$_Mackit (in Mackit) + 0")
    }

    /// An address atos cannot resolve comes back as the address itself,
    /// echoed in the form the arguments were passed in: with an
    /// "(in Mackit)" tail inside the image, bare outside it. Neither is a
    /// symbol, and the tail is exactly what makes the naive "contains a
    /// parenthesis, so it resolved" reading wrong.
    @Test
    func parseOutputMarksAddressEchoesAsUnresolved() {
        let output = """
        main (in Mackit) (MackitApp.swift:0)
        0x0000000100000008 (in Mackit)
        0x7fff00000000
        """

        let parsed = Symbolicator.parseOutput(output)

        #expect(parsed.count == 3)
        #expect(parsed[0] == "main (in Mackit) (MackitApp.swift:0)")
        #expect(parsed[1] == nil, "an echo with a tail is still an echo: \(parsed[1] ?? "nil")")
        #expect(parsed[2] == nil)
    }

    /// A record whose range is empty or inverted carries no usable range:
    /// the guard treats it as absent rather than trusting the numbers.
    @Test
    func symbolicateWithAnInvertedImageRangeResolvesNothing() async {
        let result = await Symbolicator.symbolicate(entry(imageHeader: 0x3000, imageEnd: 0x1000))

        #expect(result.unavailableReason == .noImageRange)
        #expect(result.frames.allSatisfy { $0.symbol == nil })
    }

    /// No image range in the record: there is nothing to check the frames
    /// against, so nothing is resolved and the frames stay as they are.
    @Test
    func symbolicateWithoutAnImageRangeResolvesNothing() async {
        let result = await Symbolicator.symbolicate(entry(imageHeader: nil, imageEnd: nil))

        #expect(result.unavailableReason == .noImageRange)
        #expect(result.frames.count == 3)
        #expect(result.frames.allSatisfy { $0.symbol == nil })
    }

    /// Every frame outside our image: symbolication has nothing to say, and
    /// saying so is better than running atos against the wrong binary.
    @Test
    func symbolicateWithoutOwnFramesResolvesNothing() async {
        let result = await Symbolicator.symbolicate(entry(frames: [0x9000, 0xa000]))

        #expect(result.unavailableReason == .noOwnFrames)
        #expect(result.frames.allSatisfy { $0.symbol == nil })
    }

    @Test
    func symbolicateRefusesAMissingBinary() async {
        let result = await Symbolicator.symbolicate(
            entry(executablePath: "/nonexistent/\(UUID().uuidString)/Mackit")
        )

        #expect(result.unavailableReason == .binaryMissing)
        #expect(result.frames.count == 3)
    }

    /// The dangerous case: the path exists but holds a different build — an
    /// update replaced the binary the record was written against. Running
    /// atos on it would produce confident nonsense, so it is refused with
    /// both versions named.
    @Test
    func symbolicateRefusesAReplacedBinary() async {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        let result = await Symbolicator.symbolicate(
            entry(executablePath: Bundle.main.executablePath ?? "/bin/sh")
        )

        #expect(result.unavailableReason == .binaryReplaced(recorded: "9.9.9", current: current))
    }

    /// `atos` itself failing. The binary is real and the versions match —
    /// every refusal above has been ruled out — but `/usr/bin/atos` is a
    /// stripped system binary, and atos exits nonzero on it ("cannot load
    /// symbols"), which is exactly the shape of a wedged or unusable
    /// symbolizer. The frames stay as addresses either way.
    @Test
    func symbolicateReportsATOSItselfFailing() async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

        let result = await Symbolicator.symbolicate(
            entry(executablePath: "/usr/bin/atos", appVersion: version, build: build)
        )

        #expect(result.unavailableReason == .atosFailed)
        #expect(result.frames.count == 3)
        #expect(result.frames.allSatisfy { $0.symbol == nil })
    }
}
