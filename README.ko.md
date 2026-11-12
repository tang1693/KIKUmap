<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.png">
  <img src="docs/banner-en-light.png" width="100%" alt="KIKUmap: Claude와 ChatGPT 채팅을 위한 마인드맵">
</picture>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <b>한국어</b> · <a href="README.es.md">Español</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a></p>

<p align="center">Mac 메뉴 막대에 두는, Claude와 ChatGPT 채팅을 위한 마인드맵.<br>실행 중인 것, 끝난 것, 나를 기다리는 것을 한눈에 볼 수 있어요.</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-en.svg" height="56" alt="macOS용 KIKUmap 다운로드"></a>&nbsp;&nbsp;<a href="https://tang1693.github.io/KIKUmap/?lang=ko"><img src="docs/website-en.svg" height="56" alt="KIKUmap 웹사이트 방문"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=version&color=187DFE" alt="최신 릴리스"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 이상">
  <img src="https://img.shields.io/badge/languages-9-7A5AF8" alt="9 languages">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift, 의존성 없음">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="MIT 라이선스"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="GitHub 스타"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white" alt="Ko-fi에서 후원하기"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/?lang=ko">웹사이트</a> ·
  <a href="#features">기능</a> ·
  <a href="#install">설치</a> ·
  <a href="#privacy">개인정보</a> ·
  <a href="#faq">자주 묻는 질문</a> ·
  <a href="#support">후원 ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="Work 토픽을 맵 위로 드래그하면 다른 토픽들이 옆으로 비켜 자리를 만들고, 빈자리에 내려앉는 모습"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/#tour"><img src="docs/demo/intro-poster.jpg" width="100%" alt="KIKUmap 소개 영상 보기"></a></p>

## <a id="features"></a>기능

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="메뉴 막대 아이콘이 회전하는 링으로 실행 중인 채팅 수를 세고, 이어서 빨간 읽지 않음 배지, 채팅이 나를 기다릴 때는 느낌표가 표시되는 모습"></td>
<td>

### 1. 메뉴 막대에서 상태 확인
링은 실행 중인 채팅 수를 보여 줘요. 빨간 배지는 끝났지만 아직 읽지 않은 채팅 수이고, 나를 기다리는 채팅(승인이나 답변이 필요하거나 오류로 멈춘 채팅)이 있으면 **!**가 붙어요. 원하면 효과음이나 음성으로 어떤 채팅이 끝났는지 알려 줘요.

</td>
</tr>
<tr>
<td>

### 2. 채팅을 맵으로
Claude와 ChatGPT 앱에서 고정한 채팅, 그리고 Claude Code 세션이 왼쪽 열에 나란히 놓여요. 이것들을 내 토픽으로 드래그하세요. 각 채팅에는 **Claude** 또는 **GPT** 태그가 붙어요.

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="채팅 세 개를 선택해 한꺼번에 Side projects로 드래그하는 모습"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="In progress 태그를 클릭하면 그 태그가 붙은 채팅이 강조되고, 이어서 태그를 채팅 위로 드래그하는 모습"></td>
<td>

### 3. 색, 모양, 태그
토픽에 색과 모양을 지정할 수 있어요. 채팅에 태그를 달고, 태그를 클릭하면 그 태그가 붙은 채팅이 모두 강조돼요. 태그 영역의 위쪽 가장자리를 드래그해 높이를 바꾸거나 접어 둘 수 있어요(⌃⌘G). 창이 낮은데 확대해 두면 자리가 생길 때까지 태그가 비켜 있어요. 창을 높이거나 ⌘-를 누르세요.

Settings → Colors(설정 → 색상)에는 창 전체에 쓰는 색 세트가 여덟 가지 있어요(Classic, KIKU flower, Bauhaus black, Retro, Deep sea, Neon, Sunset, Candy). 색을 하나하나 직접 고를 수도 있어요.

</td>
</tr>
<tr>
<td>

### 4. 키보드 중심
⇥ 하위 토픽 · ⏎ 형제 토픽 · ⌥↑↓ 이동 · ⌘Z 실행 취소 · ⌘F 검색 · 스페이스로 채팅 열기.

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab으로 하위 토픽, Return으로 형제 토픽을 추가하고, Option-위쪽 화살표로 옮기고, Command-Z로 되돌리는 모습"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="타임라인: 지난 실행과 그 시각, 카운트다운이 붙은 예약 작업"></td>
<td>

### 5. 타임라인
각 채팅이 언제 실행됐는지, 그리고 다가오는 예약 작업을 카운트다운과 함께 보여 줘요.

