import Foundation

/// Finds the Claude desktop app's own session ID (`local_…`) for a Claude Code transcript
/// session, so an Agent key can open that exact Code tab session through the app's
/// `claude://code/continue?session=…` link.
///
/// The desktop app keeps one small JSON record per Code session under
/// `<root>/<account>/<organization>/local_<id>.json`; each record names the transcript
/// session it currently writes as `cliSessionId`. Records are read only, never changed.
struct ClaudeDesktopSessionLocator: Sendable {
    static let applicationBundleIdentifier = "com.anthropic.claudefordesktop"

    let root: URL
    let maximumRecords: Int

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions",
            isDirectory: true
        ),
        maximumRecords: Int = 400
    ) {
        self.root = root
        self.maximumRecords = maximumRecords
    }

    func desktopSessionID(forCLISessionID cliSessionID: String) -> String? {
        guard !cliSessionID.isEmpty else { return nil }
        let needle = Data(cliSessionID.utf8)
        for recordURL in recentRecordURLs() {
            guard
                let data = try? Data(contentsOf: recordURL, options: .mappedIfSafe),
                data.range(of: needle) != nil,
                let record = try? JSONDecoder().decode(DesktopSessionRecord.self, from: data),
                record.cliSessionId == cliSessionID,
                Self.isDesktopSessionID(record.sessionId)
            else { continue }
            return record.sessionId
        }
        return nil
    }

    static func continueURL(forDesktopSessionID sessionID: String) -> URL? {
        guard isDesktopSessionID(sessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url
    }

    /// Mirrors the desktop app's own check on this link: `local_` then 1–64 letters,
    /// digits, or hyphens.
    static func isDesktopSessionID(_ sessionID: String) -> Bool {
        sessionID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
    }

    /// Most recently modified records first, so active sessions are found quickly.
    private func recentRecordURLs() -> [URL] {
        let records = organizationDirectories().flatMap(recordURLs(in:))
        return
            records
            .sorted { $0.modified > $1.modified }
            .prefix(maximumRecords)
            .map(\.url)
    }

    private func organizationDirectories() -> [URL] {
        subdirectories(of: root).flatMap(subdirectories(of:))
    }

    private func subdirectories(of directory: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func recordURLs(in directory: URL) -> [(url: URL, modified: Date)] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
        return entries.compactMap { url in
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" else {
                return nil
            }
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return (url, modified)
        }
    }
}

private struct DesktopSessionRecord: Decodable {
    let sessionId: String
    let cliSessionId: String?
}
