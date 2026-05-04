import Foundation

enum AppPaths {
    private static let appName = "CTTranscriber"

    static let storageRoot: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent(appName, isDirectory: true)
    }()

    static var settingsURL: URL {
        storageRoot.appendingPathComponent("settings.json")
    }

    static var logFileURL: URL {
        storageRoot.appendingPathComponent("ct-transcriber.log")
    }

    static var filesDirectory: URL {
        storageRoot.appendingPathComponent("files", isDirectory: true)
    }

    static var dataDirectory: URL {
        storageRoot.appendingPathComponent("data", isDirectory: true)
    }

    static var storeURL: URL {
        dataDirectory.appendingPathComponent("default.store")
    }

    static var modelsDirectory: URL {
        storageRoot.appendingPathComponent("models", isDirectory: true)
    }

    static var preferencesPlist: String {
        NSHomeDirectory() + "/Library/Preferences/com.branch.ct-transcriber.plist"
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [storageRoot, dataDirectory, filesDirectory, modelsDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func migrateIfNeeded() {
        let fm = FileManager.default
        let marker = storageRoot.appendingPathComponent(".migrated-v2")

        guard !fm.fileExists(atPath: marker.path) else { return }

        ensureDirectories()

        let migrationOk = migrateSwiftDataStore(fm: fm)
        migrateSettingsFromXDG(fm: fm)
        migrateModelsFromMetalWhisperCache(fm: fm)

        if migrationOk {
            fm.createFile(atPath: marker.path, contents: nil)
        }
    }

    private static func migrateSwiftDataStore(fm: FileManager) -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")

        var migrationFailed = false
        var copiedSources: [URL] = []

        for ext in ["", "-shm", "-wal"] {
            let src = appSupport.appendingPathComponent("default.store\(ext)")
            let dst = dataDirectory.appendingPathComponent("default.store\(ext)")
            if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.copyItem(at: src, to: dst)
                    copiedSources.append(src)
                } catch {
                    AppLogger.error("Migration failed: could not copy \(src.path) -> \(dst.path): \(error)")
                    migrationFailed = true
                    break
                }
            }
        }

        if !migrationFailed {
            for src in copiedSources {
                do {
                    try fm.removeItem(at: src)
                } catch {
                    AppLogger.error("Migration failed: could not remove original \(src.path): \(error)")
                    migrationFailed = true
                }
            }
        }

        return !migrationFailed
    }

    private static func migrateSettingsFromXDG(fm: FileManager) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdgSettings = home.appendingPathComponent(".config/ct-transcriber/settings.json")
        let target = settingsURL

        if fm.fileExists(atPath: xdgSettings.path) && !fm.fileExists(atPath: target.path) {
            try? fm.copyItem(at: xdgSettings, to: target)
        }
    }

    private static func migrateModelsFromMetalWhisperCache(fm: FileManager) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let cachesDir = caches else { return }
        let mwCache = cachesDir.appendingPathComponent("MetalWhisper/models", isDirectory: true)

        guard let contents = try? fm.contentsOfDirectory(at: mwCache, includingPropertiesForKeys: nil) else { return }

        for item in contents {
            let dest = modelsDirectory.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: item, to: dest)
            }
        }

        if fm.fileExists(atPath: mwCache.path) {
            try? fm.removeItem(at: mwCache)
        }
    }
}
