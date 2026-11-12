<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.png">
  <img src="docs/banner-en-light.png" width="100%" alt="KIKUmap : une carte mentale pour vos conversations Claude et ChatGPT">
</picture>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.de.md">Deutsch</a> · <b>Français</b></p>

<p align="center">Une carte mentale pour vos conversations Claude et ChatGPT, dans la barre des menus du Mac.<br>Voyez ce qui tourne, ce qui est terminé et ce qui vous attend.</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-en.svg" height="56" alt="Télécharger KIKUmap pour macOS"></a>&nbsp;&nbsp;<a href="https://tang1693.github.io/KIKUmap/?lang=fr"><img src="docs/website-en.svg" height="56" alt="Visiter le site de KIKUmap"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=version&color=187DFE" alt="Dernière version"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 ou ultérieur">
  <img src="https://img.shields.io/badge/languages-9-7A5AF8" alt="9 languages">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift, sans dépendances">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="Licence MIT"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="Étoiles GitHub"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white" alt="Soutenir sur Ko-fi"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/?lang=fr">Site web</a> ·
  <a href="#features">Fonctionnalités</a> ·
  <a href="#install">Installation</a> ·
  <a href="#privacy">Confidentialité</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="#support">Soutenir ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="Le sujet Work est déplacé sur la carte : les autres sujets s’écartent pour lui faire de la place et il se pose dans l’espace libéré"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/#tour"><img src="docs/demo/intro-poster.jpg" width="100%" alt="Regarder la visite guidée de KIKUmap"></a></p>

## <a id="features"></a>Fonctionnalités

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="L’icône de la barre des menus compte les conversations en cours dans un anneau qui tourne, puis affiche une pastille rouge de non-lus, puis un point d’exclamation quand une conversation vous attend"></td>
<td>

### 1. L’état dans la barre des menus
Un anneau compte les conversations en cours. Une pastille rouge compte celles qui sont terminées et non lues, avec un **!** quand l’une d’elles vous attend (pour approuver ou répondre, ou parce qu’elle s’est arrêtée sur une erreur). En option, un son ou une voix vous dit quelle conversation est terminée.

</td>
</tr>
<tr>
<td>

### 2. Les conversations en carte
Les conversations épinglées dans Claude et dans l’app ChatGPT, ainsi que les sessions Claude Code, s’alignent dans la colonne de gauche. Faites-les glisser sur vos propres sujets. Chaque conversation porte l’étiquette **Claude** ou **GPT**.

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="Sélection de trois conversations, glissées ensemble sur Side projects"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="Un clic sur le tag In progress met en évidence les conversations qui l’ont ; le tag est ensuite glissé sur une conversation"></td>
<td>

### 3. Couleurs, formes et tags
Donnez une couleur et une forme à un sujet. Ajoutez des tags aux conversations et cliquez sur un tag pour mettre en évidence toutes celles qui l’ont. Faites glisser le bord supérieur des tags pour les agrandir ou les réduire, ou rangez-les (⌃⌘G). Dans une fenêtre basse et zoomée, ils s’effacent jusqu’à ce qu’il y ait de la place : agrandissez la fenêtre en hauteur ou appuyez sur ⌘-.

Settings → Colors (Réglages → Couleurs) propose huit jeux de couleurs pour toute la fenêtre (Classic, KIKU flower, Bauhaus black, Retro, Deep sea, Neon, Sunset, Candy), ou choisissez chaque couleur vous-même.

</td>
</tr>
<tr>
<td>

### 4. Pensé pour le clavier
⇥ sous-sujet · ⏎ sujet voisin · ⌥↑↓ déplacer · ⌘Z annuler · ⌘F rechercher · espace ouvre une conversation.

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab ajoute un sous-sujet, Retour ajoute un sujet voisin, Option-Flèche haut le déplace, Commande-Z annule"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="La chronologie : les exécutions passées avec leurs heures, et les tâches planifiées avec un compte à rebours"></td>
<td>

### 5. Chronologie
Quand chaque conversation a tourné, et les prochaines tâches planifiées, avec compte à rebours.

