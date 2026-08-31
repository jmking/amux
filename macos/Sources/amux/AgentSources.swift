import Foundation

// MARK: - Reading what agents record about themselves
//
// Both Claude and Codex append newline-delimited JSON as they work, so both are
// read the same way: resolve the session file for a pane's working directory,
// remember how far we got, and parse whatever is new. Codex also keeps a SQLite
// mirror of this, but a running Codex holds it in WAL mode and tailing the
// rollout avoids any chance of interfering with it.

/// Reads whole lines appended to a file since the last visit.
final class LineTailer {
    private(set) var url: URL?
    private var offset: UInt64 = 0
    private var carry = Data()

    /// Points at a new file, restarting from its end so history is not replayed
    /// as if it had just happened.
    func retarget(_ newURL: URL?, fromEnd: Bool = true) {
        guard newURL?.path != url?.path else { return }
        url = newURL
        carry.removeAll()
        offset = 0
        if fromEnd, let u = newURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? UInt64 {
            offset = size
        }
    }

    func newLines() -> [Data] {
        guard let url, let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return [] }
        if end < offset { offset = 0; carry.removeAll() }   // file was rotated
        guard end > offset else { return [] }
        try? fh.seek(toOffset: offset)
        let chunk = (try? fh.readToEnd()) ?? Data()
        offset = end
        var buf = carry + chunk
        carry.removeAll()
        var lines: [Data] = []
        while let nl = buf.firstIndex(of: 0x0a) {
            lines.append(buf[buf.startIndex..<nl])
            buf = buf[buf.index(after: nl)...]
        }
        carry = Data(buf)          // trailing partial line, completed next tick
        return lines
    }
}

// MARK: - Claude

/// Content blocks in a transcript's assistant records say what the model did:
/// `thinking` for reasoning, `tool_use`/`tool_result` for work, paired by id so
/// each call yields a duration.
/// @unchecked: created on the main actor, then touched exclusively on the
/// model's serial poll queue — the queue is the synchronisation.
final class ClaudeReader: @unchecked Sendable {
    private let tailer = LineTailer()
    private var pending: [String: (Date, String)] = [:]
    private var lastResolve = Date.distantPast
    private var cwd: String?
    /// Test seam: point at one file and replay it from the start.
    private let forced: URL?
    private let fromEnd: Bool

    init(forced: URL? = nil, fromEnd: Bool = true) {
        self.forced = forced
        self.fromEnd = fromEnd
    }

    private static let networkTools: Set<String> = ["WebFetch", "WebSearch"]

    static func isNetwork(_ tool: String) -> Bool {
        if networkTools.contains(tool) { return true }
        let t = tool.lowercased()
        return t.contains("browser") || t.contains("chrome") || t.contains("fetch")
            || t.contains("websearch")
    }

    func poll(paneId: String, cwd: String?) -> [AgentEvent] {
        resolve(cwd: cwd)
        var out: [AgentEvent] = []
        for line in tailer.newLines() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let rec = obj["type"] as? String,
                  rec == "assistant" || rec == "user",   // results come back on user records
                  let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            let at = Self.stamp(obj["timestamp"] as? String)
            for b in blocks {
                switch b["type"] as? String {
                case "thinking":
                    out.append(AgentEvent(at: at, paneId: paneId, kind: "claude",
                                          phase: .thinking, detail: "thinking", durationMs: nil))
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    if let id = b["id"] as? String { pending[id] = (at, name) }
                    // interrupted calls never get a result; stop the orphans
                    // accumulating over a long session
                    if pending.count > 512 {
                        for (k, v) in pending.sorted(by: { $0.value.0 < $1.value.0 }).prefix(pending.count - 512) {
                            _ = v; pending.removeValue(forKey: k)
                        }
                    }
                    out.append(AgentEvent(at: at, paneId: paneId, kind: "claude",
                                          phase: Self.isNetwork(name) ? .network : .tool,
                                          detail: Self.shortTool(name), durationMs: nil))
                case "tool_result":
                    if let id = b["tool_use_id"] as? String, let started = pending.removeValue(forKey: id) {
                        let ms = Int(at.timeIntervalSince(started.0) * 1000)
                        out.append(AgentEvent(at: at, paneId: paneId, kind: "claude",
                                              phase: .done, detail: Self.shortTool(started.1),
                                              durationMs: max(ms, 0)))
                    }
                default: break
                }
            }
        }
        return out
    }

    /// MCP tools are namespaced `mcp__<server>__<tool>`; keep the tool itself.
    /// Splitting on a single underscore mangles names that contain one.
    static func shortTool(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.components(separatedBy: "__").filter { !$0.isEmpty }
        return parts.last ?? name
    }

    private static func stamp(_ s: String?) -> Date {
        guard let s else { return Date() }
        // fractional first: real transcripts carry millisecond timestamps, so
        // the plain parse failed on every event before this order
        return ISO8601DateFormatter.withFractional.date(from: s)
            ?? ISO8601DateFormatter.plain.date(from: s) ?? Date()
    }

    private func resolve(cwd newCwd: String?) {
        if let forced { tailer.retarget(forced, fromEnd: fromEnd); return }
        guard let newCwd else { return }
        // re-checking every tick would stat the project dir constantly
        if newCwd == cwd && Date().timeIntervalSince(lastResolve) < 10 { return }
        cwd = newCwd
        lastResolve = Date()
        guard let dir = SessionMatch.claudeProjectDir(for: newCwd) else {
            tailer.retarget(nil); return
        }
        // Sticky while live: with two agents in one project, always chasing the
        // newest transcript flip-flops the tailer between their files, which
        // cross-attributes one agent's events to both panes and drops chunks on
        // every switch. Only rehunt once the current file has gone quiet.
        if let current = tailer.url,
           let mod = (try? FileManager.default.attributesOfItem(atPath: current.path)[.modificationDate]) as? Date,
           Date().timeIntervalSince(mod) < 30 {
            return
        }
        tailer.retarget(SessionMatch.newestTranscript(in: dir))
    }
}

