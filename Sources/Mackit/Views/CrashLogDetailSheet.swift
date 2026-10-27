import AppKit
import SwiftUI

/// The detail view for one crash record: what the process was, what killed
/// it, and the backtrace — with symbolication on demand.
///
/// A sheet rather than an inline expansion of the settings row: the
/// backtrace is monospaced text a reader scrolls and selects, and a form row
/// is the wrong container for that. Everything still starts from the
/// settings page's crash log section.
struct CrashLogDetailSheet: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let entry: CrashLogEntry

    /// The delete confirmation. A past crash cannot be re-collected, so
    /// deleting its record is confirmed even from inside the sheet.
    @State private var confirmsDeletion = false

    private var model: CrashLogsModel { vm.crashLogs }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            metadata
            if let reason = entry.exceptionReason, !reason.isEmpty {
                exceptionReason(reason)
            }
            Divider()
            backtrace
            Divider()
            actions
        }
        .frame(width: 560, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            L10n.tr("crashLogs.detail.deleteConfirm"),
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("crashLogs.action.delete"), role: .destructive) {
                Task {
                    await model.delete(entry, moveToTrash: vm.moveToTrash)
                    if model.lastError == nil {
                        vm.showToast(.success, L10n.tr("toast.crashLogDeleted"))
                    }
                }
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("crashLogs.detail.title"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: Formatters.dateTime(entry.date))
                    .font(.system(size: 20, weight: .semibold))
            }
            Spacer(minLength: 12)
            Button(L10n.tr("common.done")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow(L10n.tr("crashLogs.detail.process"), entry.processLabel)
            metadataRow(
                L10n.tr("crashLogs.detail.version"),
                entry.build.isEmpty
                    ? entry.appVersion
                    : L10n.fmt("crashLogs.detail.versionValue", entry.appVersion, entry.build)
            )
            metadataRow(L10n.tr("crashLogs.detail.os"), entry.osVersion)
            metadataRow(L10n.tr("crashLogs.detail.pid"), "\(entry.pid)")
            if entry.isException {
                metadataRow(L10n.tr("crashLogs.detail.exception"), entry.exceptionName ?? "")
            } else {
                metadataRow(L10n.tr("crashLogs.detail.signal"), entry.signalName)
                if let faultAddress = entry.faultAddress {
                    metadataRow(
                        L10n.tr("crashLogs.detail.faultAddress"),
                        Formatters.hex(faultAddress)
                    )
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(verbatim: value)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// The exception's own words, when there are any: the reason is the one
    /// part of an exception record a reader wants verbatim.
    private func exceptionReason(_ reason: String) -> some View {
        Text(verbatim: reason)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
    }

    private var backtrace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: L10n.tr("crashLogs.detail.backtrace"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let reason = model.symbolications[entry.id]?.unavailableReason {
                    Text(verbatim: unavailableText(reason))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                        frameRow(index: index, frame: frame)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func frameRow(index: Int, frame: SymbolizedFrame) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            if let symbol = frame.symbol {
                Text(verbatim: symbol)
                    .font(.system(size: 11, design: .monospaced))
                Text(verbatim: Formatters.hex(frame.address))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Text(verbatim: Formatters.hex(frame.address))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            symbolicationControl
            Spacer(minLength: 8)
            Button(L10n.tr("crashLogs.action.reveal")) {
                model.revealInFinder(entry)
            }
            Button(L10n.tr("crashLogs.action.export")) {
                export()
            }
            Button(L10n.tr("crashLogs.action.delete"), role: .destructive) {
                confirmsDeletion = true
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    /// The symbolicate button, or its outcome. A cached result replaces the
    /// button — symbolizing is a subprocess for an answer that cannot
    /// change — and a failure says so instead of pretending otherwise.
    @ViewBuilder
    private var symbolicationControl: some View {
        if let result = model.symbolications[entry.id] {
            if result.unavailableReason == nil {
                Label(
                    L10n.tr("crashLogs.action.symbolicated"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else {
                Label(
                    L10n.tr("crashLogs.action.symbolicateFailed"),
                    systemImage: "xmark.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        } else if model.isSymbolicating {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: L10n.tr("crashLogs.action.symbolicating"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Button(L10n.tr("crashLogs.action.symbolicate")) {
                Task { await model.symbolicate(entry) }
            }
            .disabled(entry.frames.isEmpty)
        }
    }

    // MARK: - Helpers

    /// The frames to show: the symbolicated set once there is one, the raw
    /// addresses until then.
    private var frames: [SymbolizedFrame] {
        model.symbolications[entry.id]?.frames
            ?? entry.frames.map { SymbolizedFrame(address: $0, symbol: nil) }
    }

    private func unavailableText(_ reason: SymbolicationUnavailable) -> String {
        switch reason {
        case .noImageRange:
            return L10n.tr("crashLogs.symbolize.noImageRange")
        case .noOwnFrames:
            return L10n.tr("crashLogs.symbolize.noOwnFrames")
        case .binaryMissing:
            return L10n.tr("crashLogs.symbolize.binaryMissing")
        case .binaryReplaced(let recorded, let current):
            return L10n.fmt("crashLogs.symbolize.binaryReplaced", recorded, current)
        case .atosFailed:
            return L10n.tr("crashLogs.symbolize.atosFailed")
        }
    }

    /// Saves a copy of the record through the system save panel. The panel
    /// is the view's job; the model's `export` is the file operation.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.id
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.export(entry, to: url)
            vm.showToast(.success, L10n.tr("toast.crashLogExported"))
        } catch {
            vm.showToast(.error, error.localizedDescription)
        }
    }
}
