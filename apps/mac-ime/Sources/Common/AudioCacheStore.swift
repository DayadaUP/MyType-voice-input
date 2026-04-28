import Foundation

public enum AudioCacheStore {
    public static let directoryName = "MyTypeAudioCache"
    public static let defaultRetentionSeconds: TimeInterval = 3600

    public static func cacheDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    public static func ensureCacheDirectory() throws -> URL {
        let url = cacheDirectoryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func makeFileURL(prefix: String, fileExtension: String) -> URL {
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(prefix)-\(UUID().uuidString)"
        let directory = (try? ensureCacheDirectory()) ?? FileManager.default.temporaryDirectory

        guard !ext.isEmpty else {
            return directory.appendingPathComponent(filename)
        }
        return directory.appendingPathComponent(filename).appendingPathExtension(ext)
    }

    public static func scheduleDeletion(of url: URL, after seconds: TimeInterval = defaultRetentionSeconds) {
        let delay = max(0, seconds)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            deleteFileIfExists(url)
        }
    }

    @discardableResult
    public static func pruneExpiredFiles(olderThan seconds: TimeInterval = defaultRetentionSeconds) -> Int {
        let maxAge = max(0, seconds)
        let cutoff = Date().addingTimeInterval(-maxAge)
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: cacheDirectoryURL(),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var removed = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if modified <= cutoff {
                if deleteFileIfExists(url) {
                    removed += 1
                }
            }
        }
        for url in legacyAudioFileURLs() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if modified <= cutoff {
                if deleteFileIfExists(url) {
                    removed += 1
                }
            }
        }
        return removed
    }

    @discardableResult
    public static func removeAllCachedFiles() throws -> Int {
        let directory = try ensureCacheDirectory()
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var removed = 0
        for url in urls {
            if deleteFileIfExists(url) {
                removed += 1
            }
        }
        for url in legacyAudioFileURLs() {
            if deleteFileIfExists(url) {
                removed += 1
            }
        }
        return removed
    }

    @discardableResult
    public static func deleteFileIfExists(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            try fm.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func legacyAudioFileURLs() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("mytype-") else { return false }
            let ext = url.pathExtension.lowercased()
            guard ["caf", "wav", "m4a"].contains(ext) else { return false }
            return !url.path.contains("/\(directoryName)/")
        }
    }
}
