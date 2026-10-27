import SwiftUI
import AppKit

/// Settings page: embedded in the main window's detail area (entered from the
/// bottom of the sidebar), not a separate window.
///
/// The layout follows the standard style of Mac preferences: a row of segmented
/// switching at the top, and a centered single column of form below. The form is
/// limited to 560 wide: after the detail area widens with the window, a fully
/// stretched Form pushes switches to the far end and leaves a large blank on the
/// right; with a width-limited centered column, the row spacing matches System
/// Settings and the window won't look scattered however wide it gets.
///
/// The form's built-in gray background is hidden entirely (scrollContentBackground),
/// letting the white rounded card below show through: the settings page thus shares
/// one card with the main content area, rather than a whole swath of gray running
/// to the card's edge. Back navigation is delegated to the sidebar — clicking any
/// category row returns to the cleanable items, so there is only segmented
/// switching here, no back button.
struct SettingsView: View {
    @Environment(AppViewModel.self) private var vm
    /// The current segment. Entering the settings page always returns to "General".
    @State private var tab: SettingsTab = .general
    @State private var newRoot: String = ""
    /// Language selection. Writing changes AppleLanguages immediately, taking
    /// effect after restart (see AppLanguage).
    @State private var language: AppLanguage = AppLanguage.stored()
    /// The language the process was using when the settings page was entered. The
    /// restart prompt is only shown when it differs from language: no need to make
    /// the user restart for nothing when they pick back the same language.
    @State private var runningLanguage: AppLanguage = .running
    /// The auto-update controller (singleton). When no update source is
    /// configured, the entire update section is not rendered.
    @StateObject private var updates = UpdateController.shared
    /// Whether the "delete all crash logs" confirmation is up.
    @State private var confirmsDeleteAllCrashLogs = false

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                form
                    .frame(maxWidth: formColumnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            }
        }
        .onAppear { tab = .general }
        // The crash log list is read on entry: a record may have been
        // written since the last visit — by a crash, or by the other
        // process — and the section shows what is on disk now.
        .task { vm.crashLogs.reload() }
        .sheet(item: Binding(
            get: { vm.crashLogs.selectedEntry },
            set: { vm.crashLogs.select($0) }
        )) { entry in
            CrashLogDetailSheet(entry: entry)
                .environment(vm)
        }
        .onChange(of: vm.autoSelectRisk) { _, _ in vm.saveSettings() }
        .onChange(of: vm.moveToTrash) { _, _ in vm.saveSettings() }
        .onChange(of: vm.includeCLI) { _, _ in vm.saveSettings() }
        .onChange(of: vm.includeApps) { _, _ in vm.saveSettings() }
        .onChange(of: vm.showMenuBarCPU) { _, _ in vm.saveSettings() }
        .onChange(of: vm.showMenuBarMemory) { _, _ in vm.saveSettings() }
        .onChange(of: vm.showMenuBarTemperature) { _, _ in vm.saveSettings() }
        .onChange(of: vm.showMenuBarLogo) { _, _ in vm.saveSettings() }
        .onChange(of: vm.showDesktopStats) { _, _ in vm.saveSettings() }
        // A crash log deletion that failed (a file that would not move to
        // the Trash, say) carries its own message; the row stays listed.
        .onChange(of: vm.crashLogs.lastError) { _, message in
            if let message {
                vm.showToast(.error, message)
            }
        }
    }

    /// Form column width: close to System Settings' reading width; the column
    /// keeps this width however wide the window gets.
    private let formColumnWidth: CGFloat = 560

    /// Segmented switching row: the whole row spans the card's width, with the
    /// segmented control centered.
    private var toolbar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 12)

            Picker(L10n.tr("sidebar.settings"), selection: $tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(verbatim: tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // The segmented control shrinks to its content width rather than
            // stretching to fill the remaining space
            .fixedSize()

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var form: some View {
        switch tab {
        case .general:
            generalForm
        case .clean:
            cleanForm
        case .projects:
            projectForm
        case .menubar:
            menubarForm
        case .about:
            aboutForm
        }
    }

    private var generalForm: some View {
        Form {
            Section {
                Picker(L10n.tr("settings.language"), selection: Binding(
                    get: { language },
                    set: { selectLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }

                // The restart entry is only offered when a language different
                // from the current process's is picked: when the language already
                // matches, showing a "Restart Now" button would only make people
                // think something went wrong.
                if language.effective != runningLanguage {
                    Button(L10n.tr("settings.language.restart")) {
                        restartApp()
                    }
                }
            } footer: {
                Text(verbatim: L10n.tr("settings.language.restartHint"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(L10n.tr("settings.launchAtLogin"), isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { vm.setLaunchAtLogin($0) }
                ))
            } header: {
                Label(L10n.tr("settings.launch"), systemImage: "power")
            } footer: {
                Text(verbatim: L10n.tr("settings.launchAtLoginFooter"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The update section only appears when an update source is configured
            // (Info.plist's SUFeedURL): dev builds have no feed, Sparkle doesn't
            // start, and putting two switches here would only mislead.
            if updates.isEnabled {
                updateSection
            }
            // Crash logs close the general form: diagnostics are a different
            // kind of setting from the ones above, and the section carries
            // both the collection switch and the records it produced.
            crashLogsSection
        }
        .formStyle(.grouped)
        // Hide the whole gray background the Form brings: the settings page
        // shares the white rounded card below with the main content, and gray
        // stays only on the section cards.
        .scrollContentBackground(.hidden)
    }

    /// Update section: Sparkle's switches and the manual check entry.
    ///
    /// After a new version is found, downloading, signature verification,
    /// install and restart are all taken over by Sparkle's standard interface;
    /// only the switches and "Check Now" are exposed here.
    private var updateSection: some View {
        Section {
            Toggle(L10n.tr("settings.update.autoCheck"), isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.automaticallyChecksForUpdates = $0 }
            ))
            Toggle(L10n.tr("settings.update.autoDownload"), isOn: Binding(
                get: { updates.automaticallyDownloadsUpdates },
                set: { updates.automaticallyDownloadsUpdates = $0 }
            ))

            Button {
                updates.checkForUpdates()
            } label: {
                Text(verbatim: L10n.tr("settings.update.check"))
            }
            .disabled(!updates.canCheckForUpdates)

            Text(verbatim: lastCheckText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } header: {
            Label(L10n.tr("settings.update.header"), systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text(verbatim: L10n.tr("settings.update.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { updates.refresh() }
    }

    /// "Last check: 3 hours ago" / "Last check: never checked".
    private var lastCheckText: String {
        updates.lastCheckDescription()
    }

    private var cleanForm: some View {
        @Bindable var vm = vm

        return Form {
            Section {
                Picker(L10n.tr("settings.autoSelectRisk"), selection: $vm.autoSelectRisk) {
                    ForEach(AutoSelectLevel.allCases, id: \.self) { level in
                        Text(verbatim: level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Text(verbatim: autoSelectHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(L10n.tr("settings.moveToTrash"), isOn: $vm.moveToTrash)
                Toggle(L10n.tr("settings.includeCLI"), isOn: $vm.includeCLI)
                Toggle(L10n.tr("settings.includeApps"), isOn: $vm.includeApps)
            } header: {
                Label(L10n.tr("settings.cleanMethod"), systemImage: "trash")
            } footer: {
                Text(verbatim: L10n.tr("settings.includeAppsHint"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Hide the whole gray background the Form brings: the settings page
        // shares the white rounded card below with the main content, and gray
        // stays only on the section cards.
        .scrollContentBackground(.hidden)
    }

    /// Project directories section: the same Form card and limited-width column
    /// as the other sections.
    private var projectForm: some View {
        @Bindable var vm = vm

        return Form {
            Section {
                Text(verbatim: L10n.tr("settings.projects.intro"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(L10n.tr("settings.projects.header"), systemImage: "folder.fill.badge.gearshape")
            }

            Section {
                List {
                    ForEach(vm.projectRoots, id: \.self) { root in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(verbatim: root)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button(role: .destructive) {
                                vm.removeProjectRoot(root)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("common.remove"))
                        }
                    }
                }
                .frame(minHeight: 130)
                .overlay {
                    if vm.projectRoots.isEmpty {
                        Text(verbatim: L10n.tr("settings.projects.empty"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 8) {
                    TextField(L10n.tr("settings.projects.textField"), text: $newRoot)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button(L10n.tr("common.add")) {
                        vm.addProjectRoot(newRoot)
                        newRoot = ""
                    }
                    .disabled(newRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(L10n.tr("common.choose")) {
                        chooseDirectory()
                    }
                }
            }

            Section {
                FlowLayout(spacing: 6) {
                    ForEach(CommonProjectRoots.candidates, id: \.self) { candidate in
                        let expanded = FileSystem.expand(candidate)
                        let exists = FileSystem.exists(expanded)
                        let added = vm.projectRoots.contains(expanded)
                        Button {
                            vm.addProjectRoot(expanded)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: added ? "checkmark" : "plus")
                                Text(verbatim: (candidate as NSString).lastPathComponent)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!exists || added)
                        .foregroundStyle(added ? .secondary : (exists ? .primary : .tertiary))
                        .help(exists ? (added ? L10n.tr("settings.projects.added") : expanded) : L10n.tr("settings.projects.notExist"))
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text(verbatim: L10n.tr("settings.projects.quickAdd"))
            }
        }
        .formStyle(.grouped)
        // Hide the whole gray background the Form brings: the settings page
        // shares the white rounded card below with the main content, and gray
        // stays only on the section cards.
        .scrollContentBackground(.hidden)
    }

    /// Menu bar section: which monitor items to show in the tray menu.
    ///
    /// The three switches are each independent, and when all are off the whole
    /// monitor area collapses. The temperature row can only show thermal state:
    /// macOS has no public API for temperature values, so the explanation text
    /// makes it clear, to avoid users thinking the display is broken.
    ///
    /// The logo switch is the odd one out: it controls the icon rather than a
    /// value, so it is listed after the three values and footed separately —
    /// it stays effective while all three values are off (the item then shows
    /// the icon alone), which the footer says outright so nobody turns
    /// everything off and thinks the app has disappeared.
    private var menubarForm: some View {
        @Bindable var vm = vm

        return Form {
            Section {
                Toggle(L10n.tr("settings.menubar.cpu"), isOn: $vm.showMenuBarCPU)
                Toggle(L10n.tr("settings.menubar.memory"), isOn: $vm.showMenuBarMemory)
                Toggle(L10n.tr("settings.menubar.temperature"), isOn: $vm.showMenuBarTemperature)
                Toggle(L10n.tr("settings.menubar.logo"), isOn: $vm.showMenuBarLogo)
            } header: {
                Label(L10n.tr("settings.menubar.header"), systemImage: "menubar.rectangle")
            } footer: {
                Text(verbatim: L10n.tr("settings.menubar.footer"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Desktop overlay: another arrangement of the same monitor data — not
            // crammed into the menu bar, but resident at the top of the desktop.
            // Which items are shown follows the three switches above, and the
            // position is remembered separately once the user drags it (only the
            // agent writes it, see OverlayPositionStore).
            Section {
                Toggle(L10n.tr("settings.overlay.show"), isOn: $vm.showDesktopStats)
            } header: {
                Label(L10n.tr("settings.overlay.header"), systemImage: "macwindow.on.rectangle")
            } footer: {
                Text(verbatim: L10n.tr("settings.overlay.footer"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Hide the whole gray background the Form brings: the settings page
        // shares the white rounded card below with the main content, and gray
        // stays only on the section cards.
        .scrollContentBackground(.hidden)
    }

    private var aboutForm: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    IconBadge(
                        // Fall back to an SF Symbol when the brand image is
                        // missing, so an empty badge doesn't appear
                        systemImage: "sparkle.magnifyingglass",
                        image: BrandIcon.image,
                        tint: .accentColor,
                        diameter: 56,
                        symbolSize: 40,
                        symbolWeight: .regular,
                        cornerRadius: 12,
                        fillOpacity: 0.12
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Mackit")
                            .font(.system(size: 17, weight: .bold))
                        Text(verbatim: L10n.tr("settings.about.subtitle"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(verbatim: L10n.fmt("settings.about.version", Self.versionText))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L10n.tr("settings.about.privacy"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: L10n.tr("settings.about.bundleID"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)

                Link(destination: Links.website) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                        Text(verbatim: L10n.tr("settings.about.website"))
                    }
                    .font(.system(size: 11))
                }
                .padding(.vertical, 2)

                Link(destination: URL(string: "https://github.com/virskor/mackit")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text(verbatim: L10n.tr("settings.about.github"))
                    }
                    .font(.system(size: 11))
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        // Hide the whole gray background the Form brings: the settings page
        // shares the white rounded card below with the main content, and gray
        // stays only on the section cards.
        .scrollContentBackground(.hidden)
    }

    private var autoSelectHint: String {
        switch vm.autoSelectRisk {
        case .none: return L10n.tr("settings.autoSelectHint.none")
        case .safe: return L10n.tr("settings.autoSelectHint.safe")
        case .review: return L10n.tr("settings.autoSelectHint.review")
        case .caution: return L10n.tr("settings.autoSelectHint.caution")
        }
    }

    /// The About page's version row: the main version number, with the build
    /// number appended (only when the two differ).
    ///
    /// The text used to be a hardcoded "Version 1.0" in the catalog — the version
    /// changes with every release, so the hardcoded sentence was wrong from the
    /// second version on. The real version is in the bundle
    /// (CFBundleShortVersionString / CFBundleVersion, written by the build script
    /// from the git tag and commit count), formatted by the same helper the
    /// update controller's bundle-replacement marker uses so the two cannot
    /// drift apart.
    private static var versionText: String {
        AppVersion.display ?? "—"
    }

    /// Switch language: write persistence and AppleLanguages, taking effect after
    /// restart.
    private func selectLanguage(_ language: AppLanguage) {
        self.language = language
        AppLanguage.store(language)
        // The language choice must also be saved to the shared settings: the two
        // processes' UserDefaults are different domains (different bundle IDs),
        // so AppleLanguages in the main app's domain is invisible to the agent,
        // while the menu bar label and tray panel are both drawn by the agent.
        // After writing, broadcast once, and the agent immediately restarts to
        // switch language (see MackitEntry.relaunchIfLanguageChanged).
        SharedStore.saveSettings(["appLanguage": language.rawValue])
        AppBridge.postSettingsChanged()
    }

    /// Restart the app: launch a new process first, then quit itself.
    ///
    /// You can't terminate and then open: while the old process is still around,
    /// LaunchServices only activates the old instance, which doesn't achieve a
    /// restart. A delayed shell command is used as a fallback — wait for the old
    /// process to exit, then open, at which point the system no longer has an
    /// instance of this app.
    ///
    /// The path is escaped per shell single-quote rules: when a single quote
    /// appears in the install directory, failing to escape produces a
    /// syntactically wrong command and the restart fails silently.
    private func restartApp() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        let path = Bundle.main.bundleURL.path
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        relaunch.arguments = ["-c", "sleep 0.6; open '\(escaped)'"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = L10n.tr("common.add")
        if panel.runModal() == .OK, let url = panel.url {
            vm.addProjectRoot(url.path)
        }
    }

    // MARK: - Crash Logs

    /// The crash log section: the collection switch, and the records the
    /// switch has produced.
    ///
    /// The list lives here rather than on a tool page of its own: a crash
    /// record is something the user opens once, when something has already
    /// gone wrong, and it belongs next to the switch that decides whether
    /// more of them get written.
    private var crashLogsSection: some View {
        Section {
            Toggle(L10n.tr("settings.crashLogs.collect"), isOn: Binding(
                get: { vm.collectCrashLogs },
                set: { vm.setCrashLogCollection($0) }
            ))
            // Said out loud when collection is off: the list below is still
            // the truth, it is just not growing.
            if !vm.collectCrashLogs {
                Text(verbatim: L10n.tr("settings.crashLogs.notice.off"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            crashLogsRows
        } header: {
            Label(L10n.tr("settings.crashLogs.header"), systemImage: "exclamationmark.triangle.fill")
        } footer: {
            Text(verbatim: L10n.tr("settings.crashLogs.hint"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var crashLogsRows: some View {
        let entries = vm.crashLogs.entries
        if entries.isEmpty {
            Text(verbatim: L10n.tr("settings.crashLogs.empty"))
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries) { entry in
                Button {
                    vm.crashLogs.select(entry)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Formatters.dateTime(entry.date))
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                            Text(verbatim: crashLogSummary(entry))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                // The same press feedback every other list row in the app
                // uses: a plain button in a form reads as dead text.
                .buttonStyle(RowPressStyle())
            }
            Button(L10n.tr("settings.crashLogs.deleteAll"), role: .destructive) {
                confirmsDeleteAllCrashLogs = true
            }
            .confirmationDialog(
                L10n.tr("settings.crashLogs.deleteAllConfirm"),
                isPresented: $confirmsDeleteAllCrashLogs,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("settings.crashLogs.deleteAllConfirmAction"), role: .destructive) {
                    Task { await vm.crashLogs.deleteAll(moveToTrash: vm.moveToTrash) }
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            }
        }
    }

    /// One line under a crash log's timestamp: which process, which build,
    /// and what killed it.
    private func crashLogSummary(_ entry: CrashLogEntry) -> String {
        let cause = entry.isException ? (entry.exceptionName ?? "") : entry.signalName
        return L10n.fmt("crashLogs.row.summary", entry.processLabel, entry.appVersion, cause)
    }
}

/// The settings page's segments. Declaration order is the arrangement order in
/// the toolbar.
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, clean, projects, menubar, about

    var id: String { rawValue }

    var title: String {
        L10n.tr("settings.tab.\(rawValue)")
    }
}
