import Foundation

// MARK: - Normalised agent activity
//
// Claude and Codex both record what their agents are doing, in structured form,
// on disk. They disagree about almost everything else: Claude writes JSONL
// transcripts of content blocks, Codex keeps a SQLite database of typed items
// with turn durations already computed. Rovo we have not been able to inspect.
//
// Everything is normalised onto one small event so the visualisation never has
// to care which agent produced it, and so an agent we cannot read degrades to
// the coarse state machine rather than breaking the view.
//
// PRIVACY: only the shape of the work is stored, never its content. Reasoning
// text, shell commands and file diffs stay on disk where the agent put them.
// `detail` holds a tool name or a short label, never a payload.

enum AgentPhase: String, Codable {
    case thinking     // model is reasoning
    case tool         // running a tool, editing, executing
    case network      // reaching the internet
    case waiting      // wants the human
    case done         // turn finished
    case idle

    /// Coarse pane states map onto phases so an unreadable agent still animates.
    static func fromState(_ state: String) -> AgentPhase {
        switch state {
        case "working": return .tool
        case "blocked": return .waiting
        case "done": return .done
        default: return .idle
        }
    }
}

struct AgentEvent: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let paneId: String
    let kind: String          // claude | codex | rovo
    let phase: AgentPhase
    let detail: String        // tool name or short label, never a payload
    let durationMs: Int?

    static func == (a: AgentEvent, b: AgentEvent) -> Bool { a.id == b.id }
}

/// Bounded in-memory log. Nothing is persisted: the prototype should not become
/// a second copy of the user's work.
final class AgentEventLog {
    private(set) var events: [AgentEvent] = []
    private let cap = 4000

    func append(_ e: AgentEvent) {
        events.append(e)
        if events.count > cap { events.removeFirst(events.count - cap) }
    }

    func append(contentsOf batch: [AgentEvent]) {
        guard !batch.isEmpty else { return }
        events.append(contentsOf: batch)
        if events.count > cap { events.removeFirst(events.count - cap) }
    }

    /// Most recent phase per pane, for driving avatar behaviour.
    func latestPhase(paneId: String, within: TimeInterval = 12) -> AgentEvent? {
        let cutoff = Date().addingTimeInterval(-within)
        return events.last { $0.paneId == paneId && $0.at > cutoff }
    }

    func recent(paneId: String, limit: Int = 40) -> [AgentEvent] {
        events.suffix(where: { $0.paneId == paneId }, limit: limit)
    }
}

private extension Array {
    func suffix(where match: (Element) -> Bool, limit: Int) -> [Element] {
        var out: [Element] = []
        for e in reversed() where match(e) {
            out.append(e)
            if out.count == limit { break }
        }
        return out.reversed()
    }
}

// MARK: - Correlating a pane with an agent's own session
//
// Neither store knows anything about amux panes. Both are keyed by their own
// session id, and the only natural join is the working directory, which is
// exactly the case amux encourages you to break by running several agents in
// one repo. For a prototype we take the most recently touched session under a
// pane's cwd and accept the ambiguity; the real fix is to stamp a pane id into
// the environment and have Claude's hooks echo it back.

enum SessionMatch {
    /// Claude slugifies the project path into a directory name under
    /// ~/.claude/projects by replacing every non-alphanumeric character, not
    /// just '/': /Users/me/.conclave/x -> -Users-me--conclave-x. Replacing only
    /// '/' made any cwd containing '.' or '_' resolve to nothing, which
    /// silently killed the activity pipeline for that pane.
    static func claudeProjectDir(for cwd: String) -> URL? {
        let slug = cwd.replacingOccurrences(
            of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Newest transcript in a project directory.
    static func newestTranscript(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }
    }
}
