import Foundation
import AppKit

enum AppUninstaller {
    @MainActor
    static func run() {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        let paths = [
            AppPaths.storageRoot.path,
            NSHomeDirectory() + "/Library/Caches/MetalWhisper",
            NSHomeDirectory() + "/.config/ct-transcriber",
            NSHomeDirectory() + "/.ct-transcriber",
            AppPaths.preferencesPlist,
            appPath,
        ]

        // Spawn a cleanup process that waits for this app to exit, then deletes everything.
        // Uses argument array (not shell interpolation) to prevent command injection.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")

        // Build script safely: paths are passed as positional arguments ($1, $2, ...),
        // NOT interpolated into the script string.
        var args = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.2; done; shift; for p in \"$@\"; do rm -rf \"$p\"; done",
                    "--", // separator
                    String(pid)] // $1 = PID
        args.append(contentsOf: paths) // $2... = paths to delete

        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        NSApplication.shared.terminate(nil)
    }
}
