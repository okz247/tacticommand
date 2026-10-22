import Foundation
import XCTest

@testable import CreatorMicroControl

final class ClaudeDesktopSessionLocatorTests: XCTestCase {
    func testFindsTheDesktopSessionForATranscriptSession() throws {
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ClaudeDesktopSessionLocator(root: root)

        XCTAssertEqual(locator.desktopSessionID(forCLISessionID: "cli-1"), "local_abc-123")
        XCTAssertNil(locator.desktopSessionID(forCLISessionID: "cli-missing"))
        XCTAssertNil(locator.desktopSessionID(forCLISessionID: ""))
    }

    func testIgnoresRecordsWhoseDesktopIDIsNotAValidSessionID() throws {
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ClaudeDesktopSessionLocator(root: root)

        XCTAssertNil(locator.desktopSessionID(forCLISessionID: "cli-2"))
    }

    func testBuildsTheDesktopContinueLinkOnlyForValidIDs() {
        XCTAssertEqual(
            ClaudeDesktopSessionLocator.continueURL(forDesktopSessionID: "local_abc-123")?.absoluteString,
            "claude://code/continue?session=local_abc-123"
        )
        XCTAssertNil(ClaudeDesktopSessionLocator.continueURL(forDesktopSessionID: "local_../x"))
        XCTAssertNil(ClaudeDesktopSessionLocator.continueURL(forDesktopSessionID: "session_1"))
    }

    func testMissingRootFindsNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let locator = ClaudeDesktopSessionLocator(root: missing)

        XCTAssertNil(locator.desktopSessionID(forCLISessionID: "cli-1"))
    }

    private func makeSessionsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let organization = root.appendingPathComponent("account/organization", isDirectory: true)
        try FileManager.default.createDirectory(at: organization, withIntermediateDirectories: true)
        let records = [
            "local_other-1": #"{"sessionId":"local_other-1","cliSessionId":"cli-other"}"#,
            "local_abc-123": #"{"sessionId":"local_abc-123","cliSessionId":"cli-1"}"#,
            "local_bad": #"{"sessionId":"../escape","cliSessionId":"cli-2"}"#,
        ]
        for (name, json) in records {
            try Data(json.utf8).write(to: organization.appendingPathComponent("\(name).json"))
        }
        return root
    }
}
