# agent-sessions-menubar

A tiny macOS menu bar app that shows where each of your recent **Claude Code** and **Codex** sessions left off, and copies the command to resume one with a single click.

<p align="center"><img src="docs/screenshot.png" width="680" alt="Popup with recent Claude Code sessions on the left and Codex sessions on the right"></p>

<p align="center"><sub>Sample data. Click a row to copy <code>cd &lt;project&gt; &amp;&amp; &lt;resume command&gt;</code>.</sub></p>

When you run many agent sessions in parallel, it is easy to lose track of which one was doing what. This app lists the 10 most recent sessions of each tool, side by side, with a one-glance summary of their current state.

## Features

- **Two columns**: Claude Code on the left, Codex on the right, 10 sessions each.
- **Header**: `<project directory> / <session title>`.
- **Summary line** (first 60 characters):
  - Claude Code: the session's **recap** (the "while you were away" summary) if it is newer than the last message, otherwise the last user/assistant message.
  - Codex: the last user/assistant message.
- **Ordered by the last message**, not by file modification time. Session files are rewritten even when nothing new was said, so mtime alone gives a misleading order.
- **Click to copy a resume command**, for example:
  - `cd /path/to/project && claude --dangerously-skip-permissions -r <session-id>`
  - `cd /path/to/project && codex resume <session-id>`
- Refreshes when the popup opens and every 30 seconds. Reading is fast (well under a second) because files are scanned from the end.
- Read-only: it never writes to `~/.claude` or `~/.codex`.

> [!WARNING]
> The copied Claude Code command includes `--dangerously-skip-permissions`, which starts the session **without permission prompts**. Only paste it if that is what you want. To change it, edit `resumeCommand` in `Sources/AgentSessionsMenubar/SessionStore.swift`.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16 or later, or the matching Command Line Tools)
- Claude Code and/or Codex CLI used on the same machine

## Install and run

```bash
git clone https://github.com/konaito/agent-sessions-menubar.git
cd agent-sessions-menubar
swift build -c release
.build/release/AgentSessionsMenubar &
```

A cloud icon appears in the menu bar. There is no Dock icon and no window.

To quit, run `pkill AgentSessionsMenubar`.

It does not start at login automatically. If you want that, add the binary to **System Settings → General → Login Items**, or create a LaunchAgent.

## Where the data comes from

| Tool | Session list | Title | Summary |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/<project>/<session>.jsonl` (top level only; subagent transcripts are ignored) | latest `custom-title` (set with `/rename`), else latest `ai-title` | latest `system`/`away_summary` record (recap), or the last `user`/`assistant` text |
| Codex | `threads` table in `~/.codex/state_5.sqlite` (CLI and Desktop threads; archived, subagent, `exec` and automation threads are excluded) | `name`, else `title` | last `user`/`assistant` `message` in the thread's rollout `.jsonl` |

Messages injected by the harness (for example `<system-reminder>`, `<command-name>`, `<environment_context>`, tool results, `developer` messages) are skipped.

These are **undocumented internal formats** of Claude Code and Codex. They may change in a future release and break this app.

## Development

```bash
swift build
.build/debug/AgentSessionsMenubar --dump           # print what the popup would show, plus resume commands
.build/debug/AgentSessionsMenubar --render out.png # render the popup view to a PNG
```

`docs/screenshot.png` is generated from built-in sample data, so no real sessions are shown:

```bash
.build/debug/AgentSessionsMenubar --render docs/screenshot.png --demo --dark
```

The project layout, data-format notes and verification steps are in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE)