</td>
</tr>
<tr>
<td>

### 6. 내보내기와 가져오기
Claude 채팅 하나하나를 요약, 프롬프트, 대화, 아티팩트 파일로 내보내요. 다른 Claude 계정으로 가져올 수도 있어요.

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="내보내기 창과, 내보낸 Markdown 파일과 아티팩트가 담긴 폴더"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget.png" width="100%" alt="세 가지 크기의 KIKUmap 위젯: 지난 24시간 작업 시간, 사용량, 큰 위젯에는 가장 바빴던 채팅과 지난 7일까지"></td>
<td>

### 7. 데스크톱 위젯
지난 24시간과 지난 7일의 작업 시간, 그리고 요금제 이름과 함께 Claude와 ChatGPT 사용량을 보여 줘요. 세 가지 크기가 있고, macOS 14 이상이 필요해요.

</td>
</tr>
<tr>
<td>

### 8. 통계
채팅과 세션별 시간을 7일, 14일, 30일, 90일 단위로 보여 줘요. ⌘Y.

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="통계: 7일 동안 채팅과 세션별 시간을 나타낸 막대그래프"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="끝난 채팅에 불이 들어옴"><br>맵에서 <b>끝난 채팅에 불이 들어와요</b>.</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="검색"><br>토픽, 채팅, 태그를 <b>검색</b>.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="메뉴의 Today"><br><b>Today</b>(오늘): 어떤 채팅과 세션이 얼마나 작업했는지.</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="메뉴의 Usage"><br>현재 세션과 이번 주의 <b>사용량</b>.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="맵을 PDF로"><br>맵 전체를 <b>PDF</b>로.</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="매일 백업"><br>맵을 <b>매일 백업</b>.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="라이트 또는 다크"><br><b>라이트 또는 다크.</b></td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="영어와 중국어"><br><b>9개 언어:</b> English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Português · Deutsch · Français</td>
</tr>
</table>

**지원 앱:** Claude 데스크톱 앱 · Claude Code(터미널, VS Code, Cursor, 앱의 Code 모드) · ChatGPT 데스크톱 앱 · VS Code나 터미널의 Codex.