</td>
</tr>
<tr>
<td>

### 6. Export et import
Chaque conversation Claude sous forme de fichiers : un résumé, les prompts, la conversation et les artefacts. Importez-les dans un autre compte Claude.

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="La fenêtre d’export et le dossier de fichiers Markdown et d’artefacts qu’elle produit"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget.png" width="100%" alt="Les widgets KIKUmap en trois tailles : temps de travail sur les dernières 24 heures, utilisation et, dans le grand, les conversations les plus actives et les 7 derniers jours"></td>
<td>

### 7. Widget de bureau
Le temps de travail sur les dernières 24 heures et les 7 derniers jours, plus l’utilisation de Claude et de ChatGPT avec le nom de l’abonnement. Trois tailles, macOS 14 ou ultérieur.

</td>
</tr>
<tr>
<td>

### 8. Statistiques
Le temps par conversation et par session sur 7, 14, 30 ou 90 jours. ⌘Y.

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="Statistiques : temps par conversation et par session, en barres sur sept jours"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="Les conversations terminées s’allument"><br><b>Les conversations terminées s’allument</b> sur la carte.</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="Recherche"><br><b>Recherchez</b> sujets, conversations et tags.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="Today dans le menu"><br><b>Today</b> (aujourd’hui) : quelles conversations et sessions ont travaillé, et combien de temps.</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="Usage dans le menu"><br><b>Utilisation</b> pour la session et la semaine.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="La carte en PDF"><br><b>PDF</b> de toute la carte.</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="Sauvegardes quotidiennes"><br><b>Sauvegardes quotidiennes</b> de la carte.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="Clair ou sombre"><br><b>Clair ou sombre.</b></td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="Anglais et chinois"><br><b>9 langues :</b> English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Português · Deutsch · Français</td>
</tr>
</table>

**Fonctionne avec :** l’app de bureau Claude · Claude Code (Terminal, VS Code, Cursor, le mode Code de l’app) · l’app de bureau ChatGPT · Codex dans VS Code ou le terminal.

