import AppKit
import SwiftUI

enum Tool: Hashable, Sendable {
    case claude, codex
}

@MainActor
final class SessionListModel: ObservableObject {
    @Published var claude: [SessionSummary] = []
    @Published var codex: [SessionSummary] = []
    @Published var claudeUsage: Usage?
    @Published var codexUsage: Usage?
    /// 更新ボタンを押されて、まだ取り直しが終わっていない列
    @Published var refreshing: Set<Tool> = []
    private var loading = false
    private var pendingForce: Set<Tool> = []
    private var usageFetchedAt: [Tool: Date] = [:]
    private var timer: Timer?

    init(autoReload: Bool = true) {
        guard autoReload else { return }
        // 開いた検知を取りこぼしても古くなりすぎないように定期的にも読み直す
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    /// 更新ボタン: その列の使用量を 5 分の間隔を無視して取り直し、一覧も読み直す
    func refresh(_ tool: Tool) {
        refreshing.insert(tool)
        reload(force: [tool])
    }

    /// 一覧を読んでから、必要なら使用量を取る。
    /// codex app-server の起動と Codex の DB 読み込みが同じプロセス内で重なると DB が SQLITE_CANTOPEN になるので、
    /// 両者は必ず順番に行い、終わるまで次の読み直しを始めない（その間に来た強制更新は終わってから続けて行う）。
    /// 使用量はネットワークや codex の起動を伴うので、一覧（30 秒ごと）とは別に 5 分に 1 回までにする
    func reload(force: Set<Tool> = []) {
        guard !loading else {
            pendingForce.formUnion(force)
            return
        }
        loading = true
        let now = Date()
        let usageTools = Set([Tool.claude, .codex].filter {
            force.contains($0) || now.timeIntervalSince(usageFetchedAt[$0] ?? .distantPast) >= 5 * 60
        })
        Task.detached(priority: .userInitiated) {
            let claude = SessionStore.loadRecent()
            let codex = CodexStore.loadRecent()
            await MainActor.run {
                self.claude = claude
                if let codex { self.codex = codex }
            }
            if usageTools.contains(.claude) {
                let usage = await ClaudeUsage.fetch()
                await MainActor.run {
                    self.claudeUsage = usage
                    self.usageFetchedAt[.claude] = Date()
                }
            }
            if usageTools.contains(.codex) {
                let usage = await CodexUsage.fetch()
                await MainActor.run {
                    self.codexUsage = usage
                    self.usageFetchedAt[.codex] = Date()
                }
            }
            await MainActor.run {
                self.loading = false
                self.refreshing.subtract(force)
                if !self.pendingForce.isEmpty {
                    let next = self.pendingForce
                    self.pendingForce = []
                    self.reload(force: next)
                }
            }
        }
    }
}

struct SessionListView: View {
    @ObservedObject var model: SessionListModel
    @State private var copiedID: String?

    private func copy(_ session: SessionSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.resumeCommand, forType: .string)
        copiedID = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == session.id { copiedID = nil }
        }
    }

    var body: some View {
        sections
            .frame(width: 680, alignment: .leading)
            .onAppear { model.reload() }
            // .window スタイルは閉じても View が残り onAppear が初回しか来ないので、ポップアップが前面に来たときにも読み直す
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                model.reload()
            }
    }

    private var sections: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) { section("ClaudeCode", .claude, model.claude, usage: model.claudeUsage) }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 10) { section("Codex", .codex, model.codex, usage: model.codexUsage) }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(_ name: String, _ tool: Tool, _ sessions: [SessionSummary], usage: Usage?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // 取得中はくるくるに差し替える。見出しの高さが変わるとポップアップの角丸が崩れるので枠は固定
            ZStack {
                if model.refreshing.contains(tool) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { model.refresh(tool) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("\(name) の使用量とセッションを取り直す")
                }
            }
            .frame(width: 14, height: 14)
            Text(name)
                .font(.system(size: 15, weight: .semibold))
            Text(usage?.label ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        if sessions.isEmpty {
            Text("セッションがありません")
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
        ForEach(sessions) { session in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(session.directory).fontWeight(.medium)
                        if let title = session.title {
                            Text("/").foregroundStyle(.tertiary)
                            Text(title).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                    Text(copiedID == session.id ? session.resumeCommand : session.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(copiedID == session.id ? .tertiary : .secondary)
                        // 表示中に高さが変わるとポップアップの角丸が崩れるので、本文は常に3行分の高さを確保する
                        .lineLimit(3, reservesSpace: true)
                        .padding(.leading, 8)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { copy(session) }
                .help(session.resumeCommand)
        }
    }
}

@main
struct AgentSessionsMenubarApp: App {
    @StateObject private var model = SessionListModel()

    init() {
        if CommandLine.arguments.contains("--dump") {
            let (claude, codex) = Self.fetchUsageBlocking()
            print("usage: ClaudeCode \(claude?.label ?? "unavailable") / Codex \(codex?.label ?? "unavailable")")
            for s in SessionStore.loadRecent() + (CodexStore.loadRecent() ?? []) {
                print("\(s.updatedAt.formatted(date: .numeric, time: .shortened)) \(s.directory) / \(s.title ?? "-") [\(s.isRecap ? "recap" : "msg")] \(s.snippet)\n    \(s.resumeCommand)")
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            // 検証用: ポップアップと同じ View を PNG に書き出す。--demo は架空データ、--dark はダークのポップアップ風の見た目
            MainActor.assumeIsolated {
                let args = CommandLine.arguments
                let m = SessionListModel(autoReload: false)
                m.claude = args.contains("--demo") ? DemoData.claude : SessionStore.loadRecent()
                m.codex = args.contains("--demo") ? DemoData.codex : (CodexStore.loadRecent() ?? [])
                (m.claudeUsage, m.codexUsage) = args.contains("--demo") ? (DemoData.claudeUsage, DemoData.codexUsage) : Self.fetchUsageBlocking()
                let dark = args.contains("--dark")
                let content = SessionListView(model: m)
                    .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: dark ? 12 : 0))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
            }
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// --dump / --render 用。起動直後の同期処理から使用量を取る
    nonisolated static func fetchUsageBlocking() -> (Usage?, Usage?) {
        nonisolated(unsafe) var result: (Usage?, Usage?) = (nil, nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result = (await ClaudeUsage.fetch(), await CodexUsage.fetch())
            done.signal()
        }
        done.wait()
        return result
    }

    var body: some Scene {
        MenuBarExtra("ClaudeCode", systemImage: "cloud.fill") {
            SessionListView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
