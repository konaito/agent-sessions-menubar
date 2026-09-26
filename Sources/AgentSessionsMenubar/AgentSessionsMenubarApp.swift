import AppKit
import SwiftUI

@MainActor
final class SessionListModel: ObservableObject {
    @Published var claude: [SessionSummary] = []
    @Published var codex: [SessionSummary] = []
    private var loading = false
    private var timer: Timer?

    init() {
        // 開いた検知を取りこぼしても古くなりすぎないように定期的にも読み直す
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func reload() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let claude = SessionStore.loadRecent()
            let codex = CodexStore.loadRecent()
            await MainActor.run {
                self.claude = claude
                self.codex = codex
                self.loading = false
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
            VStack(alignment: .leading, spacing: 10) { section("ClaudeCode", model.claude) }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 10) { section("Codex", model.codex) }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(_ name: String, _ sessions: [SessionSummary]) -> some View {
        Text(name)
            .font(.system(size: 15, weight: .semibold))
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
            for s in SessionStore.loadRecent() + CodexStore.loadRecent() {
                print("\(s.updatedAt.formatted(date: .numeric, time: .shortened)) \(s.directory) / \(s.title ?? "-") [\(s.isRecap ? "recap" : "msg")] \(s.snippet)\n    \(s.resumeCommand)")
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            // 検証用: ポップアップと同じ View を PNG に書き出す。--demo は架空データ、--dark はダークのポップアップ風の見た目
            MainActor.assumeIsolated {
                let args = CommandLine.arguments
                let m = SessionListModel()
                m.claude = args.contains("--demo") ? DemoData.claude : SessionStore.loadRecent()
                m.codex = args.contains("--demo") ? DemoData.codex : CodexStore.loadRecent()
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

    var body: some Scene {
        MenuBarExtra("ClaudeCode", systemImage: "cloud.fill") {
            SessionListView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
