import Foundation

struct SessionSummary: Identifiable, Sendable {
    let id: String
    let directory: String
    let title: String?
    let snippet: String
    let isRecap: Bool
    let updatedAt: Date
    let resumeCommand: String
}

/// cwd があれば cd してから resume を実行するコマンドにする
func resumeCommand(cwd: String?, resume: String) -> String {
    guard let cwd else { return resume }
    return "cd \(shellQuote(cwd)) && \(resume)"
}

func shellQuote(_ s: String) -> String {
    if s.range(of: #"^[A-Za-z0-9_./~-]+$"#, options: .regularExpression) != nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum SessionStore {
    static let maxSessions = 10
    static let snippetLength = 60
    static let recapSuffix = " (disable recaps in /config)"

    static var projectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    }

    /// 最後のメッセージ（recap 含む）が新しい順に、表示できる内容を持つセッションを最大 maxSessions 件返す
    static func loadRecent() -> [SessionSummary] {
        topByActivity(recentFiles()) { summarize(url: $0) }
    }

    /// ファイルは会話がなくても書き換わる（mtime ではメッセージ順にならない）ので、各セッションの最終メッセージ時刻で並べる。
    /// 最終メッセージ時刻 ≤ 更新時刻 なので、更新時刻の新しい順に読み、上位 maxSessions 件が次の候補の更新時刻以上になったら打ち切る
    static func topByActivity<T>(_ candidates: [(T, Date)], summarize: (T) -> SessionSummary?) -> [SessionSummary] {
        var picked: [SessionSummary] = []
        for (candidate, modifiedAt) in candidates {
            if picked.count >= maxSessions, picked[maxSessions - 1].updatedAt >= modifiedAt { break }
            if let summary = summarize(candidate) {
                picked.append(summary)
                picked.sort { $0.updatedAt > $1.updatedAt }
            }
        }
        return Array(picked.prefix(maxSessions))
    }

    /// ~/.claude/projects/<project>/<session>.jsonl（深さ1のみ）を mtime 降順で返す
    static func recentFiles() -> [(URL, Date)] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for dir in projects {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((url, mtime))
            }
        }
        return files.sorted { $0.1 > $1.1 }
    }

    static func summarize(url: URL) -> SessionSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var cwd: String?
        var recap: (text: String, at: Date)?
        var message: (text: String, at: Date)?

        // 末尾から読み、最後のメッセージが見つかった時点で止める（それより前の recap は必ず古い）
        forEachLineReversed(data) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { return true }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            let at = (obj["timestamp"] as? String).flatMap(parseDate) ?? .distantPast

            switch type {
            case "system" where obj["subtype"] as? String == "away_summary" && recap == nil:
                if var text = obj["content"] as? String {
                    if text.hasSuffix(recapSuffix) { text.removeLast(recapSuffix.count) }
                    if !text.isEmpty { recap = (text, at) }
                }
            case "user", "assistant":
                if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true { break }
                if let text = messageText(obj) {
                    message = (text, at)
                    return false
                }
            default:
                break
            }
            return true
        }
        let customTitle = lastStringValue(in: data, key: "customTitle")
        let aiTitle = lastStringValue(in: data, key: "aiTitle")

        // recap と最後のメッセージのうち新しい方を出す
        let chosen: (text: String, isRecap: Bool, at: Date)
        switch (recap, message) {
        case let (r?, m?): chosen = r.at >= m.at ? (r.text, true, r.at) : (m.text, false, m.at)
        case let (r?, nil): chosen = (r.text, true, r.at)
        case let (nil, m?): chosen = (m.text, false, m.at)
        case (nil, nil): return nil
        }

        let directory = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? url.deletingLastPathComponent().lastPathComponent
        return SessionSummary(
            id: url.deletingPathExtension().lastPathComponent,
            directory: directory,
            title: customTitle ?? aiTitle,
            snippet: truncate(chosen.text),
            isRecap: chosen.isRecap,
            updatedAt: chosen.at,
            resumeCommand: resumeCommand(cwd: cwd, resume: "claude --dangerously-skip-permissions -r \(url.deletingPathExtension().lastPathComponent)")
        )
    }

    /// user/assistant レコードから人間が読むテキストだけを取り出す。tool_result・thinking・コマンド出力などは nil
    static func messageText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        var texts: [String] = []
        if let s = msg["content"] as? String {
            texts = [s]
        } else if let blocks = msg["content"] as? [[String: Any]] {
            texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let joined = texts.map(stripSystemReminders).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { return nil }
        // <command-name> / <task-notification> / <local-command-stdout> などハーネス由来のタグで始まるものは除外
        if isHarnessTagged(joined) { return nil }
        if joined.hasPrefix("[Request interrupted") { return nil }
        return joined
    }

    /// jsonl を末尾の行から順に渡す。body が false を返したら止める
    static func forEachLineReversed(_ data: Data, _ body: (Data) -> Bool) {
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[data.startIndex..<end].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
            if start < end, !body(data[start..<end]) { return }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
    }

    /// "key":"..." の最後の出現を含む行を JSON として読み、その値を返す（全行を解析せずにタイトルを拾う）
    static func lastStringValue(in data: Data, key: String) -> String? {
        guard let range = data.range(of: Data("\"\(key)\":\"".utf8), options: .backwards) else { return nil }
        let start = data[..<range.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
        let end = data[range.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
        guard let obj = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
              let value = obj[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func isHarnessTagged(_ s: String) -> Bool {
        s.range(of: #"^<[a-z][a-z_-]*[ >]"#, options: .regularExpression) != nil
    }

    static func stripSystemReminders(_ s: String) -> String {
        s.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
    }

    static func truncate(_ s: String) -> String {
        let flat = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > snippetLength ? String(flat.prefix(snippetLength)) + "…" : flat
    }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let isoFormatterNoFraction = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
    }
}