**Native et légère :** uniquement Swift et AppKit. Pas d’Electron, pas de vue web, pas de code tiers (icônes au trait de [Lucide](https://lucide.dev), ISC).

## <a id="install"></a>Installation

1. [Téléchargez Kikumap.dmg](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg) (macOS 13 ou ultérieur, Apple silicon et Intel) et faites glisser KIKUmap dans Applications.
2. Au premier lancement, macOS ne peut pas vérifier l’app (elle n’est pas notarisée). Cliquez sur **Terminé**, puis sur **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.
3. Autorisez **Accessibilité** quand l’introduction le demande. Tout le reste est facultatif.
4. Épinglez des conversations dans Claude ou ChatGPT pour les suivre.

<details>
<summary>Compiler depuis les sources</summary>

Nécessite les Xcode Command Line Tools.

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command` compile avec `swiftc`, installe dans `~/Applications` et signe avec un certificat local, pour que les autorisations survivent aux recompilations. `scripts/build-release.sh` crée l’image disque.
</details>

## <a id="privacy"></a>Confidentialité

- Tout reste sur le Mac, dans `~/Library/Application Support/ClaudeConsole/`.
- Une seule autorisation est requise : **Accessibilité**, pour lire les listes de conversations dans les fenêtres de Claude et de ChatGPT. Chaque autorisation est expliquée avant que macOS ne la demande.
- Aucune requête réseau, à part les consultations d’utilisation facultatives (désactivées par défaut) auprès d’Anthropic et d’OpenAI. Elles lisent les identifiants de connexion que Claude Code et Codex conservent déjà sur le Mac, et ne les enregistrent jamais. Aucune des deux entreprises n’a dit que les apps pouvaient faire cela, ces consultations pourraient donc être bloquées.
- L’export (avec résumés) et l’import collent via le presse-papiers. Ce que KIKUmap colle est marqué pour que les apps d’historique du presse-papiers l’ignorent, et ne passe pas sur vos autres appareils. Chaque résumé passe par le propre bouton Copier de Claude, qu’une app d’historique du presse-papiers peut conserver. Votre presse-papiers est rétabli après chaque étape.

<details>
<summary>À quoi sert chaque source et chaque autorisation</summary>

| Affiche | Provient de | Autorisation |
|---|---|---|
| Conversations Claude en cours, non lues, épinglées | La barre latérale de l’app Claude | Accessibilité |
| Claude qui vous attend (pour approuver ou répondre) et tâches Cowork terminées, même fenêtre de Claude fermée (facultatif) | Les notifications de Claude dans le Centre de notifications | Accès complet au disque |
| Sessions Claude Code | Les hooks Claude Code dans `~/.claude/settings.json` (sauvegardé avant) | aucune |
| Conversations ChatGPT | Les fichiers de l’app ChatGPT dans `~/.codex` (lecture seule) | aucune |
| En cours, terminée et non lue pour les conversations ChatGPT ordinaires (hors Codex) | La barre latérale de la fenêtre de ChatGPT, tant qu’une partie de la fenêtre est visible | Accessibilité |
| Une session terminée que vous regardez compte comme lue | Les titres de fenêtre de son éditeur ou de son terminal, tant que cette app est au premier plan | Accessibilité |
| Widget de bureau | Un fichier que KIKUmap écrit pour lui (`widget.json`) | aucune |
| Utilisation de Claude et tâches planifiées (facultatif) | L’API d’utilisation d’Anthropic, avec la connexion de Claude Code | Trousseau |
| Utilisation de ChatGPT (facultatif, expérimental) | L’interface d’utilisation d’OpenAI, avec la connexion de Codex | aucune |

ChatGPT : les conversations Codex sont les mieux prises en charge (lues depuis les fichiers de l’app, exactes même fenêtre fermée). Les conversations ordinaires le sont moins bien : elles sont lues dans la fenêtre de ChatGPT, seulement tant qu’une partie en est visible.

Non affiché : les conversations non épinglées, et tout ce qui tourne sur un autre ordinateur, un serveur ou dans le cloud.
</details>

<details>
<summary>Tous les raccourcis clavier</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | nouveau sujet enfant / nouveau sujet parent |
| ⏎ / ⌥⏎ / ⇧⏎ | nouveau sujet voisin en dessous / au-dessus / nouveau sujet principal |
| ⌘⏎, double-clic | renommer |
| ⌫ / ⌥⌫ | supprimer (les conversations épinglées restent dans la colonne de gauche) / supprimer seulement le sujet en gardant ses éléments (aussi avec plusieurs sélectionnés) |
| ⌥. | replier / déplier |
| ↑ ↓ ← → | sélectionner l’élément le plus proche dans cette direction |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | monter ou descendre / changer de niveau |
| ⌘↓, appui bref sur espace | ouvrir la conversation dans son app |
| ⌘↑ | remonter au sujet qui le contient |
| glisser sur un espace vide, ⇧/⌘-clic | sélectionner plusieurs éléments |
| maintenir espace, balayer à deux doigts | se déplacer sur la carte |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | colonne de gauche / tags / chronologie |
| ↑ ↓ dans la colonne de gauche | choisir la ligne au-dessus ou en dessous (la carte sélectionne aussi sa conversation) |
| ⏎, espace dans la colonne de gauche | ouvrir la conversation dans son app |
| ⌘Y | statistiques |
| ⌘R | actualiser |
| ⌘Z / ⇧⌘Z | annuler / rétablir |
| ⌘F | rechercher |
| ⌘E / ⇧⌘E | carte en PDF / exporter les conversations |
| ⇧⌘U | marquer comme non lu / lu |
| ⌘+ / ⌘- / pincer / ⌘0 | agrandir / réduire / zoomer / ajuster |
| ⌃⌥C (modifiable, mais pas vers les propres ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H de KIKUmap) | afficher ou masquer la carte depuis n’importe où |
</details>

## <a id="faq"></a>FAQ

<details>
<summary><b>Est-ce fait par Anthropic ou OpenAI ?</b></summary>

Non. KIKUmap est un projet indépendant et open source. L’app Claude n’a pas d’API publique, donc KIKUmap lit sa fenêtre via l’Accessibilité ; une mise à jour de Claude ou de ChatGPT peut en casser une partie jusqu’à ce que KIKUmap s’adapte.
</details>

<details>
<summary><b>Pourquoi « Ouvrir quand même » ?</b></summary>

La notarisation exige un compte développeur Apple payant, et KIKUmap est gratuit. Vous pouvez aussi le compiler depuis les sources : du Swift pur, sans dépendances.
</details>

<details>
<summary><b>La fenêtre de Claude est fermée. Que se passe-t-il ?</b></summary>

⌘W ne fait que la masquer. KIKUmap lit les conversations de Claude depuis la fenêtre, il ne peut donc pas les voir tant que la fenêtre n’est pas revenue sur le bureau actuel ; en attendant, les conversations en cours affichent « running? » (en cours ?). Une fois la fenêtre revenue, une conversation trouvée terminée affiche « done after 14:00 » (terminée après 14:00, la dernière fois qu’elle a été vue en cours), puisqu’on ne sait pas quand elle s’est terminée. Les conversations Claude Code et Codex ne sont pas concernées. Les conversations ChatGPT ordinaires sont lues de la même façon dans la fenêtre de ChatGPT, tant qu’une partie en est visible.
</details>

<details>
<summary><b>Une session s’est terminée pendant que je la regardais. Pourquoi est-elle encore non lue ?</b></summary>

KIKUmap ne marque de lui-même une session terminée comme lue que lorsque la fenêtre au premier plan ne peut être que celle de cette session : pour Claude Code, la fenêtre de son dossier dans VS Code ou Cursor, ou une fenêtre de terminal dont le titre affiche à la fois son dossier et `claude` ; pour Codex, la fenêtre de son dossier dans VS Code. Si une autre fenêtre ou un autre onglet pourrait aussi l’afficher, comme une autre fenêtre d’éditeur sur son dossier ou sur un dossier parent, elle reste non lue. Les sessions Codex dans un terminal restent aussi non lues (KIKUmap ne peut pas savoir quel terminal les exécute). Ouvrez-la depuis KIKUmap, ou sélectionnez-la et appuyez sur ⇧⌘U, pour la marquer comme lue.
</details>

<details>
<summary><b>Quelque chose ne s’affiche pas</b></summary>

- **▸ To-do** (à faire) dans la barre du haut liste ce qui manque, avec un bouton pour chaque point.
- Conversations Claude : épinglez-les, et gardez la barre latérale de Claude ouverte sur Chat avec Pinned déplié.
- Claude Code : Settings → Access → Claude Code → **Connect** (Réglages → Accès → Claude Code → Connecter), puis lancez une nouvelle session.
- Widget : macOS 14 ou ultérieur, avec KIKUmap dans Applications. Clic droit sur le bureau → **Modifier les widgets**.
- Toujours bloqué ? Settings → Access → **Diagnostic report** (Réglages → Accès → Rapport de diagnostic ; sans titres ni messages de conversations) et [ouvrez une issue](https://github.com/tang1693/KIKUmap/issues).
</details>

<details>
<summary><b>Pourquoi ce nom ?</b></summary>

*Kiku* (菊) signifie chrysanthème en japonais : la petite fleur de la barre des menus.
</details>

## Contribuer

Les issues et les pull requests sont les bienvenues, surtout quand une mise à jour de Claude ou de ChatGPT casse quelque chose. Consultez le [guide de contribution](.github/CONTRIBUTING.md) et le [code de conduite](.github/CODE_OF_CONDUCT.md) ; les problèmes de sécurité passent par la [politique de sécurité](.github/SECURITY.md).

## <a id="support"></a>Soutenir

KIKUmap est gratuit. S’il vous est utile, un café l’aide à continuer ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-en.svg" height="64" alt="M’offrir un café sur Ko-fi"></a></p>

## Licence

[MIT](LICENSE). Claude est une marque d’Anthropic et ChatGPT une marque d’OpenAI ; ce projet est indépendant et n’est approuvé par aucune des deux.
