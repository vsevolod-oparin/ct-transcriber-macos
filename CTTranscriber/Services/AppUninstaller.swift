import Foundation
import AppKit

enum AppUninstaller {
    static func run() {
        let home = NSHomeDirectory()
        let appPath = Bundle.main.bundlePath

        let paths = [
            "\(home)/Library/Application Support/CTTranscriber",
            "\(home)/Library/Application Support/CT Transcriber",
            "\(home)/.ct-transcriber",
            "\(home)/.config/ct-transcriber",
            "\(home)/Library/Preferences/com.branch.ct-transcriber.plist",
            "\(home)/Library/Application Support/default.store",
            "\(home)/Library/Application Support/default.store-shm",
            "\(home)/Library/Application Support/default.store-wal",
            appPath,
        ]

        // Spawn a shell process that waits for this app to exit, then deletes everything.
        let pid = ProcessInfo.processInfo.processIdentifier
        let rmCommands = paths.map { "rm -rf \"\($0)\"" }.joined(separator: "\n")
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            \(rmCommands)
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        NSApplication.shared.terminate(nil)
    }
}
