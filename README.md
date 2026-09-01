<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Vibe Notch</h3>
  <p align="center">
    A macOS app that shows live Claude Code session state in the MacBook notch,
    and lets you answer tool permission requests without switching to the terminal.
    <br />
    <br />
    <a href="https://github.com/BogdanTaranenko/vibe-notch/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/BogdanTaranenko/vibe-notch?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="https://github.com/BogdanTaranenko/vibe-notch/releases" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/BogdanTaranenko/vibe-notch/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

> This is a fork of [farouqaldori/vibe-notch](https://github.com/farouqaldori/vibe-notch)
> (previously Claude Island) and has diverged from it. Releases, automatic updates
> and issues for this build are served from this repository.

## Features

- **Notch overlay** — Expands from the MacBook notch and collapses out of the way. While closed it passes clicks through to the menu bar underneath.
- **Live session monitoring** — Each running Claude Code session gets its own indicator in the collapsed notch. Open one to see whether it is working, waiting for input, waiting for an approval, or compacting.
- **Permission approvals** — Approve or deny a tool call from the notch. If nothing answers within five minutes, the request falls through to Claude Code's own terminal prompt, so a request is never left stuck.
- **Auto-approve rules** — Turn a single approval into a standing answer for one project. Read-only tools can be allowed for any input that stays inside the project; everything else is matched against the exact arguments. Rules are kept in the app, so removing one takes effect immediately.
- **Context and cost** — A per-session bar for how full the model's context window is, plus an estimate of what the session has cost at list API prices.
- **Chat history** — The full conversation with markdown rendering, and tool results formatted per tool.
- **Health checks** — A panel that names which link in the chain is broken — Claude directory, `settings.json`, hook script, Python, Claude Code, socket, Accessibility, event flow — and what to do about each one.
- **Terminal focus** — Jump back to the terminal window a session came from, including the right tmux pane. Optional; it does nothing if the supporting tools are not installed.
- **Automatic setup** — Hooks are installed on first launch and kept current, registering only the hook events your installed Claude Code understands.
- **Automatic updates** — Signed updates delivered through Sparkle.

## Requirements

- macOS 15.6 or later
- Claude Code CLI
- Python 3, used by the hook script (`xcode-select --install` provides it)
- Accessibility permission, granted on first launch — the notch detects hover and clicks through global event monitors

## Install

Download the latest DMG from [Releases](https://github.com/BogdanTaranenko/vibe-notch/releases/latest),
open it, and drag Vibe Notch to Applications. Builds are signed with a Developer ID
and notarized by Apple. After that the app updates itself.

To build from source instead:

```bash
git clone https://github.com/BogdanTaranenko/vibe-notch.git
cd vibe-notch
xcodebuild -scheme ClaudeIsland -configuration Release build
```

The Xcode target, scheme and source directory are named `ClaudeIsland` for
historical reasons; the product that ships is Vibe Notch.

## How it works

Claude Code exposes no API for any of this, so the app assembles session state
from two sources.

**Hooks** tell it when something happened. On launch the app copies a hook script
into your Claude directory and registers it in `settings.json`. The script reports
each event over a local Unix socket, which is what makes the notch react
immediately.

**Transcripts** tell it what happened. The app incrementally reads the session
files Claude Code writes to disk, which is where the conversation text, tool
inputs and results, and token counts come from.

Permission requests are the one case that blocks. The hook holds the socket open
and waits for an answer; the app writes the decision back on the same connection.
No answer means Claude Code asks in the terminal as usual.

## Settings

Open the notch and choose the menu:

| Setting | What it does |
| --- | --- |
| Screen | Which display the notch appears on |
| Notification Sound | Played when a session becomes ready for input |
| Claude Directory | For non-default installs. `CLAUDE_CONFIG_DIR` is honoured first |
| Auto-approve | Review and remove standing approvals |
| Health | The diagnostic panel |
| Launch at Login | Start Vibe Notch with the system |
| Hooks | Install or remove the hook integration |

## Development

```bash
# Debug build
xcodebuild -scheme ClaudeIsland -configuration Debug build

# Tests
xcodebuild test -scheme ClaudeIsland -destination 'platform=macOS'
```

The test bundle runs without launching the app, so a test run never rewrites your
own Claude configuration. Coverage sits where a mistake would be silent or hard to
undo: the `settings.json` rewrite, locating the `claude` binary, the session phase
state machine, auto-approve rule matching, the health report, and the cost and
context meters. GitHub Actions runs the tests and a Release build on every push
and pull request.

## Analytics

Vibe Notch reports usage data through Mixpanel. Two events are sent:

- **App Launched** — once per launch
- **Session Started** — when a new Claude Code session is detected

Each carries the app version, build number and macOS version, plus the installed
Claude Code version once it has been detected. Events are attributed to a
per-machine identifier derived from the hardware UUID, so they are not tied to a
name or an account.

No conversation content, project paths, or file contents are collected.

## License

Apache 2.0. See [LICENSE.md](LICENSE.md). The original work is
copyright 2025 Farouq Aldori.
