import Foundation

enum AppResourceLocator {
    private static let resourceBundleName = "MyTypeIME_MyTypeIMEDemo"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        resourceBundle?.url(forResource: name, withExtension: ext)
    }

    private static let resourceBundle: Bundle? = {
        for rootURL in bundleSearchRoots() {
            let bundleURL = rootURL.appendingPathComponent("\(resourceBundleName).bundle", isDirectory: true)
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }
        return nil
    }()

    private static func bundleSearchRoots() -> [URL] {
        var roots: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL)
        }

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executableDirectory)
        }

        roots.append(Bundle.main.bundleURL)

        var uniqueRoots: [URL] = []
        var seenPaths = Set<String>()
        for url in roots {
            let path = url.standardizedFileURL.path
            if seenPaths.insert(path).inserted {
                uniqueRoots.append(url)
            }
        }
        return uniqueRoots
    }
}
