import Foundation

public struct ClaudeSessionEvidenceParser: AgentSessionEvidenceParsing {
    public let source = AgentSource.claudeHooks

    public init() {}

    public func parse(
        _ data: Data,
        context: AgentEvidenceContext
    ) throws -> AgentEvidenceParseResult {
        let decoded = decodeJSONLines(ClaudeRecord.self, from: data)
        var identity = ClaudeIdentity()
        var latestStatus: AgentStatus?
        var updatedAt = context.observedAt

        for record in decoded.records {
            identity.consume(record)
            updatedAt = evidenceDate(record.timestamp, fallback: updatedAt)
            if let nextStatus = status(for: record) {
                latestStatus = nextStatus
            }
        }

        guard let id = identity.id, !id.isEmpty else {
            throw AgentEvidenceParserError.missingSessionIdentity
        }
        return AgentEvidenceParseResult(
            session: makeSession(
                id: id,
                identity: identity,
                status: latestStatus ?? .idle,
                updatedAt: updatedAt,
                context: context
            ),
            malformedLineCount: decoded.malformedLineCount
        )
    }

    private func makeSession(
        id: String,
        identity: ClaudeIdentity,
        status: AgentStatus,
        updatedAt: Date,
        context: AgentEvidenceContext
    ) -> AgentSession {
        AgentSession(
            id: AgentSessionID(source: .claudeHooks, externalID: id),
            title: evidenceTitle(
                preferred: identity.title,
                workingDirectory: identity.workingDirectory,
                fallback: "Claude"
            ),
            detail: identity.workingDirectory,
            status: sessionStatus(status, identity: identity, context: context),
            updatedAt: updatedAt,
            focusTarget: focusTarget(id: id, identity: identity, context: context)
        )
    }

    /// The Claude desktop app writes its Code tab transcripts without keeping them open,
    /// so open-file liveness never holds for them. The adapter's recency window bounds
    /// how long their last reported status is shown instead.
    private func sessionStatus(
        _ status: AgentStatus,
        identity: ClaudeIdentity,
        context: AgentEvidenceContext
    ) -> AgentStatus {
        identity.isDesktopSession ? status : statusWithLiveness(status, isLive: context.isLive)
    }

    private func focusTarget(
        id: String,
        identity: ClaudeIdentity,
        context: AgentEvidenceContext
    ) -> AgentFocusTarget? {
        if identity.isDesktopSession {
            return .claudeDesktopSession(sessionID: id)
        }
        return terminalFocusTarget(
            bundleIdentifier: context.terminalBundleIdentifier,
            workingDirectory: identity.workingDirectory
        )
    }

    private func status(for record: ClaudeRecord) -> AgentStatus? {
        switch record.type {
        case "user":
            return .working
        case "assistant":
            if record.message?.content.contains(where: isWaitingTool) == true {
                return .waiting
            }
            switch record.message?.stopReason {
            case "end_turn": return .complete
            case "tool_use": return .working
            default: return nil
            }
        case "error":
            return .error
        default:
            return nil
        }
    }

    private func isWaitingTool(_ content: ClaudeRecord.Content) -> Bool {
        guard content.type == "tool_use" else { return false }
        return content.name == "AskUserQuestion"
    }
}

private struct ClaudeIdentity {
    static let desktopEntrypoint = "claude-desktop"

    var id: String?
    var aiTitle: String?
    var customTitle: String?
    var workingDirectory: String?
    var isDesktopSession = false

    /// A title the user (or the desktop app) set explicitly wins over the AI-generated one.
    var title: String? {
        customTitle ?? aiTitle
    }

    mutating func consume(_ record: ClaudeRecord) {
        if let sessionID = record.sessionID, !sessionID.isEmpty {
            id = sessionID
        }
        if record.type == "ai-title", let aiTitle = record.aiTitle {
            self.aiTitle = aiTitle
        }
        if record.type == "custom-title", let customTitle = record.customTitle, !customTitle.isEmpty {
            self.customTitle = customTitle
        }
        if let cwd = record.workingDirectory, !cwd.isEmpty {
            workingDirectory = cwd
        }
        if record.entrypoint == Self.desktopEntrypoint {
            isDesktopSession = true
        }
    }
}

private struct ClaudeRecord: Decodable {
    let type: String
    let sessionID: String?
    let timestamp: String?
    let workingDirectory: String?
    let aiTitle: String?
    let customTitle: String?
    let entrypoint: String?
    let message: Message?

    struct Message: Decodable {
        let stopReason: String?
        let content: [Content]

        enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case content
        }
    }

    struct Content: Decodable {
        let type: String?
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case legacySessionID = "session_id"
        case timestamp
        case workingDirectory = "cwd"
        case aiTitle
        case customTitle
        case entrypoint
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        sessionID =
            try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .legacySessionID)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        workingDirectory = try container.decodeIfPresent(
            String.self,
            forKey: .workingDirectory
        )
        aiTitle = try container.decodeIfPresent(String.self, forKey: .aiTitle)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        entrypoint = try container.decodeIfPresent(String.self, forKey: .entrypoint)
        message =
            type == "assistant"
            ? try container.decodeIfPresent(Message.self, forKey: .message)
            : nil
    }
}
