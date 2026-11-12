<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.png">
  <img src="docs/banner-en-light.png" width="100%" alt="KIKUmap: eine Mindmap für deine Claude- und ChatGPT-Chats">
</picture>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.pt-BR.md">Português</a> · <b>Deutsch</b> · <a href="README.fr.md">Français</a></p>

<p align="center">Eine Mindmap für deine Claude- und ChatGPT-Chats, in der Mac-Menüleiste.<br>Sieh, was läuft, was fertig ist und was auf dich wartet.</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-en.svg" height="56" alt="KIKUmap für macOS laden"></a>&nbsp;&nbsp;<a href="https://tang1693.github.io/KIKUmap/?lang=de"><img src="docs/website-en.svg" height="56" alt="KIKUmap-Website besuchen"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=version&color=187DFE" alt="Neueste Version"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 oder neuer">
  <img src="https://img.shields.io/badge/languages-9-7A5AF8" alt="9 languages">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift, keine Abhängigkeiten">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="MIT-Lizenz"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="GitHub-Sterne"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white" alt="Auf Ko-fi unterstützen"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/?lang=de">Website</a> ·
  <a href="#features">Funktionen</a> ·
  <a href="#install">Installation</a> ·
  <a href="#privacy">Datenschutz</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="#support">Unterstützen ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="Das Thema Work wird über die Map gezogen: Die anderen Themen rücken auseinander, um Platz zu machen, und es landet in der Lücke"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/#tour"><img src="docs/demo/intro-poster.jpg" width="100%" alt="Die KIKUmap-Tour ansehen"></a></p>

## <a id="features"></a>Funktionen

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="Das Menüleistensymbol zählt laufende Chats in einem sich drehenden Ring, zeigt dann ein rotes Ungelesen-Badge und schließlich ein Ausrufezeichen, wenn ein Chat auf dich wartet"></td>
<td>

### 1. Status in der Menüleiste
Ein Ring zählt laufende Chats. Ein rotes Badge zählt fertige, ungelesene Chats, mit **!**, wenn einer auf dich wartet (auf eine Freigabe oder Antwort, oder weil er mit einem Fehler angehalten hat). Auf Wunsch sagt dir ein Ton oder eine Stimme, welcher Chat fertig ist.

</td>
</tr>
<tr>
<td>

### 2. Chats als Map
Angepinnte Chats aus Claude und der ChatGPT-App sowie Claude Code-Sitzungen reihen sich in der linken Spalte auf. Zieh sie auf deine eigenen Themen. Jeder Chat ist mit **Claude** oder **GPT** gekennzeichnet.

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="Drei Chats werden ausgewählt und zusammen auf Side projects gezogen"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="Ein Klick auf den Tag In progress hebt die Chats hervor, die ihn haben; danach wird der Tag auf einen Chat gezogen"></td>
<td>

### 3. Farben, Formen und Tags
Gib einem Thema eine Farbe und eine Form. Versieh Chats mit Tags und klick auf einen Tag, um alle Chats mit diesem Tag hervorzuheben. Zieh den oberen Rand der Tags, um sie höher oder niedriger zu machen, oder blende sie aus (⌃⌘G). In einem niedrigen, vergrößerten Fenster weichen sie aus, bis Platz ist: Mach das Fenster höher oder drück ⌘-.

Settings → Colors (Einstellungen → Farben) bietet acht Farbsets für das ganze Fenster (Classic, KIKU flower, Bauhaus black, Retro, Deep sea, Neon, Sunset, Candy), oder du wählst jede Farbe selbst.

</td>
</tr>
<tr>
<td>

### 4. Tastatur zuerst
⇥ Unterthema · ⏎ Nachbarthema · ⌥↑↓ verschieben · ⌘Z widerrufen · ⌘F suchen · Leertaste öffnet einen Chat.

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab fügt ein Unterthema hinzu, Return ein Nachbarthema, Wahl-Pfeil nach oben verschiebt es, Befehl-Z macht es rückgängig"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="Die Timeline: vergangene Läufe mit ihren Zeiten und geplante Aufgaben mit Countdowns"></td>
<td>

### 5. Timeline
Wann jeder Chat lief, und die anstehenden geplanten Aufgaben mit Countdown.

</td>
</tr>
<tr>
<td>

