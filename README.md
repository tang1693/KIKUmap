<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.png">
  <img src="docs/banner-en-light.png" width="100%" alt="KIKUmap: a mind map for your Claude and ChatGPT chats">
</picture>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">A mind map for your Claude and ChatGPT chats, in the Mac menu bar.<br>See what's running, what's done and what needs you.</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-en.svg" height="56" alt="Download KIKUmap for macOS"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=version&color=187DFE" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift, no dependencies">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="MIT license"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="GitHub stars"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white" alt="Support on Ko-fi"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/">Website</a> ·
  <a href="#features">Features</a> ·
  <a href="#install">Install</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="#support">Support ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="Dragging the Work topic across the map: the other topics slide apart to make room, and it lands where the gap was"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/#tour"><img src="docs/demo/intro-poster.jpg" width="100%" alt="Watch the KIKUmap tour"></a></p>

## Features

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="The menu-bar icon counting running chats in a turning ring, then a red unread badge, then an exclamation mark when a chat needs approval"></td>
<td>

### 1. Status in the menu bar
A ring counts running chats. A red badge counts finished, unread ones, with **!** when one needs approval. An optional sound or voice says which chat is done.

</td>
</tr>
<tr>
<td>

### 2. Chats as a map
Chats pinned in Claude and in the ChatGPT app, plus Claude Code sessions, line up in the left column. Drag them onto your own topics. Each chat is tagged **Claude** or **GPT**.

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="Selecting three chats and dragging them onto Side projects together"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="Clicking the In progress tag highlights the chats that have it; the tag is then dragged onto a chat"></td>
<td>

### 3. Colours, shapes and tags
Give a topic a colour and a shape. Tag chats, and click a tag to highlight every chat that has it. Drag the top edge of the tags to make them taller or shorter, or tuck them away (⌃⌘G). In a short window zoomed in, they step aside until there's room: make the window taller or press ⌘-.

</td>
</tr>
<tr>
<td>

### 4. Keyboard-first
⇥ subtopic · ⏎ sibling · ⌥↑↓ move · ⌘Z undo · ⌘F search · space opens a chat.

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab adds a subtopic, Return adds a sibling, Option-Up moves it, Command-Z undoes"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="The timeline: past runs with their times, and scheduled tasks with countdowns"></td>
<td>

### 5. Timeline
When each chat ran, and the scheduled tasks coming up, with countdowns.

</td>
</tr>
<tr>
<td>

### 6. Export and import
Each chat as files: a summary, prompts, the conversation and artifacts. Import them into another Claude account.

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="The export window and the folder of Markdown files and artifacts it writes"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget.png" width="100%" alt="KIKUmap widgets in three sizes: time worked in the last 24 hours, usage, and in the large one the busiest chats and the last 7 days"></td>
<td>

### 7. Desktop widget
Time worked in the last 24 hours and the last 7 days, plus Claude and ChatGPT usage with plan names. Three sizes, macOS 14 or later.

</td>
</tr>
<tr>
<td>

### 8. Statistics
Time per chat over 7, 14, 30 or 90 days. ⌘Y.

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="Statistics: time per chat in bars over seven days"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="Finished chats light up"><br><b>Finished chats light up</b> on the map.</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="Search"><br><b>Search</b> topics, chats and tags.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="Today in the menu"><br><b>Today</b>: which chats worked, and how long.</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="Usage in the menu"><br><b>Usage</b> for the session and the week.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="The map as a PDF"><br><b>PDF</b> of the whole map.</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="Daily backups"><br><b>Daily backups</b> of the map.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="Light or dark"><br><b>Light or dark.</b></td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="English and Chinese"><br><b>English · 中文.</b></td>
</tr>
</table>

