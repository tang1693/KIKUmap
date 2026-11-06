<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-zh-dark.png">
  <img src="docs/banner-zh-light.png" width="100%" alt="KIKUmap：给 Claude 和 ChatGPT 对话的思维导图">
</picture>

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

<p align="center">住在 Mac 菜单栏里的思维导图，管理 Claude 和 ChatGPT 的对话。<br>哪个在跑、哪个做完了、哪个在等你，一眼就知道。</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-zh.svg" height="56" alt="下载 KIKUmap macOS 版"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=%E7%89%88%E6%9C%AC&color=187DFE" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 及以上">
  <img src="https://img.shields.io/badge/Swift-%E9%9B%B6%E4%BE%9D%E8%B5%96-F05138?logo=swift&logoColor=white" alt="Swift，零依赖">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="MIT 协议"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="GitHub stars"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-%E8%AF%B7%E6%88%91%E5%96%9D%E5%92%96%E5%95%A1-FF5E5B?logo=kofi&logoColor=white" alt="在 Ko-fi 支持"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/?lang=zh">官网</a> ·
  <a href="#功能">功能</a> ·
  <a href="#安装">安装</a> ·
  <a href="#隐私">隐私</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="#支持">支持 ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="把 Work 主题拖过导图：其他主题让开空出位置，松手后落进空位"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/?lang=zh#tour"><img src="docs/demo/intro-poster-zh.jpg" width="100%" alt="观看 KIKUmap 介绍视频"></a></p>

## 功能

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="菜单栏图标：转动的圆环数着在跑的对话，然后出现红色未读角标，有对话等批准时加上感叹号"></td>
<td>

### 1. 菜单栏看状态
圆环里是在跑的对话数；红色角标是做完还没看的对话数，有对话等你批准时带 **!**。可以开提示音，或者用语音说出是哪个对话做完了。

</td>
</tr>
<tr>
<td>

### 2. 对话变成导图
Claude 和 ChatGPT App 里置顶的对话、Claude Code 会话，都会列在左栏。把它们拖到自己的主题下。每个对话都标着 **Claude** 或 **GPT**。

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="选中三个对话，一起拖到 Side projects 下"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="点「进行中」标签，高亮带这个标签的对话；再把标签拖到一个对话上"></td>
<td>

### 3. 颜色、形状、标签
给主题设颜色和形状。给对话打标签，点一下标签就高亮所有带它的对话。拖动标签区的上边可以调高度，也可以整个收起（⌃⌘G）。窗口太矮又放大时放不下，标签区会先让开：把窗口拉高，或按 ⌘- 缩小。

</td>
</tr>
<tr>
<td>

### 4. 键盘就能搞定
⇥ 子主题 · ⏎ 同级 · ⌥↑↓ 移动 · ⌘Z 撤销 · ⌘F 搜索 · 空格打开对话。

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab 加子主题，回车加同级，Option-上移动，Command-Z 撤销"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="时间轴：过去的运行和时间，以及带倒计时的定时任务"></td>
<td>

### 5. 时间轴
每个对话什么时候在跑，接下来有哪些定时任务，带倒计时。

</td>
</tr>
<tr>
<td>

### 6. 导出和导入
每个对话导出成文件：总结、提示词、完整对话和产出物。也能导入到另一个 Claude 账号。

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="导出窗口，以及导出的 Markdown 文件和产出物文件夹"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget-zh.png" width="100%" alt="三种尺寸的 KIKUmap 小组件：最近 24 小时的工作时长、用量；大号还有用时最多的对话和最近 7 天"></td>
<td>

### 7. 桌面小组件
最近 24 小时和最近 7 天的工作时长，以及 Claude、ChatGPT 的用量和套餐名。三种尺寸，需要 macOS 14 及以上。

</td>
</tr>
<tr>
<td>