### 6. Export und Import
Jeder Claude-Chat als Dateien: eine Zusammenfassung, die Prompts, die Unterhaltung und die Artefakte. Importiere sie in einen anderen Claude-Account.

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="Das Exportfenster und der Ordner mit Markdown-Dateien und Artefakten, den es schreibt"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget.png" width="100%" alt="KIKUmap-Widgets in drei Größen: Arbeitszeit der letzten 24 Stunden, Nutzung und im großen Widget die aktivsten Chats und die letzten 7 Tage"></td>
<td>

### 7. Schreibtisch-Widget
Arbeitszeit der letzten 24 Stunden und der letzten 7 Tage, dazu die Nutzung von Claude und ChatGPT mit Tarifnamen. Drei Größen, macOS 14 oder neuer.

</td>
</tr>
<tr>
<td>

### 8. Statistik
Zeit pro Chat und Sitzung über 7, 14, 30 oder 90 Tage. ⌘Y.

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="Statistik: Zeit pro Chat und Sitzung als Balken über sieben Tage"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="Fertige Chats leuchten auf"><br><b>Fertige Chats leuchten</b> auf der Map auf.</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="Suche"><br><b>Durchsuche</b> Themen, Chats und Tags.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="Today im Menü"><br><b>Today</b> (Heute): welche Chats und Sitzungen gearbeitet haben, und wie lange.</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="Usage im Menü"><br><b>Nutzung</b> für die Sitzung und die Woche.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="Die Map als PDF"><br><b>PDF</b> der ganzen Map.</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="Tägliche Backups"><br><b>Tägliche Backups</b> der Map.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="Hell oder dunkel"><br><b>Hell oder dunkel.</b></td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="Englisch und Chinesisch"><br><b>9 Sprachen:</b> English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Português · Deutsch · Français</td>
</tr>
</table>

**Funktioniert mit:** der Claude-Desktop-App · Claude Code (Terminal, VS Code, Cursor, dem Code-Modus der App) · der ChatGPT-Desktop-App · Codex in VS Code oder im Terminal.

