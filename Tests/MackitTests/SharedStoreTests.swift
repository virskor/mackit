import Foundation
import Testing

@testable import Mackit

/// Write safety of shared storage and the expiry of pending commands.
@MainActor
struct SharedStoreTests {
    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-store-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Atomic writes

    /// Happy path: content lands on the destination via a temporary file, and no temporary file remains.
    @Test func successfulWriteReplacesDestinationAndCleansUp() throws {
        let dir = tempDirectory("atomic-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("shared-settings.plist")
        let temporary = dir.appendingPathComponent("shared-settings.plist.tmp")
        let payload = Data("payload".utf8)

        try SharedStore.writeAtomically(payload, to: destination, via: temporary)

        #expect(try Data(contentsOf: destination) == payload)
        // Only the destination file itself remains in the directory: the temporary file was consumed by replaceItemAt
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() == ["shared-settings.plist"])
    }

    /// When the write fails (the destination is not writable), the temporary file already on disk must be cleaned up.
    ///
    /// Regression: the former implementation cleaned up "settingsURL/tmp" in the
    /// catch — a path hidden inside a file, which never exists; the real
    /// temporary file therefore leaked one into ~/Library/Application Support on
    /// every failed write, and was never cleaned up.
    ///
    /// The failure happens at the replacement step: the parent of the destination
    /// path is a regular file (the directory is occupied), the temporary file
    /// has already been written successfully, and only then does replaceItemAt throw.
    @Test func failedWriteLeavesNoTemporaryFileBehind() throws {
        let dir = tempDirectory("atomic-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker")
        try Data("occupy".utf8).write(to: blocker)
        let destination = blocker.appendingPathComponent("shared-settings.plist")
        let temporary = dir.appendingPathComponent("shared-settings.plist.tmp")

        #expect(throws: (any Error).self) {
            try SharedStore.writeAtomically(Data("x".utf8), to: destination, via: temporary)
        }

        #expect(!FileManager.default.fileExists(atPath: temporary.path), "写失败后临时文件残留在目录里")
        // Only the blocker file itself remains in the directory
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() == ["blocker"])
    }

    // MARK: - Pending commands

    private func writeCommand(_ command: AppCommand, to url: URL) {
        try? command.rawValue.write(to: url, atomically: true, encoding: .utf8)
    }

    private func backdate(_ url: URL, by seconds: TimeInterval) {
        let date = Date().addingTimeInterval(-seconds)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func freshPendingCommandIsTakenAndRemoved() {
        let dir = tempDirectory("pending-fresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pending-command.txt")
        writeCommand(.hardware, to: file)

        #expect(PendingCommandStore.take(fileURL: file) == .hardware)
        #expect(!FileManager.default.fileExists(atPath: file.path), "读即删")
    }

    /// After the command is persisted, the main app may fail to come up in time
    /// (launch failure, or killed right after starting); the command must not
    /// wait until the user opens the app themselves — the app would jump
    /// inexplicably to the hardware page.
    @Test func stalePendingCommandIsDiscarded() {
        let dir = tempDirectory("pending-stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pending-command.txt")
        writeCommand(.clean, to: file)
        backdate(file, by: PendingCommandStore.maxAge + 60)

        #expect(PendingCommandStore.take(fileURL: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path), "过期命令也要清掉，不能留着反复解析")
    }

    @Test func unknownPendingCommandIsDiscardedAndRemoved() {
        let dir = tempDirectory("pending-garbage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pending-command.txt")
        try? "not-a-command".write(to: file, atomically: true, encoding: .utf8)

        #expect(PendingCommandStore.take(fileURL: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingPendingCommandReturnsNil() {
        let dir = tempDirectory("pending-missing")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PendingCommandStore.take(fileURL: dir.appendingPathComponent("nope.txt")) == nil)
    }
}
