import AppKit

/// What a quit request for one ranking row means.
enum AppQuitPlan: Equatable {
    /// Ask the app to quit: a quit event first, a force kill only when the
    /// event cannot be delivered.
    case requestQuit
    /// Quit Mackit entirely — the row is our own main app.
    case quitMackit
}

/// Ending one app's process for the memory ranking's quit button.
///
/// The graceful path comes first: `terminate()` posts a quit Apple event,
/// which leaves the target app room to ask about unsaved documents.
/// `forceTerminate()` is only the fallback for when the event cannot be
/// delivered at all — it kills without asking, so it is never the first
/// choice.
///
/// Mackit's own main app is the exception. It shows up in its own ranking
/// like any other app, but quitting only it would leave the tray agent
/// running with nothing to talk to, so the whole app goes instead.
@MainActor
struct AppQuitter {
    /// Resolves a pid to its running app; nil means the process is gone.
    ///
    /// Injectable so tests can drive the decision without terminating real
    /// processes.
    var resolve: (Int32) -> NSRunningApplication?

    init(resolve: @escaping (Int32) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }) {
        self.resolve = resolve
    }

    /// What quitting one row achieved.
    enum Outcome: Equatable {
        /// The quit request was delivered to the app.
        case quitRequested
        /// The row was Mackit itself; the whole app is quitting.
        case quittingMackit
        /// There was nothing to quit: the process is gone.
        case alreadyGone
    }

    /// Ends the app for one ranking row.
    ///
    /// `terminate` and `forceTerminate` are injectable so tests can drive the
    /// graceful-first ordering without signalling real processes;
    /// `quitMackit` runs when the row turns out to be Mackit's own main app.
    ///
    /// `expectedPath` is the .app path the row was sampled from. The pid is
    /// re-resolved at click time, and a pid is not a promise: the app that
    /// owned it may have exited and the system may have handed the number to
    /// an unrelated process. Signalling that process — forceTerminate is
    /// SIGKILL — would kill an app the user never pointed at, so the row is
    /// acted on only while the resolved app is still the one that was
    /// rendered. An empty path (a row whose bundle could not be read) carries
    /// no identity to check and is acted on as before.
    @discardableResult
    func quit(
        pid: Int,
        expectedPath: String = "",
        terminate: @MainActor (NSRunningApplication) -> Bool = { $0.terminate() },
        forceTerminate: @MainActor (NSRunningApplication) -> Bool = { $0.forceTerminate() },
        quitMackit: @escaping @MainActor () -> Void
    ) -> Outcome {
        guard let raw = Int32(exactly: pid),
              let app = resolve(raw),
              !app.isTerminated,
              Self.isSameApp(app, asPath: expectedPath) else {
            return .alreadyGone
        }

        switch Self.plan(bundleID: app.bundleIdentifier) {
        case .quitMackit:
            quitMackit()
            return .quittingMackit
        case .requestQuit:
            // Short-circuit: a force kill is only reached when the quit event
            // could not be delivered. Skipping it on success also keeps a
            // signal from being sent to a pid the app has just released.
            return terminate(app) || forceTerminate(app) ? .quitRequested : .alreadyGone
        }
    }

    /// Whether the resolved app is still the one the row was rendered from.
    ///
    /// The sampled path comes from the same `bundleURL` this compares against,
    /// so a plain equality is the check — a canonicalization would only add a
    /// filesystem round trip for a value both sides spell identically.
    private static func isSameApp(_ app: NSRunningApplication, asPath expectedPath: String) -> Bool {
        guard !expectedPath.isEmpty else { return true }
        return app.bundleURL?.path == expectedPath
    }

    /// What a quit request for the given bundle id means.
    static func plan(bundleID: String?) -> AppQuitPlan {
        bundleID == AppIdentity.mainBundleID ? .quitMackit : .requestQuit
    }
}
