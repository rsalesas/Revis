import Foundation

/// The other half of the in-app updater: replace the installed app bundle and relaunch it.
///
/// A target of its own rather than a mode of the app, because a bundle cannot replace
/// itself while its own code is mapped. The app copies this binary OUT of the bundle before
/// running it — a helper still sitting in `Contents/Helpers` would be deleted from under
/// itself mid-swap.
///
/// Deliberately dumb. Every check that decides *whether* to install — checksum, code
/// signature, version — has already run in the app (see `AppUpdater`). By the time this
/// starts, the only questions left are "has the app exited" and "did the rename succeed".
enum ApplyUpdate {

    static func run(_ arguments: [String]) -> Never {
        var pid: pid_t?
        var staged: String?
        var installed: String?
        var index = 0
        while index < arguments.count - 1 {
            switch arguments[index] {
            case "--pid": pid = pid_t(arguments[index + 1])
            case "--staged": staged = arguments[index + 1]
            case "--installed": installed = arguments[index + 1]
            default: break
            }
            index += 1
        }
        guard let pid, let staged, let installed else {
            FileHandle.standardError.write(Data("apply-update: missing arguments\n".utf8))
            exit(2)
        }

        waitForExit(of: pid)

        let stagedURL = URL(fileURLWithPath: staged)
        let installedURL = URL(fileURLWithPath: installed)

        // One atomic directory replacement. If it throws, nothing has moved and the old app
        // is still exactly where it was — so a failed update is a no-op rather than a
        // half-installed bundle.
        do {
            _ = try FileManager.default.replaceItemAt(installedURL, withItemAt: stagedURL)
        } catch {
            FileHandle.standardError.write(
                Data("apply-update: \(error.localizedDescription)\n".utf8))
            // Relaunch the old copy regardless: the user asked for the app, and it is still
            // intact. Better a stale Revis than no Revis.
            relaunch(installedURL)
            exit(1)
        }
        relaunch(installedURL)
        exit(0)
    }

    /// Poll until the process is gone. `kill(pid, 0)` reports reachability without
    /// signalling; we are not the parent, so `waitpid` is not available to us.
    private static func waitForExit(of pid: pid_t, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }        // ESRCH: it has exited
            usleep(100_000)
        }
    }

    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", app.path]
        try? process.run()
        process.waitUntilExit()
    }
}
