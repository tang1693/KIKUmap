# Security policy

## Supported versions

Only the [latest release](https://github.com/tang1693/KIKUmap/releases/latest) gets security fixes.

## Report a vulnerability

Please **don't open a public issue**. Report it privately instead: go to the repository's **Security** tab, choose **Report a vulnerability**, and describe:

- what the problem is and what it affects
- how to reproduce it (the KIKUmap and macOS versions help)
- any idea for a fix

You'll get a reply as soon as possible, usually within a week. Once a fix is released, the report can be made public, with credit to you if you want it.

## What's in scope

KIKUmap handles a few sensitive things, and these matter most:

- the Claude Code and Codex sign-ins it reads, when the optional usage features are on (they're read, never saved, and sent only to Anthropic's or OpenAI's own usage endpoints)
- the hooks it adds to `~/.claude/settings.json`
- the files it reads (Claude's notifications, `~/.codex`) and the data it keeps in `~/Library/Application Support/ClaudeConsole/`
- the `kikumap://` links the widget uses

Bugs in Claude, ChatGPT or macOS themselves should go to Anthropic, OpenAI or Apple.