**Works with:** the Claude desktop app · Claude Code (Terminal, VS Code, Cursor, the app's Code mode) · the ChatGPT desktop app · Codex in VS Code or the terminal.

**Native and light:** Swift and AppKit only. No Electron, no web view, no third-party code (line icons from [Lucide](https://lucide.dev), ISC).

## Install

1. [Download Kikumap.dmg](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg) (macOS 13 or later, Apple silicon and Intel) and drag KIKUmap to Applications.
2. On first launch, macOS can't check the app (it isn't notarized). Click **Done**, then **System Settings → Privacy & Security → Open Anyway**.
3. Allow **Accessibility** when the intro asks. Everything else is optional.
4. Pin chats in Claude or ChatGPT to follow them.

<details>
<summary>Build from source</summary>

Needs the Xcode Command Line Tools.

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command` builds with `swiftc`, installs to `~/Applications` and signs with a local certificate, so permissions survive rebuilds. `scripts/build-release.sh` builds the disk image.
</details>

## Privacy

- Everything stays on the Mac, in `~/Library/Application Support/ClaudeConsole/`.
- One permission is required: **Accessibility**, to read the chat lists in the Claude and ChatGPT windows. Every permission is explained before macOS asks.
- No network requests, except the optional usage lookups (off by default) to Anthropic and OpenAI. Those read the sign-ins Claude Code and Codex already keep on the Mac, and never save them. Neither company has said apps may do this, so these lookups could be blocked.

<details>
<summary>What each source and permission is for</summary>

| Shows | Comes from | Permission |
|---|---|---|
| Running, unread, pinned Claude chats | The Claude app's sidebar | Accessibility |
| Approval requests and finished Cowork tasks, also with Claude's window closed (optional) | Claude's notifications in Notification Center | Full Disk Access |
| Claude Code sessions | Claude Code hooks in `~/.claude/settings.json` (backed up first) | none |
| ChatGPT chats | The ChatGPT app's files in `~/.codex` (read-only) | none |
| Running, done and unread for ordinary ChatGPT chats (not Codex) | The sidebar in ChatGPT's window, while part of the window can be seen | Accessibility |
| Desktop widget | One file KIKUmap writes for it (`widget.json`) | none |
| Claude usage and scheduled tasks (optional) | Anthropic's usage API, with Claude Code's sign-in | Keychain |
| ChatGPT usage (optional, experimental) | OpenAI's usage interface, with Codex's sign-in | none |

ChatGPT: Codex chats are supported best (read from the app's files, right even with its window closed). Ordinary chats are supported less well: they're read off ChatGPT's window, only while part of it shows.

Not shown: unpinned chats, and anything running on another computer, a server or in the cloud.
</details>

<details>
<summary>All keyboard shortcuts</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | new child / new parent topic |
| ⏎ / ⌥⏎ / ⇧⏎ | new sibling below / above / new main topic |
| ⌘⏎, double-click | rename |
| ⌫ / ⌥⌫ | delete (pinned chats stay in the left column) / delete just the topic, keeping its items (also with several selected) |
| ⌥. | fold / unfold |
| ↑ ↓ ← → | select the nearest item that way |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | move up or down / move a level |
| ⌘↓, tap space | open the chat in its app |
| ⌘↑ | up to the topic it's in |
| drag on empty space, ⇧/⌘-click | select several |
| hold space, two-finger swipe | move around the map |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | left column / tags / timeline |
| ↑ ↓ in the left column | pick the row above or below (the map selects its chat too) |
| ⏎, space in the left column | open the chat in its app |
| ⌘Y | statistics |
| ⌘R | refresh |
| ⌘Z / ⇧⌘Z | undo / redo |
| ⌘F | search |
| ⌘E / ⇧⌘E | map as PDF / export chats |
| ⇧⌘U | mark unread / read |
| ⌘+ / ⌘- / pinch / ⌘0 | bigger / smaller / zoom / fit |
| ⌃⌥C (changeable, but not to KIKUmap's own ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H) | show or hide the map from anywhere |
</details>

## FAQ

<details>
<summary><b>Is this made by Anthropic or OpenAI?</b></summary>

No. KIKUmap is an independent, open-source project. The Claude app has no public API, so KIKUmap reads its window through Accessibility; an update to Claude or ChatGPT can break parts of it until KIKUmap catches up.
</details>

<details>
<summary><b>Why "Open Anyway"?</b></summary>

Notarizing needs a paid Apple developer account, and KIKUmap is free. Building from source works too: plain Swift, no dependencies.
</details>

<details>
<summary><b>Claude's window is closed. What happens?</b></summary>

⌘W only hides it. KIKUmap reads Claude's chats from the window, so it can't see them until the window is back on the current desktop; meanwhile running chats show "running?". Claude Code and Codex chats aren't affected. ChatGPT's ordinary chats are read from ChatGPT's window the same way, while part of it can be seen.
</details>

<details>
<summary><b>Something isn't showing</b></summary>

- **▸ To-do** in the top bar lists what's missing, with a button for each.
- Claude chats: pin them, and keep Claude's sidebar open on Chat with Pinned unfolded.
- Claude Code: Settings → Access → Claude Code → **Connect**, then start a new session.
- Widget: macOS 14 or later, with KIKUmap in Applications. Right-click the desktop → **Edit Widgets**.
- Still stuck: Settings → Access → **Diagnostic report** (no chat titles or messages in it) and [open an issue](https://github.com/tang1693/KIKUmap/issues).
</details>

<details>
<summary><b>Why the name?</b></summary>

*Kiku* (菊) is Japanese for chrysanthemum: the little flower in the menu bar.
</details>

## Contributing

Issues and pull requests are welcome, especially when a Claude or ChatGPT update breaks something. See the [contributing guide](.github/CONTRIBUTING.md) and the [code of conduct](.github/CODE_OF_CONDUCT.md); security problems go through the [security policy](.github/SECURITY.md).

## Support

KIKUmap is free. If it helps, a coffee keeps it going ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-en.svg" height="64" alt="Buy me a coffee on Ko-fi"></a></p>

## License

[MIT](LICENSE). Claude is a trademark of Anthropic and ChatGPT a trademark of OpenAI; this project is independent and not endorsed by either.