**네이티브라 가벼워요:** Swift와 AppKit만 써요. Electron도, 웹 뷰도, 서드파티 코드도 없어요(선 아이콘은 [Lucide](https://lucide.dev), ISC).

## <a id="install"></a>설치

1. [Kikumap.dmg를 다운로드](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg)하고(macOS 13 이상, Apple 실리콘과 Intel 지원) KIKUmap을 응용 프로그램 폴더로 드래그하세요.
2. 처음 실행하면 macOS가 앱을 확인할 수 없다고 해요(공증을 받지 않았기 때문이에요). **완료**를 클릭한 다음 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 누르세요.
3. 소개 화면에서 요청하면 **손쉬운 사용**을 허용하세요. 나머지는 모두 선택 사항이에요.
4. Claude나 ChatGPT에서 채팅을 고정하면 KIKUmap이 따라가요.

<details>
<summary>소스에서 빌드하기</summary>

Xcode Command Line Tools가 필요해요.

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command`는 `swiftc`로 빌드해 `~/Applications`에 설치하고 로컬 인증서로 서명해요. 그래서 다시 빌드해도 권한이 그대로 남아요. `scripts/build-release.sh`는 디스크 이미지를 만들어요.
</details>

## <a id="privacy"></a>개인정보

- 모든 데이터는 Mac 안의 `~/Library/Application Support/ClaudeConsole/`에만 저장돼요.
- 꼭 필요한 권한은 하나예요. Claude와 ChatGPT 창의 채팅 목록을 읽기 위한 **손쉬운 사용**이에요. 모든 권한은 macOS가 묻기 전에 용도를 먼저 설명해요.
- 네트워크 요청은 하지 않아요. 예외는 Anthropic과 OpenAI에 보내는 선택적 사용량 조회(기본값은 꺼짐)뿐이에요. 이 조회는 Claude Code와 Codex가 이미 Mac에 보관하는 로그인 정보를 읽어 쓰고, 저장하지는 않아요. 두 회사 모두 앱이 이렇게 해도 된다고 밝힌 적은 없어서, 이 조회는 막힐 수도 있어요.
- 내보내기(요약 포함)와 가져오기는 클립보드를 통해 붙여 넣어요. KIKUmap이 붙여 넣는 내용에는 클립보드 기록 앱이 건너뛰도록 표시가 붙고, 다른 기기로 넘어가지 않아요. 각 요약은 Claude 자체의 복사 버튼을 거치기 때문에 클립보드 기록 앱에 남을 수 있어요. 단계마다 클립보드는 원래대로 돌아가요.

<details>
<summary>각 소스와 권한의 용도</summary>

| 보여 주는 것 | 출처 | 권한 |
|---|---|---|
| 실행 중, 읽지 않음, 고정된 Claude 채팅 | Claude 앱의 사이드바 | 손쉬운 사용 |
| 나를 기다리는 Claude(승인이나 답변)와 끝난 Cowork 작업, Claude 창이 닫혀 있어도(선택 사항) | 알림 센터에 있는 Claude의 알림 | 전체 디스크 접근 권한 |
| Claude Code 세션 | `~/.claude/settings.json`의 Claude Code 훅(먼저 백업) | 없음 |
| ChatGPT 채팅 | ChatGPT 앱이 `~/.codex`에 두는 파일(읽기 전용) | 없음 |
| 일반 ChatGPT 채팅(Codex 제외)의 실행 중, 완료, 읽지 않음 | ChatGPT 창의 사이드바(창의 일부가 보이는 동안) | 손쉬운 사용 |
| 보고 있던 세션이 끝나면 읽음으로 처리 | 그 편집기나 터미널의 창 제목(그 앱이 맨 앞에 있는 동안) | 손쉬운 사용 |
| 데스크톱 위젯 | KIKUmap이 위젯용으로 쓰는 파일 하나(`widget.json`) | 없음 |
| Claude 사용량과 예약 작업(선택 사항) | Anthropic의 사용량 API, Claude Code의 로그인 사용 | 키체인 |
| ChatGPT 사용량(선택 사항, 실험적) | OpenAI의 사용량 인터페이스, Codex의 로그인 사용 | 없음 |

ChatGPT: Codex 채팅이 가장 잘 지원돼요(앱의 파일에서 읽기 때문에 창이 닫혀 있어도 정확해요). 일반 채팅은 지원이 덜해요. ChatGPT 창에서, 창의 일부가 보이는 동안에만 읽어요.

표시되지 않는 것: 고정하지 않은 채팅, 그리고 다른 컴퓨터나 서버, 클라우드에서 실행되는 모든 것.
</details>

<details>
<summary>모든 키보드 단축키</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | 새 하위 토픽 / 새 상위 토픽 |
| ⏎ / ⌥⏎ / ⇧⏎ | 아래에 형제 토픽 / 위에 형제 토픽 / 새 메인 토픽 |
| ⌘⏎, 더블 클릭 | 이름 바꾸기 |
| ⌫ / ⌥⌫ | 삭제(고정한 채팅은 왼쪽 열에 남아요) / 토픽만 삭제하고 안의 항목은 유지(여러 개를 선택했을 때도) |
| ⌥. | 접기 / 펼치기 |
| ↑ ↓ ← → | 그 방향에서 가장 가까운 항목 선택 |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | 위아래로 이동 / 단계 이동 |
| ⌘↓, 스페이스 살짝 누르기 | 채팅을 해당 앱에서 열기 |
| ⌘↑ | 속한 토픽으로 올라가기 |
| 빈 곳에서 드래그, ⇧/⌘-클릭 | 여러 개 선택 |
| 스페이스를 누른 채, 두 손가락 쓸어넘기기 | 맵 이동 |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | 왼쪽 열 / 태그 / 타임라인 |
| 왼쪽 열에서 ↑ ↓ | 위나 아래 행 선택(맵에서도 그 채팅이 선택돼요) |
| 왼쪽 열에서 ⏎, 스페이스 | 채팅을 해당 앱에서 열기 |
| ⌘Y | 통계 |
| ⌘R | 새로고침 |
| ⌘Z / ⇧⌘Z | 실행 취소 / 실행 복귀 |
| ⌘F | 검색 |
| ⌘E / ⇧⌘E | 맵을 PDF로 / 채팅 내보내기 |
| ⇧⌘U | 읽지 않음 / 읽음으로 표시 |
| ⌘+ / ⌘- / 핀치 / ⌘0 | 크게 / 작게 / 확대·축소 / 창에 맞추기 |
| ⌃⌥C(바꿀 수 있지만 KIKUmap 자체의 ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H로는 안 돼요) | 어디서든 맵 보이기 / 숨기기 |
</details>

## <a id="faq"></a>자주 묻는 질문

<details>
<summary><b>Anthropic이나 OpenAI가 만든 건가요?</b></summary>

아니요. KIKUmap은 독립적인 오픈 소스 프로젝트예요. Claude 앱에는 공개 API가 없어서 KIKUmap은 손쉬운 사용을 통해 창을 읽어요. 그래서 Claude나 ChatGPT가 업데이트되면 KIKUmap이 따라잡을 때까지 일부 기능이 동작하지 않을 수 있어요.
</details>

<details>
<summary><b>왜 "그래도 열기"를 눌러야 하나요?</b></summary>

공증을 받으려면 유료 Apple 개발자 계정이 필요한데, KIKUmap은 무료예요. 소스에서 직접 빌드해도 돼요. 순수 Swift이고 의존성이 없어요.
</details>

<details>
<summary><b>Claude 창을 닫으면 어떻게 되나요?</b></summary>

⌘W는 창을 숨길 뿐이에요. KIKUmap은 Claude의 채팅을 창에서 읽기 때문에, 창이 현재 데스크톱으로 돌아올 때까지는 채팅을 볼 수 없어요. 그동안 실행 중이던 채팅은 "running?"(실행 중?)으로 표시돼요. 창이 돌아왔을 때 끝나 있던 채팅은 "done after 14:00"(14:00 이후 완료, 마지막으로 실행 중인 걸 본 시각)으로 표시돼요. 언제 끝났는지는 알 수 없기 때문이에요. Claude Code와 Codex 채팅은 영향을 받지 않아요. ChatGPT의 일반 채팅도 같은 방식으로, 창의 일부가 보이는 동안 ChatGPT 창에서 읽어요.
</details>

<details>
<summary><b>세션이 끝나는 걸 보고 있었는데, 왜 아직 읽지 않음인가요?</b></summary>

KIKUmap은 맨 앞의 창이 그 세션의 창일 수밖에 없을 때만 끝난 세션을 알아서 읽음으로 바꿔요. Claude Code라면 VS Code나 Cursor에서 그 폴더를 연 창, 또는 제목에 그 폴더와 `claude`가 모두 보이는 터미널 창이에요. Codex라면 VS Code에서 그 폴더를 연 창이에요. 다른 창이나 탭에도 표시되고 있을 수 있다면(같은 폴더나 그 상위 폴더를 연 다른 편집기 창 등) 읽지 않음으로 남아요. 터미널에서 실행되는 Codex 세션도 읽지 않음으로 남아요(KIKUmap이 어느 터미널에서 실행되는지 알 수 없어서요). 읽음으로 바꾸려면 KIKUmap에서 열거나, 선택한 뒤 ⇧⌘U를 누르세요.
</details>

<details>
<summary><b>뭔가 표시되지 않아요</b></summary>

- 상단 막대의 **▸ To-do**(할 일)에 빠진 것이 버튼과 함께 하나씩 나와요.
- Claude 채팅: 채팅을 고정하고, Claude 사이드바를 열어 Chat에 둔 채 Pinned를 펼쳐 두세요.
- Claude Code: Settings → Access → Claude Code → **Connect**(설정 → 접근 → Claude Code → 연결)를 누른 뒤 새 세션을 시작하세요.
- 위젯: macOS 14 이상이고 KIKUmap이 응용 프로그램 폴더에 있어야 해요. 데스크톱을 우클릭 → **위젯 편집**.
- 그래도 안 되면: Settings → Access → **Diagnostic report**(설정 → 접근 → 진단 보고서, 채팅 제목이나 메시지는 들어가지 않아요)를 만들고 [이슈를 열어 주세요](https://github.com/tang1693/KIKUmap/issues).
</details>

<details>
<summary><b>이름은 왜 이렇게 지었나요?</b></summary>

*Kiku*(菊)는 일본어로 국화예요. 메뉴 막대에 있는 작은 꽃이죠.
</details>

## 기여하기

이슈와 풀 리퀘스트는 언제나 환영해요. 특히 Claude나 ChatGPT 업데이트로 뭔가 망가졌을 때요. [기여 가이드](.github/CONTRIBUTING.md)와 [행동 강령](.github/CODE_OF_CONDUCT.md)을 참고하세요. 보안 문제는 [보안 정책](.github/SECURITY.md)에 따라 알려 주세요.

## <a id="support"></a>후원

KIKUmap은 무료예요. 도움이 됐다면 커피 한 잔이 계속 만들어 가는 힘이 돼요 ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-en.svg" height="64" alt="Ko-fi에서 커피 한 잔 사 주기"></a></p>

## 라이선스

[MIT](LICENSE). Claude는 Anthropic의 상표이고 ChatGPT는 OpenAI의 상표예요. 이 프로젝트는 독립적이며 두 회사 어디의 승인도 받지 않았어요.
