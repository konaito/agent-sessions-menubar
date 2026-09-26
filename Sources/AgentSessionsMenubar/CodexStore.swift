import Foundation
import SQLite3

enum CodexStore {
    static var codexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    struct Thread {
        let id: String
        let rolloutPath: String
        let cwd: String
        let title: String
        let updatedAt: Date
    }

    /// 自分で話した CLI / Desktop のセッションを、最後のメッセージが新しい順に最大 maxSessions 件返す。
    /// DB を読めなかったときは nil（0 件とは区別し、呼び出し側は前回の一覧を残す）
    static func loadRecent() -> [SessionSummary]? {
        guard let threads = recentThreads() else { return nil }
        return SessionStore.topByActivity(threads.map { ($0, $0.updatedAt) }) { summarize($0) }
    }

    /// Codex が WAL を書き換えている瞬間は読み取り専用の接続が SQLITE_CANTOPEN などで一時的に失敗するので、少し待ってやり直す
    static func recentThreads() -> [Thread]? {
        for attempt in 0..<3 {
            if attempt > 0 { usleep(200_000) }
            if let threads = queryThreads() { return threads }
        }
        return nil
    }

    /// state_5.sqlite の threads から、アーカイブ・サブエージェント・exec・automation を除いて取る
    private static func queryThreads() -> [Thread]? {
        let path = codexURL.appending(path: "state_5.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, rollout_path, cwd, coalesce(nullif(name, ''), title), updated_at_ms
            FROM threads
            WHERE archived = 0
              AND source IN ('cli', 'vscode')
              AND coalesce(thread_source, '') != 'automation'
            ORDER BY updated_at_ms DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var threads: [Thread] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            defer { rc = sqlite3_step(stmt) }
            func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            threads.append(Thread(
                id: text(0),
                rolloutPath: text(1),
                cwd: text(2),
                title: text(3),
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000)
            ))
        }
        // 途中で失敗した場合も、欠けた一覧を返さない
        return rc == SQLITE_DONE ? threads : nil
    }

    static func summarize(_ thread: Thread) -> SessionSummary? {
        guard let last = lastMessage(rolloutPath: thread.rolloutPath) else { return nil }
        return SessionSummary(
            id: "codex-" + thread.id,
            directory: URL(fileURLWithPath: thread.cwd).lastPathComponent,
            title: thread.title.isEmpty ? nil : thread.title,
            snippet: SessionStore.truncate(last.text),
            isRecap: false,
            updatedAt: last.at,
            // フラグは付けない。alias codex="codex --yolo" のような環境で貼ると --yolo が二重になりエラーになるため
            resumeCommand: resumeCommand(cwd: thread.cwd.isEmpty ? nil : thread.cwd, resume: "codex resume \(thread.id)")
        )
    }

    /// rollout jsonl の最後の user/assistant テキスト。developer ロールやハーネス由来のタグ始まりは除外
    static func lastMessage(rolloutPath: String) -> (text: String, at: Date)? {
        guard let data = FileManager.default.contents(atPath: rolloutPath) else { return nil }
        var last: (text: String, at: Date)?
        // 末尾から読み、最初に見つかった表示できるメッセージで止める
        SessionStore.forEachLineReversed(data) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String, role == "user" || role == "assistant",
                  let blocks = payload["content"] as? [[String: Any]] else { return true }
            let joined = blocks
                .compactMap { ["input_text", "output_text"].contains($0["type"] as? String) ? $0["text"] as? String : nil }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if joined.isEmpty || SessionStore.isHarnessTagged(joined) { return true }
            let at = (obj["timestamp"] as? String).flatMap(SessionStore.parseDate) ?? .distantPast
            last = (joined, at)
            return false
        }
        return last
    }
}