extension ISO8601DateFormatter {
    static let plain = ISO8601DateFormatter()
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Codex

/// Rollouts carry `event_msg` records whose `item_completed` payload names the
/// kind of work directly: Reasoning, CommandExecution, FileChange, WebSearch.
/// No inference needed, unlike Claude where we classify by tool name.
/// @unchecked: same single-serial-queue discipline as ClaudeReader.
final class CodexReader: @unchecked Sendable {
    private let tailer = LineTailer()
    private var lastResolve = Date.distantPast
    private var cwd: String?
    /// Test seam: point at one file and replay it from the start.
    private let forced: URL?
    private let fromEnd: Bool

    init(forced: URL? = nil, fromEnd: Bool = true) {
        self.forced = forced
        self.fromEnd = fromEnd
    }

    /// Newer rollouts: `item_completed` carries a typed item.
    private static let phaseFor: [String: AgentPhase] = [
        "Reasoning": .thinking,
        "CommandExecution": .tool,
        "FileChange": .tool,
        "WebSearch": .network,
        "AgentMessage": .done,
        "ContextCompaction": .tool,
    ]

    /// Older rollouts: discrete event_msg types instead of item_completed. Both
    /// shapes appear in the wild, so both are handled.
    private static let legacyPhaseFor: [String: (AgentPhase, String)] = [
        "agent_reasoning":   (.thinking, "Reasoning"),
        "web_search_end":    (.network,  "WebSearch"),
        "patch_apply_end":   (.tool,     "FileChange"),
        "mcp_tool_call_end": (.tool,     "McpToolCall"),
        "exec_command_end":  (.tool,     "CommandExecution"),
        "agent_message":     (.done,     "AgentMessage"),
        "context_compacted": (.tool,     "ContextCompaction"),
    ]

    func poll(paneId: String, cwd: String?) -> [AgentEvent] {
        resolve(cwd: cwd)
        var out: [AgentEvent] = []
        for line in tailer.newLines() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "event_msg":
                switch payload["type"] as? String {
                case "item_completed":
                    let item = payload["item"] as? [String: Any] ?? [:]
                    let t = (item["item_type"] as? String) ?? (item["type"] as? String) ?? ""
                    guard let phase = Self.phaseFor[t] else { break }
                    out.append(AgentEvent(at: Date(), paneId: paneId, kind: "codex",
                                          phase: phase, detail: t, durationMs: nil))
                case "task_complete":
                    out.append(AgentEvent(at: Date(), paneId: paneId, kind: "codex",
                                          phase: .done, detail: "turn", durationMs: nil))
                case "turn_aborted":
                    out.append(AgentEvent(at: Date(), paneId: paneId, kind: "codex",
                                          phase: .idle, detail: "aborted", durationMs: nil))
                case let t?:
                    if let (phase, label) = Self.legacyPhaseFor[t] {
                        out.append(AgentEvent(at: Date(), paneId: paneId, kind: "codex",
                                              phase: phase, detail: label, durationMs: nil))
                    }
                default: break
                }
            case "response_item":
                if payload["type"] as? String == "custom_tool_call",
                   let name = payload["name"] as? String {
                    out.append(AgentEvent(at: Date(), paneId: paneId, kind: "codex",
                                          phase: .tool, detail: name, durationMs: nil))
                }
            default: break
            }
        }
        return out
    }

    private func resolve(cwd newCwd: String?) {
        if let forced { tailer.retarget(forced, fromEnd: fromEnd); return }
        guard let newCwd else { return }
        if newCwd == cwd && Date().timeIntervalSince(lastResolve) < 15 { return }
        cwd = newCwd
        lastResolve = Date()
        // sticky while live, for the same reason as ClaudeReader.resolve
        if let current = tailer.url,
           let mod = (try? FileManager.default.attributesOfItem(atPath: current.path)[.modificationDate]) as? Date,
           Date().timeIntervalSince(mod) < 30 {
            return
        }
        tailer.retarget(Self.newestRollout(cwd: newCwd))
    }

    /// Rollouts are filed by date, not by project, so the cwd lives inside the
    /// first line of each. Only recent files are opened, otherwise this walks
    /// every session the user has ever run.
    static func newestRollout(cwd: String) -> URL? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        // rollouts are filed YYYY/MM/DD; walking the whole tree re-stats every
        // session ever recorded, every 15 seconds. Visit only the day
        // directories that can contain a live session.
        let cal = Calendar.current
        let days = [Date(), Date().addingTimeInterval(-24 * 3600)].map {
            let c = cal.dateComponents([.year, .month, .day], from: $0)
            return root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        }
        let candidates = days.flatMap {
            (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var best: (URL, Date)?
        for url in candidates where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard mod > cutoff, mod > (best?.1 ?? .distantPast) else { continue }
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            let head = (try? fh.read(upToCount: 8192)) ?? Data()
            guard let nl = head.firstIndex(of: 0x0a),
                  let obj = try? JSONSerialization.jsonObject(
                    with: head[head.startIndex..<nl]) as? [String: Any],
                  let p = obj["payload"] as? [String: Any],
                  p["cwd"] as? String == cwd else { continue }
            best = (url, mod)
        }
        return best?.0
    }
}
