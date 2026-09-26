# AGENTS.md

Guidance for coding agents (and humans) working on this repository.

## What this is

A SwiftUI `MenuBarExtra` app with no Xcode project, built with SwiftPM. It reads Claude Code and Codex session data read-only and shows the 10 most recent sessions of each tool side by side. Clicking a row copies a `cd … && <resume>` command.

## Layout

```
Package.swift
Sources/AgentSessionsMenubar/
  AgentSessionsMenubarApp.swift  # @main, MenuBarExtra, SessionListModel (reload), SessionListView, --dump/--render
  SessionStore.swift             # Claude Code: ~/.claude/projects/*/*.jsonl, plus shared helpers (topByActivity, reverse line scan, truncate)
  CodexStore.swift               # Codex: ~/.codex/state_5.sqlite threads + rollout jsonl
```

`SessionSummary` is the shared row model. `resumeCommand` is built by each store.

## Build and verify

```bash
swift build                                         # must pass with no errors
.build/debug/AgentSessionsMenubar --dump            # text output of both columns, with timestamps and resume commands
.build/debug/AgentSessionsMenubar --render out.png  # PNG of the popup view; open it and look at it
```

There is no test target. Verify changes like this:

1. **Data changes** (parsing, filtering, ordering): compare the `--dump` output with an independent query over the same files, for example `jq` over the jsonl or `sqlite3` over `state_5.sqlite`. Check the full candidate set, not a single sample session; session files vary a lot.
2. **UI changes**: run `--render` and look at the PNG. Wrapping, truncation and spacing cannot be checked by grep or by a passing build.
3. **Popup behavior** (open/refresh/size): only the real menu bar popup shows this. Say explicitly when you could not check it.

## Data format notes (undocumented, may change)

Claude Code (`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, one JSON object per line):

- The project directory name is a lossy encoding of the cwd. Use the `cwd` field of the records instead.
- Recap: `{"type":"system","subtype":"away_summary","content":"… (disable recaps in /config)"}`. Strip the trailing suffix.
- Titles: `{"type":"custom-title","customTitle":…}` (from `/rename`) takes priority over `{"type":"ai-title","aiTitle":…}`. They can appear anywhere in the file.
- Messages: `type` `user`/`assistant`. `message.content` is either a string or an array of blocks; only `text` blocks count. Skip `isSidechain`, `isMeta`, text that starts with a harness tag (`<command-name>`, `<task-notification>`, …), and `[Request interrupted…`. Remove `<system-reminder>…</system-reminder>`.
- `timestamp` has fractional seconds. `ISO8601DateFormatter` needs `.withFractionalSeconds`, or it silently returns nil.

Codex:

- `~/.codex/state_5.sqlite`, table `threads`: `id`, `rollout_path`, `cwd`, `name`/`title`, `updated_at_ms`, `archived`, `source` (`cli`, `vscode` = Desktop, `exec`, or JSON for subagents), and `thread_source` (`automation`, …).
- Rollout jsonl: messages are `{"type":"response_item","payload":{"type":"message","role":…,"content":[{"type":"input_text"|"output_text","text":…}]}}`. Skip the `developer` role and tag-prefixed text such as `<environment_context>` (it may have leading whitespace).

## Invariants and pitfalls

- **Order by the last message time, not by mtime or `updated_at_ms`.** Files are rewritten without new messages. `SessionStore.topByActivity` relies on *last message time ≤ file modification time*. It reads candidates in mtime order and stops once the current top 10 are all newer than the next candidate's mtime. Keep that early stop, or loading becomes several seconds.
- **Scan jsonl from the end** (`forEachLineReversed`) and stop at the first displayable message. Parsing whole transcripts is slow because tool results are large. Titles are found by a backwards byte search (`lastStringValue`) instead of parsing every line.
- **`MenuBarExtra(.window)` sizing**: the window takes the content's ideal size. A `ScrollView` has none and collapses to zero height, so the popup is not scrollable by design. Keep the content bounded instead (10 rows, 60-character summaries).
- **Refreshing**: the `.window` style keeps the view alive between openings, so `onAppear` is not a reliable "opened" signal. Reload on `NSWindow.didBecomeKeyNotification`, and on the 30-second timer as a fallback.
- `ImageRenderer` (used by `--render`) does not draw `ScrollView` contents.
- Resume commands: `codex resume <id>` is deliberately left without flags. A user alias such as `codex="codex --yolo"` would otherwise pass `--yolo` twice, which is an error.
- Never write to `~/.claude` or `~/.codex`. This app is read-only.

## Style

- Match the surrounding code. Comments are sparse and explain *why*.
- Keep dependencies at zero: Foundation, SwiftUI, AppKit and the system SQLite3 only.
