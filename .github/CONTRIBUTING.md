# Contributing to KIKUmap

Thanks for helping. Bug reports, ideas and pull requests are all welcome, and so are questions.

By taking part, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Report a bug

KIKUmap reads other apps (Claude, Claude Code, ChatGPT), so an update to one of them can break something. Reports like that are the most useful kind.

1. Check the [open issues](https://github.com/tang1693/KIKUmap/issues) first. Someone may have reported it already.
2. Open a **Bug report** and fill in the form: the KIKUmap and macOS versions, and what you saw.
3. Attach the diagnostic report if you can: **Settings → Access → Diagnostic report**. It contains no chat titles, messages or passwords.

Please leave out anything private: real chat titles, chat contents and account details. That goes for screenshots too.

**Security problems:** don't open a public issue. See the [security policy](SECURITY.md).

## Suggest a feature

Open a **Feature request**. Say what you want to do and why; a sketch or screenshot helps.

## Make a change

1. For anything bigger than a small fix, open an issue first, so we can agree on the approach before you spend time on it.
2. Build it locally:
   ```bash
   git clone https://github.com/tang1693/KIKUmap.git
   cd KIKUmap
   open Install.command
   ```
   `Install.command` builds with `swiftc` (Xcode Command Line Tools, Swift 5.10 or later), installs to `~/Applications` and signs with a local certificate, so permissions survive rebuilds.
3. Try your change in the real app: the menu bar, the map and whichever part you touched.
4. Open a pull request and fill in the template.

### Guidelines

- **No dependencies.** KIKUmap is plain Swift and AppKit (SwiftUI for the widget) with no third-party code. Please keep it that way.
- **Match the code around you:** its naming, comment style and structure. Small, focused pull requests are easiest to review.
- **Privacy first.** Nothing leaves the Mac unless the user turned on a feature that says so. Any new macOS permission is explained in the app before macOS asks for it.
- **Both languages.** Every visible string has English and Chinese (`tr("中文", "English")`).
- **Honest status.** When KIKUmap can't tell something (a window it can't read, a number from an earlier read), it says so instead of guessing.

## Project layout

| Where | What |
|---|---|
| `Sources/App.swift` | wiring, global shortcut, opening chats |
| `Sources/Watchers.swift` | Claude's sidebar and Notification Center readers |
| `Sources/ClaudeCode.swift` | Claude Code hooks and session names |
| `Sources/ChatGPT.swift`, `GPTUsage.swift` | ChatGPT (Codex) chats and usage |
| `Sources/Store.swift` | chats, read state, running time |
| `Sources/MapModel.swift`, `MapView.swift` | the mind map |
| `Sources/StatusBar.swift` | menu-bar icon and menu |
| `Sources/Usage.swift` | Claude usage and scheduled tasks |
| `Sources/Archive.swift`, `ClaudeExport.swift`, `ExportWindow.swift` | export and import |
| `Sources/WidgetFeed.swift`, `Widget/` | the desktop widget |
| `Sources/Settings.swift`, `Onboarding.swift` | settings, permissions, first-launch intro |
| `scripts/build-release.sh` | the universal disk image |

## License

Contributions are released under the project's [MIT License](../LICENSE).
