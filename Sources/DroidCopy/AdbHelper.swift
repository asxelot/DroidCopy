import AppKit

/// The small background-only app inside DroidCopy.app that runs `adb start-server`.
///
/// macOS counts what an app starts as part of that app, and keeps showing the app as "Running
/// in Background" in the Dock until all of it has exited. adb's server should outlive DroidCopy,
/// so it must not be counted as DroidCopy's:
/// - started directly (or through launchd), it shares DroidCopy's place in that bookkeeping;
/// - the helper, launched through Launch Services, gets a place of its own, but launched with
///   NSWorkspace it is recorded as DroidCopy's child;
/// - so `/usr/bin/open` launches it, started with DroidCopy disclaiming responsibility for it
///   (what Terminal does for the commands it runs). Then nothing links it back to DroidCopy.
/// Being background-only, the helper never shows in the Dock. build-app.sh puts it in
/// Contents/Helpers.
enum AdbHelper {
    static var bundleURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DroidCopy adb.app")
    }

    /// Launches the helper. False when it isn't there (running from `swift run`) or won't launch.
    static func startServer(adbPath: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return false }
        let args = ["-g", "-j", "-n", bundleURL.path, "--args", adbPath]
        guard let pid = spawnDisclaimed("/usr/bin/open", args) else { return false }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                cont.resume(returning: status == 0)
            }
        }
    }

    /// Starts a program this app isn't responsible for, with no inherited input or output.
    /// `responsibility_spawnattrs_setdisclaim` is looked up at run time, so if it's ever missing
    /// this returns nil and adb starts its server the usual way.
    static func spawnDisclaimed(_ path: String, _ args: [String]) -> pid_t? {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Bool) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        let disclaim = unsafeBitCast(symbol, to: Disclaim.self)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        guard disclaim(&attr, true) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attr, argv, environ) == 0 else { return nil }
        return pid
    }
}
