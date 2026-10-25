import Foundation
import Testing

@testable import Mackit

/// The pipe reader's line splitting: what comes back per chunk, and what
/// happens when a chunk boundary falls mid-line — which is the normal case,
/// since a pipe read rarely lands on a newline.
struct HomebrewRunnerTests {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    @Test func aChunkWithWholeLinesCompletesThemAll() {
        var lines = LineBuffer()
        #expect(lines.append(data("==> Upgrading cairo\n==> Upgrading codex\n")) == [
            "==> Upgrading cairo",
            "==> Upgrading codex"
        ])
        #expect(lines.flush() == nil)
    }

    @Test func aLineSplitAcrossChunksIsCarriedToTheNextOne() {
        var lines = LineBuffer()
        #expect(lines.append(data("==> Upgrading co")).isEmpty)
        #expect(lines.append(data("dex\n  0.163.0 -> 0.164")) == ["==> Upgrading codex"])
        #expect(lines.append(data(".0\n")) == ["  0.163.0 -> 0.164.0"])
        #expect(lines.flush() == nil)
    }

    @Test func theTrailingPartialLineFlushesAtTheEndOfTheStream() {
        var lines = LineBuffer()
        #expect(lines.append(data("==> Upgraded 3 outdated packages")).isEmpty)
        #expect(lines.flush() == "==> Upgraded 3 outdated packages")
        #expect(lines.flush() == nil, "flushing twice yields nothing")
    }

    @Test func blankLinesAreDroppedButNewlinesStillSeparate() {
        var lines = LineBuffer()
        #expect(lines.append(data("a\n\nb\n\n\nc\n")) == ["a", "b", "c"])
    }

    @Test func manyLinesInOneChunkAllComeBack() {
        var lines = LineBuffer()
        let payload = (1...500).map { "Removing: /opt/homebrew/Cellar/pkg/1.0/\($0)" }.joined(separator: "\n") + "\n"
        #expect(lines.append(Data(payload.utf8)).count == 500)
        #expect(lines.flush() == nil)
    }

    @Test func aChunkWithoutANewlineYieldsNothing() {
        var lines = LineBuffer()
        #expect(lines.append(data("Warning: taps are not trusted")).isEmpty)
        #expect(lines.flush() == "Warning: taps are not trusted")
    }
}