**Nativ und leicht:** nur Swift und AppKit. Kein Electron, keine Web-View, kein Code von Dritten (Liniensymbole von [Lucide](https://lucide.dev), ISC).

## <a id="install"></a>Installation

1. [Kikumap.dmg laden](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg) (macOS 13 oder neuer, Apple Silicon und Intel) und KIKUmap in den Ordner „Programme“ ziehen.
2. Beim ersten Start kann macOS die App nicht überprüfen (sie ist nicht notariell beglaubigt). Klick auf **Fertig** und dann auf **Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen**.
3. Erlaube **Bedienungshilfen**, wenn die Einführung danach fragt. Alles andere ist optional.
4. Pinne Chats in Claude oder ChatGPT an, um ihnen zu folgen.

<details>
<summary>Aus dem Quellcode bauen</summary>

Benötigt die Xcode Command Line Tools.

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command` baut mit `swiftc`, installiert nach `~/Applications` und signiert mit einem lokalen Zertifikat, sodass Berechtigungen neue Builds überstehen. `scripts/build-release.sh` erstellt das Disk-Image.
</details>

## <a id="privacy"></a>Datenschutz

- Alles bleibt auf dem Mac, in `~/Library/Application Support/ClaudeConsole/`.
- Eine Berechtigung ist nötig: **Bedienungshilfen**, um die Chatlisten in den Fenstern von Claude und ChatGPT zu lesen. Jede Berechtigung wird erklärt, bevor macOS danach fragt.
- Keine Netzwerkanfragen, außer den optionalen Nutzungsabfragen (standardmäßig aus) bei Anthropic und OpenAI. Diese lesen die Anmeldungen, die Claude Code und Codex bereits auf dem Mac speichern, und sichern sie nie selbst. Keines der beiden Unternehmen hat gesagt, dass Apps das dürfen, daher könnten diese Abfragen blockiert werden.
- Export (mit Zusammenfassungen) und Import fügen über die Zwischenablage ein. Was KIKUmap einfügt, ist so markiert, dass Zwischenablage-Verlaufs-Apps es überspringen, und gelangt nicht auf deine anderen Geräte. Jede Zusammenfassung kommt über Claudes eigene Kopieren-Taste, die eine Zwischenablage-Verlaufs-App behalten kann. Deine Zwischenablage wird nach jedem Schritt wiederhergestellt.

<details>
<summary>Wofür jede Quelle und Berechtigung da ist</summary>

| Zeigt | Stammt aus | Berechtigung |
|---|---|---|
| Laufende, ungelesene, angepinnte Claude-Chats | Der Seitenleiste der Claude-App | Bedienungshilfen |
| Claude wartet auf dich (Freigabe oder Antwort) und fertige Cowork-Aufgaben, auch bei geschlossenem Claude-Fenster (optional) | Claudes Mitteilungen in der Mitteilungszentrale | Festplattenvollzugriff |
| Claude Code-Sitzungen | Claude Code-Hooks in `~/.claude/settings.json` (vorher gesichert) | keine |
| ChatGPT-Chats | Den Dateien der ChatGPT-App in `~/.codex` (nur lesend) | keine |
| Laufend, fertig und ungelesen für normale ChatGPT-Chats (nicht Codex) | Der Seitenleiste im ChatGPT-Fenster, solange ein Teil des Fensters sichtbar ist | Bedienungshilfen |
| Eine fertige Sitzung, die du gerade ansiehst, gilt als gelesen | Den Fenstertiteln ihres Editors oder Terminals, solange diese App vorne ist | Bedienungshilfen |
| Schreibtisch-Widget | Einer Datei, die KIKUmap dafür schreibt (`widget.json`) | keine |
| Claude-Nutzung und geplante Aufgaben (optional) | Der Nutzungs-API von Anthropic, mit der Anmeldung von Claude Code | Schlüsselbund |
| ChatGPT-Nutzung (optional, experimentell) | Der Nutzungsschnittstelle von OpenAI, mit der Anmeldung von Codex | keine |

ChatGPT: Codex-Chats werden am besten unterstützt (aus den Dateien der App gelesen, auch bei geschlossenem Fenster korrekt). Normale Chats werden weniger gut unterstützt: Sie werden aus dem ChatGPT-Fenster gelesen, nur solange ein Teil davon sichtbar ist.

Nicht angezeigt: nicht angepinnte Chats und alles, was auf einem anderen Computer, einem Server oder in der Cloud läuft.
</details>

<details>
<summary>Alle Tastaturkurzbefehle</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | neues Unterthema / neues übergeordnetes Thema |
| ⏎ / ⌥⏎ / ⇧⏎ | neues Nachbarthema darunter / darüber / neues Hauptthema |
| ⌘⏎, Doppelklick | umbenennen |
| ⌫ / ⌥⌫ | löschen (angepinnte Chats bleiben in der linken Spalte) / nur das Thema löschen, seine Einträge behalten (auch bei mehreren ausgewählten) |
| ⌥. | einklappen / ausklappen |
| ↑ ↓ ← → | nächstgelegenen Eintrag in dieser Richtung auswählen |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | nach oben oder unten verschieben / eine Ebene verschieben |
| ⌘↓, Leertaste antippen | den Chat in seiner App öffnen |
| ⌘↑ | hoch zum Thema, in dem er liegt |
| auf leerer Fläche ziehen, ⇧/⌘-Klick | mehrere auswählen |
| Leertaste halten, mit zwei Fingern streichen | in der Map bewegen |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | linke Spalte / Tags / Timeline |
| ↑ ↓ in der linken Spalte | die Zeile darüber oder darunter wählen (die Map wählt den Chat mit aus) |
| ⏎, Leertaste in der linken Spalte | den Chat in seiner App öffnen |
| ⌘Y | Statistik |
| ⌘R | aktualisieren |
| ⌘Z / ⇧⌘Z | widerrufen / wiederholen |
| ⌘F | suchen |
| ⌘E / ⇧⌘E | Map als PDF / Chats exportieren |
| ⇧⌘U | als ungelesen / gelesen markieren |
| ⌘+ / ⌘- / Aufziehen/Zuziehen / ⌘0 | größer / kleiner / zoomen / einpassen |
| ⌃⌥C (änderbar, aber nicht auf KIKUmaps eigene ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H) | die Map von überall ein- oder ausblenden |
</details>

## <a id="faq"></a>FAQ

<details>
<summary><b>Ist das von Anthropic oder OpenAI?</b></summary>

Nein. KIKUmap ist ein unabhängiges Open-Source-Projekt. Die Claude-App hat keine öffentliche API, deshalb liest KIKUmap ihr Fenster über die Bedienungshilfen; ein Update von Claude oder ChatGPT kann Teile davon kaputt machen, bis KIKUmap nachzieht.
</details>

<details>
<summary><b>Warum „Dennoch öffnen“?</b></summary>

Die Notarisierung braucht einen kostenpflichtigen Apple-Entwickler-Account, und KIKUmap ist kostenlos. Aus dem Quellcode bauen geht auch: reines Swift, keine Abhängigkeiten.
</details>

<details>
<summary><b>Claudes Fenster ist geschlossen. Was passiert?</b></summary>

⌘W blendet es nur aus. KIKUmap liest Claudes Chats aus dem Fenster und sieht sie deshalb erst wieder, wenn das Fenster zurück auf dem aktuellen Schreibtisch ist; solange zeigen laufende Chats „running?“ (läuft?). Ist es zurück, zeigt ein inzwischen fertiger Chat „done after 14:00“ (fertig nach 14:00, als er zuletzt laufend gesehen wurde), weil nicht bekannt ist, wann er fertig wurde. Claude Code- und Codex-Chats sind nicht betroffen. Normale ChatGPT-Chats werden genauso aus dem ChatGPT-Fenster gelesen, solange ein Teil davon sichtbar ist.
</details>

<details>
<summary><b>Eine Sitzung wurde fertig, während ich zugesehen habe. Warum ist sie noch ungelesen?</b></summary>

KIKUmap markiert eine fertige Sitzung nur dann selbst als gelesen, wenn das vordere Fenster nur zu dieser Sitzung gehören kann: bei Claude Code das Fenster ihres Ordners in VS Code oder Cursor oder ein Terminalfenster, dessen Titel sowohl ihren Ordner als auch `claude` zeigt; bei Codex das Fenster ihres Ordners in VS Code. Könnte ein anderes Fenster oder ein anderer Tab sie ebenfalls zeigen, etwa ein weiteres Editorfenster auf ihrem Ordner oder einem übergeordneten Ordner, bleibt sie ungelesen. Codex-Sitzungen in einem Terminal bleiben ebenfalls ungelesen (KIKUmap kann nicht erkennen, in welchem Terminal sie laufen). Öffne sie über KIKUmap oder wähl sie aus und drück ⇧⌘U, um sie als gelesen zu markieren.
</details>

<details>
<summary><b>Etwas wird nicht angezeigt</b></summary>

- **▸ To-do** (Zu erledigen) in der oberen Leiste listet auf, was fehlt, mit einer Taste für jeden Punkt.
- Claude-Chats: Pinne sie an und lass Claudes Seitenleiste auf Chat geöffnet, mit aufgeklapptem Pinned.
- Claude Code: Settings → Access → Claude Code → **Connect** (Einstellungen → Zugriff → Claude Code → Verbinden), dann eine neue Sitzung starten.
- Widget: macOS 14 oder neuer, mit KIKUmap im Ordner „Programme“. Rechtsklick auf den Schreibtisch → **Widgets bearbeiten**.
- Hängt es immer noch? Settings → Access → **Diagnostic report** (Einstellungen → Zugriff → Diagnosebericht; ohne Chattitel oder Nachrichten) und [ein Issue eröffnen](https://github.com/tang1693/KIKUmap/issues).
</details>

<details>
<summary><b>Warum der Name?</b></summary>

*Kiku* (菊) ist Japanisch für Chrysantheme: die kleine Blume in der Menüleiste.
</details>

## Mitwirken

Issues und Pull Requests sind willkommen, besonders wenn ein Update von Claude oder ChatGPT etwas kaputt macht. Sieh dir den [Leitfaden für Beiträge](.github/CONTRIBUTING.md) und den [Verhaltenskodex](.github/CODE_OF_CONDUCT.md) an; Sicherheitsprobleme laufen über die [Sicherheitsrichtlinie](.github/SECURITY.md).

## <a id="support"></a>Unterstützen

KIKUmap ist kostenlos. Wenn es dir hilft, hält ein Kaffee es am Laufen ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-en.svg" height="64" alt="Spendier mir einen Kaffee auf Ko-fi"></a></p>

## Lizenz

[MIT](LICENSE). Claude ist eine Marke von Anthropic und ChatGPT eine Marke von OpenAI; dieses Projekt ist unabhängig und wird von keinem der beiden unterstützt.