### 8. 统计
每个对话的用时，可以看 7、14、30 或 90 天。⌘Y。

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="统计：七天里每个对话用时的柱状图"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="做完的对话会亮起"><br><b>做完的对话</b>会在导图上亮起。</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="搜索"><br><b>搜索</b>主题、对话和标签。</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="菜单里的今天"><br><b>今天</b>哪些对话干了活、干了多久。</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="菜单里的用量"><br>当前会话和本周的<b>用量</b>。</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="导出 PDF"><br>整张导图导出 <b>PDF</b>。</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="每日备份"><br>导图<b>每日备份</b>。</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="浅色或深色"><br><b>浅色、深色</b>都有。</td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="中文和英文"><br><b>中文 · English。</b></td>
</tr>
</table>

**支持：** Claude 桌面 App · Claude Code（终端、VS Code、Cursor、App 里的 Code 模式）· ChatGPT 桌面 App · VS Code 或终端里的 Codex。

**原生、轻量：** 纯 Swift + AppKit。没有 Electron，没有网页套壳，没有第三方代码（线条图标来自 [Lucide](https://lucide.dev)，ISC 许可）。

## 安装

1. [下载 Kikumap.dmg](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg)（macOS 13 及以上，Apple 芯片和 Intel 都支持），把 KIKUmap 拖到「应用程序」。
2. 第一次打开时，macOS 会提示无法检查这个 App（它没有经过公证）：点「完成」，再到 **系统设置 → 隐私与安全性**，点「仍要打开」。
3. 引导页请求**辅助功能**权限时，允许它。其他权限都可选。
4. 在 Claude 或 ChatGPT 里置顶对话，KIKUmap 就会跟踪它们。

<details>
<summary>从源码构建</summary>

需要 Xcode 命令行工具。

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command` 用 `swiftc` 编译，装到 `~/Applications`，并用本地证书签名，所以重新编译后权限还在。`scripts/build-release.sh` 生成安装包。
</details>

## 隐私

- 所有数据都留在本机，放在 `~/Library/Application Support/ClaudeConsole/`。
- 必需的权限只有一个：**辅助功能**，用来读 Claude 和 ChatGPT 窗口里的对话列表。每个权限都会先说明用途，再由 macOS 弹窗请求。
- 不联网。唯一的例外是可选的用量查询（默认关闭）：开启后，会借用 Claude Code 和 Codex 已经存在本机的登录，向 Anthropic 和 OpenAI 查用量，登录信息不会被保存。这两家都没有说明允许应用这样查询，以后可能会被限制。

<details>
<summary>每个数据来源和权限的用途</summary>

| 显示的内容 | 来源 | 权限 |
|---|---|---|
| Claude 置顶对话：在跑、未读 | Claude App 的侧栏 | 辅助功能 |
| 等你批准、Cowork 任务做完，Claude 窗口关着时也能收到（可选） | 通知中心里 Claude 的通知 | 完全磁盘访问 |
| Claude Code 会话 | `~/.claude/settings.json` 里的 Claude Code hook（改之前会先备份原文件） | 不需要 |
| ChatGPT 的对话 | ChatGPT App 存在 `~/.codex` 里的文件（只读） | 不需要 |
| ChatGPT 普通对话（非 Codex）：在跑、做完、未读 | ChatGPT 窗口的左栏，窗口露出一部分时才读 | 辅助功能 |
| 桌面小组件 | KIKUmap 专门为它写的一个文件（`widget.json`） | 不需要 |
| Claude 用量和定时任务（可选） | Anthropic 的用量接口，借用 Claude Code 的登录 | 钥匙串 |
| ChatGPT 用量（可选，试验性） | OpenAI 的用量接口，借用 Codex 的登录 | 不需要 |

ChatGPT：Codex 对话支持得最好（读 App 的文件，窗口关着也准）。普通对话支持有限：只能从 ChatGPT 的窗口里读，窗口要露出一部分。

不会显示：没置顶的对话，以及在别的电脑、服务器或云端运行的任何东西。
</details>

<details>
<summary>全部快捷键</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | 新建子主题 / 父主题 |
| ⏎ / ⌥⏎ / ⇧⏎ | 在下方 / 上方新建同级 / 新建主主题 |
| ⌘⏎、双击 | 重命名 |
| ⌫ / ⌥⌫ | 删除（置顶对话仍在左栏）/ 只删主题、保留下面的（多选时也一样） |
| ⌥. | 折叠 / 展开 |
| ↑ ↓ ← → | 选中那个方向最近的条目 |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | 上下移动 / 移动一级 |
| ⌘↓、轻按空格 | 在对应的 App 里打开对话 |
| ⌘↑ | 回到所在的主题 |
| 在空白处拖框、⇧/⌘ 点击 | 多选 |
| 按住空格、双指滑动 | 移动导图 |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | 左栏 / 标签 / 时间轴 |
| 左栏里 ↑ ↓ | 选上一行 / 下一行（导图上同时选中这个对话） |
| 左栏里 ⏎、空格 | 在它的 App 里打开对话 |
| ⌘Y | 统计 |
| ⌘R | 刷新 |
| ⌘Z / ⇧⌘Z | 撤销 / 重做 |
| ⌘F | 搜索 |
| ⌘E / ⇧⌘E | 导图导出 PDF / 导出对话 |
| ⇧⌘U | 标为未读 / 已读 |
| ⌘+ / ⌘- / 双指捏合 / ⌘0 | 放大 / 缩小 / 缩放 / 适应窗口 |
| ⌃⌥C（可改，但不能用 KIKUmap 自己的 ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H） | 随时显示或隐藏导图 |
</details>

## 常见问题

<details>
<summary><b>这是 Anthropic 或 OpenAI 做的吗？</b></summary>

不是。KIKUmap 是独立的开源项目。Claude App 没有公开接口，KIKUmap 通过「辅助功能」读它的窗口；Claude 或 ChatGPT 改版后，部分功能可能要等 KIKUmap 更新才能恢复。
</details>

<details>
<summary><b>为什么要点「仍要打开」？</b></summary>

公证需要付费的 Apple 开发者账号，而 KIKUmap 是免费的。也可以从源码自己编译：纯 Swift，没有依赖。
</details>

<details>
<summary><b>Claude 的窗口关了会怎样？</b></summary>

⌘W 只是把窗口藏起来。KIKUmap 从窗口里读 Claude 的对话，所以要等窗口回到当前桌面才能看到；在那之前，原来在跑的对话显示「在跑？」。Claude Code 和 Codex 对话不受影响。ChatGPT 的普通对话也是从 ChatGPT 的窗口里读的，窗口露出一部分才看得到。
</details>

<details>
<summary><b>有东西没显示</b></summary>

- 顶栏的 **▸ 待办** 会列出缺了什么，每一项都有按钮可以直接处理。
- Claude 对话：先置顶，并让 Claude 的侧栏开着，停在 Chat，Pinned 展开。
- Claude Code：设置 → 授权 → Claude Code → **连接**，然后开一个新会话。
- 小组件：需要 macOS 14 及以上，KIKUmap 装在「应用程序」里。在桌面右键 → **编辑小组件**。
- 还是不行：设置 → 授权 → **诊断报告**（里面没有对话标题和内容），然后[提交 issue](https://github.com/tang1693/KIKUmap/issues)。
</details>

<details>
<summary><b>名字的由来？</b></summary>

*Kiku*（菊）是日语里的菊花，就是菜单栏里那朵小花。
</details>

## 参与贡献

欢迎提 issue 和 pull request，尤其是 Claude 或 ChatGPT 更新后出了问题的时候。请看[贡献指南](.github/CONTRIBUTING.md)和[行为准则](.github/CODE_OF_CONDUCT.md)；安全问题请按[安全政策](.github/SECURITY.md)私下报告。

## 支持

KIKUmap 免费。觉得有用的话，请我喝杯咖啡 ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-zh.svg" height="64" alt="在 Ko-fi 请我喝咖啡"></a></p>

## 协议

[MIT](LICENSE)。Claude 是 Anthropic 的商标，ChatGPT 是 OpenAI 的商标；本项目独立开发，未获任何一方背书。
