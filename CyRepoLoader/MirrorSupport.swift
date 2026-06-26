import Foundation

struct HTTPStatusError: Error, LocalizedError {
    let statusCode: Int
    let url: URL

    var errorDescription: String? {
        "HTTP \(statusCode) from \(url.absoluteString)"
    }

    var isRestricted: Bool {
        statusCode == 401 || statusCode == 403
    }
}

actor MirrorIssueCollector {
    private var failedFiles: [String] = []
    private var restrictedFiles: [String] = []

    func addFailed(_ path: String) {
        failedFiles.append(path)
    }

    func addRestricted(_ path: String) {
        restrictedFiles.append(path)
    }

    func snapshot() -> (failed: [String], restricted: [String]) {
        (failedFiles, restrictedFiles)
    }
}

actor URLVisitTracker {
    private var visitedURLs = Set<String>()

    func markIfNew(_ url: URL) -> Bool {
        let key = url.absoluteString
        guard !visitedURLs.contains(key) else { return false }
        visitedURLs.insert(key)
        return true
    }
}

@MainActor
final class DownloadLogStorage {
    private(set) var fullOutput = ""
    private(set) var visibleEntries: [String] = []

    func reset() {
        fullOutput = ""
        visibleEntries = []
    }

    func append(_ message: String, maxVisibleEntries: Int) -> Bool {
        fullOutput += message
        visibleEntries.append(message)

        guard visibleEntries.count > maxVisibleEntries else {
            return false
        }

        let removedEntries = visibleEntries.count - maxVisibleEntries
        visibleEntries.removeFirst(removedEntries)
        return true
    }

    func visibleText() -> String {
        visibleEntries.joined()
    }
}

enum RepoURLResolver {
    static func packageURL(for packagePath: String, repoBaseURL: URL, originalBaseURL: URL) -> URL? {
        let trimmed = packagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        let normalized = trimmed
            .replacingOccurrences(of: "^\\./", with: "", options: .regularExpression)

        if normalized.hasPrefix("/") {
            var components = URLComponents(url: originalBaseURL, resolvingAgainstBaseURL: false)
            components?.path = normalized
            components?.query = nil
            components?.fragment = nil
            return components?.url
        }

        if normalized.hasPrefix("debs2.0/"),
           originalBaseURL.host?.localizedCaseInsensitiveContains("thebigboss") == true {
            var components = URLComponents(url: originalBaseURL, resolvingAgainstBaseURL: false)
            components?.path = "/repofiles/cydia/"
            components?.query = nil
            components?.fragment = nil
            return components?.url?.appendingPathComponent(normalized)
        }

        return URL(string: normalized, relativeTo: repoBaseURL)?.absoluteURL
    }

    static func localRelativePath(for url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        return path.removingPercentEncoding ?? path
    }

    static func localRelativePath(for url: URL, relativeTo baseURL: URL) -> String {
        let basePath = normalizedDirectoryPath(baseURL.path)
        var path = url.path.removingPercentEncoding ?? url.path
        if path.hasPrefix(basePath) {
            path.removeFirst(basePath.count)
        }
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        return path.isEmpty ? "index.html" : path
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/"
        }
        return path.hasSuffix("/") ? path : path + "/"
    }
}

enum CydiaHTTPClient {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60.0
        configuration.timeoutIntervalForResource = 600.0
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
