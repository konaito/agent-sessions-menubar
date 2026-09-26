import Foundation

/// 見出しの横に出す使用率（0〜100）。取れなかった枠は nil
struct Usage: Sendable, Equatable {
    var weekly: Double?
    var session: Double?

    var label: String {
        var parts: [String] = []
        if let weekly { parts.append("\(Int(weekly.rounded()))%/1W") }
        if let session { parts.append("\(Int(session.rounded()))%/5H") }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }
}

enum ClaudeUsage {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Claude Code が Keychain に保存している OAuth トークンで usage エンドポイントを叩く
    static func fetch() async -> Usage? {
        guard let token = readAccessToken() else { return nil }
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // limits が現行の表現。five_hour / seven_day は後方互換のミラーなのでフォールバックにだけ使う
        var usage = Usage()
        for limit in obj["limits"] as? [[String: Any]] ?? [] {
            let percent = (limit["percent"] as? NSNumber)?.doubleValue
            switch limit["kind"] as? String {
            case "weekly_all": usage.weekly = percent
            case "session": usage.session = percent
            default: break
            }
        }
        func utilization(_ key: String) -> Double? {
            ((obj[key] as? [String: Any])?["utilization"] as? NSNumber)?.doubleValue
        }
        usage.weekly = usage.weekly ?? utilization("seven_day")
        usage.session = usage.session ?? utilization("five_hour")
        return usage
    }

    /// Bearer トークンがリダイレクト先に送られないよう、リダイレクトを追わないセッションを使う
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func readAccessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (obj["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String,
              !token.isEmpty else { return nil }
        return token
    }
}

enum CodexUsage {
    /// `codex app-server` に JSON-RPC（改行区切り）で account/rateLimits/read を問い合わせる
    static func fetch() async -> Usage? {
        guard let codex = codexPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { if process.isRunning { process.terminate() } }

        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-sessions-menubar","version":"0"},"capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#,
        ]
        input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))

        // 応答が来ない場合に読み込みで固まらないよう、10 秒で打ち切る
        let reader = Task.detached { () -> Data? in
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       obj["id"] as? Int == 2 {
                        return Data(line)
                    }
                }
            }
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(10)); process.terminate() }
        let line = await reader.value
        timeout.cancel()

        guard let line,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let limits = (obj["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return nil }
        // 枠の長さで週次と 5 時間枠を見分ける（primary / secondary の役割はプランで変わる）
        var usage = Usage()
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let percent = (window["usedPercent"] as? NSNumber)?.doubleValue,
                  let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue else { continue }
            if minutes >= 7 * 24 * 60 { usage.weekly = percent } else if minutes <= 5 * 60 { usage.session = percent }
        }
        return usage
    }

    /// GUI アプリは PATH を継がないので、よくある場所を探し、なければログインシェルに聞く
    private static func codexPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        // alias ではなく実体のパスがほしいので command -v ではなく whence -p / type -P 相当を使う
        process.arguments = ["-lc", "whence -p codex 2>/dev/null || type -P codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
