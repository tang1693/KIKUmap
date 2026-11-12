<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.png">
  <img src="docs/banner-en-light.png" width="100%" alt="KIKUmap: un mapa mental para tus chats de Claude y ChatGPT">
</picture>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <b>Español</b> · <a href="README.pt-BR.md">Português</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a></p>

<p align="center">Un mapa mental para tus chats de Claude y ChatGPT, en la barra de menús del Mac.<br>Mira qué está en marcha, qué ha terminado y qué te necesita.</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-en.svg" height="56" alt="Descargar KIKUmap para macOS"></a>&nbsp;&nbsp;<a href="https://tang1693.github.io/KIKUmap/?lang=es"><img src="docs/website-en.svg" height="56" alt="Visitar el sitio web de KIKUmap"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=version&color=187DFE" alt="Última versión"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 o posterior">
  <img src="https://img.shields.io/badge/languages-9-7A5AF8" alt="9 languages">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift, sin dependencias">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="Licencia MIT"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="Estrellas en GitHub"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white" alt="Apoyar en Ko-fi"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/?lang=es">Sitio web</a> ·
  <a href="#features">Funciones</a> ·
  <a href="#install">Instalación</a> ·
  <a href="#privacy">Privacidad</a> ·
  <a href="#faq">Preguntas frecuentes</a> ·
  <a href="#support">Apoyo ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="Arrastrando el tema Work por el mapa: los demás temas se apartan para hacerle sitio y cae donde quedó el hueco"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/#tour"><img src="docs/demo/intro-poster.jpg" width="100%" alt="Ver el recorrido por KIKUmap"></a></p>

## <a id="features"></a>Funciones

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="El icono de la barra de menús cuenta los chats en marcha con un anillo que gira, luego muestra una insignia roja de no leídos y después un signo de exclamación cuando un chat te espera"></td>
<td>

### 1. Estado en la barra de menús
Un anillo cuenta los chats en marcha. Una insignia roja cuenta los terminados sin leer, con **!** cuando uno te espera (para aprobar o responder, o porque se detuvo por un error). Si quieres, un sonido o una voz te dice qué chat ha terminado.

</td>
</tr>
<tr>
<td>

### 2. Los chats como un mapa
Los chats fijados en Claude y en la app de ChatGPT, más las sesiones de Claude Code, se alinean en la columna izquierda. Arrástralos a tus propios temas. Cada chat lleva la etiqueta **Claude** o **GPT**.

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="Seleccionando tres chats y arrastrándolos juntos a Side projects"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="Al hacer clic en la etiqueta In progress se resaltan los chats que la tienen; después la etiqueta se arrastra a un chat"></td>
<td>

### 3. Colores, formas y etiquetas
Dale a un tema un color y una forma. Etiqueta chats y haz clic en una etiqueta para resaltar todos los chats que la tienen. Arrastra el borde superior de las etiquetas para hacerlas más altas o más bajas, o guárdalas (⌃⌘G). En una ventana baja con zoom, se apartan hasta que haya sitio: haz la ventana más alta o pulsa ⌘-.

Settings → Colors (Ajustes → Colores) tiene ocho juegos de colores para toda la ventana (Classic, KIKU flower, Bauhaus black, Retro, Deep sea, Neon, Sunset, Candy), o elige cada color tú mismo.

</td>
</tr>
<tr>
<td>

### 4. Pensado para el teclado
⇥ subtema · ⏎ tema hermano · ⌥↑↓ mover · ⌘Z deshacer · ⌘F buscar · espacio abre un chat.

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab añade un subtema, Return añade un tema hermano, Opción-Flecha arriba lo mueve, Comando-Z lo deshace"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="La línea de tiempo: ejecuciones pasadas con sus horas y tareas programadas con cuenta atrás"></td>
<td>

### 5. Línea de tiempo
Cuándo se ejecutó cada chat y las próximas tareas programadas, con cuenta atrás.

</td>
</tr>
<tr>
<td>

### 6. Exportar e importar
Cada chat de Claude como archivos: un resumen, los prompts, la conversación y los artefactos. Impórtalos en otra cuenta de Claude.

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="La ventana de exportación y la carpeta de archivos Markdown y artefactos que genera"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget.png" width="100%" alt="Widgets de KIKUmap en tres tamaños: tiempo trabajado en las últimas 24 horas, uso y, en el grande, los chats más activos y los últimos 7 días"></td>
<td>

### 7. Widget de escritorio
Tiempo trabajado en las últimas 24 horas y los últimos 7 días, más el uso de Claude y ChatGPT con el nombre del plan. Tres tamaños, macOS 14 o posterior.

</td>
</tr>
<tr>
<td>

### 8. Estadísticas
Tiempo por chat y sesión en 7, 14, 30 o 90 días. ⌘Y.

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="Estadísticas: tiempo por chat y sesión en barras durante siete días"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="Los chats terminados se iluminan"><br><b>Los chats terminados se iluminan</b> en el mapa.</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="Búsqueda"><br><b>Busca</b> temas, chats y etiquetas.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="Today en el menú"><br><b>Today</b> (hoy): qué chats y sesiones trabajaron, y cuánto tiempo.</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="Usage en el menú"><br><b>Uso</b> de la sesión y de la semana.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="El mapa como PDF"><br><b>PDF</b> del mapa completo.</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="Copias de seguridad diarias"><br><b>Copias de seguridad diarias</b> del mapa.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="Claro u oscuro"><br><b>Claro u oscuro.</b></td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="Inglés y chino"><br><b>9 idiomas:</b> English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Português · Deutsch · Français</td>
</tr>
</table>

**Funciona con:** la app de escritorio de Claude · Claude Code (Terminal, VS Code, Cursor, el modo Code de la app) · la app de escritorio de ChatGPT · Codex en VS Code o en la terminal.

**Nativa y ligera:** solo Swift y AppKit. Sin Electron, sin vista web, sin código de terceros (iconos de línea de [Lucide](https://lucide.dev), ISC).

## <a id="install"></a>Instalación

1. [Descarga Kikumap.dmg](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg) (macOS 13 o posterior, Apple silicon e Intel) y arrastra KIKUmap a Aplicaciones.
2. La primera vez que la abras, macOS no podrá verificar la app (no está notarizada). Haz clic en **OK** y luego en **Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente**.
3. Permite **Accesibilidad** cuando te lo pida la introducción. Todo lo demás es opcional.
4. Fija chats en Claude o ChatGPT para seguirlos.

<details>
<summary>Compilar desde el código fuente</summary>

Necesitas las Xcode Command Line Tools.

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command` compila con `swiftc`, instala en `~/Applications` y firma con un certificado local, así que los permisos se mantienen entre compilaciones. `scripts/build-release.sh` crea la imagen de disco.
</details>

## <a id="privacy"></a>Privacidad

- Todo se queda en el Mac, en `~/Library/Application Support/ClaudeConsole/`.
- Solo hace falta un permiso: **Accesibilidad**, para leer las listas de chats en las ventanas de Claude y ChatGPT. Cada permiso se explica antes de que macOS lo pida.
- Sin peticiones de red, salvo las consultas de uso opcionales (desactivadas por defecto) a Anthropic y OpenAI. Esas consultas leen los inicios de sesión que Claude Code y Codex ya guardan en el Mac, y nunca los guardan. Ninguna de las dos empresas ha dicho que las apps puedan hacer esto, así que estas consultas podrían bloquearse.
- Exportar (con resúmenes) e Importar pegan a través del portapapeles. Lo que pega KIKUmap va marcado para que las apps de historial del portapapeles lo omitan y no pasa a tus otros dispositivos. Cada resumen llega mediante el propio botón Copiar de Claude, que una app de historial del portapapeles podría guardar. Tu portapapeles se restaura después de cada paso.

<details>
<summary>Para qué sirve cada fuente y cada permiso</summary>

| Muestra | Viene de | Permiso |
|---|---|---|
| Chats de Claude en marcha, sin leer y fijados | La barra lateral de la app de Claude | Accesibilidad |
| Claude esperándote (para aprobar o responder) y tareas de Cowork terminadas, también con la ventana de Claude cerrada (opcional) | Las notificaciones de Claude en el Centro de notificaciones | Acceso total al disco |
| Sesiones de Claude Code | Hooks de Claude Code en `~/.claude/settings.json` (con copia de seguridad previa) | ninguno |
| Chats de ChatGPT | Los archivos de la app de ChatGPT en `~/.codex` (solo lectura) | ninguno |
| En marcha, terminado y sin leer para los chats normales de ChatGPT (no Codex) | La barra lateral de la ventana de ChatGPT, mientras se vea parte de la ventana | Accesibilidad |
| Una sesión terminada que estás mirando cuenta como leída | Los títulos de ventana de su editor o terminal, mientras esa app está delante | Accesibilidad |
| Widget de escritorio | Un archivo que KIKUmap escribe para él (`widget.json`) | ninguno |
| Uso de Claude y tareas programadas (opcional) | La API de uso de Anthropic, con el inicio de sesión de Claude Code | Llavero |
| Uso de ChatGPT (opcional, experimental) | La interfaz de uso de OpenAI, con el inicio de sesión de Codex | ninguno |

ChatGPT: los chats de Codex tienen el mejor soporte (se leen de los archivos de la app, correctos incluso con la ventana cerrada). Los chats normales tienen menos soporte: se leen de la ventana de ChatGPT, solo mientras se ve parte de ella.

No se muestra: los chats sin fijar, ni nada que se ejecute en otro ordenador, en un servidor o en la nube.
</details>

<details>
<summary>Todos los atajos de teclado</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | nuevo tema hijo / nuevo tema padre |
| ⏎ / ⌥⏎ / ⇧⏎ | nuevo tema hermano debajo / encima / nuevo tema principal |
| ⌘⏎, doble clic | renombrar |
| ⌫ / ⌥⌫ | eliminar (los chats fijados se quedan en la columna izquierda) / eliminar solo el tema y conservar sus elementos (también con varios seleccionados) |
| ⌥. | contraer / expandir |
| ↑ ↓ ← → | seleccionar el elemento más cercano en esa dirección |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | mover arriba o abajo / mover de nivel |
| ⌘↓, toque de espacio | abrir el chat en su app |
| ⌘↑ | subir al tema que lo contiene |
| arrastrar en un espacio vacío, ⇧/⌘-clic | seleccionar varios |
| mantener espacio, deslizar con dos dedos | moverse por el mapa |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | columna izquierda / etiquetas / línea de tiempo |
| ↑ ↓ en la columna izquierda | elegir la fila de arriba o de abajo (el mapa también selecciona su chat) |
| ⏎, espacio en la columna izquierda | abrir el chat en su app |
| ⌘Y | estadísticas |
| ⌘R | actualizar |
| ⌘Z / ⇧⌘Z | deshacer / rehacer |
| ⌘F | buscar |
| ⌘E / ⇧⌘E | mapa como PDF / exportar chats |
| ⇧⌘U | marcar como no leído / leído |
| ⌘+ / ⌘- / pellizcar / ⌘0 | más grande / más pequeño / zoom / ajustar |
| ⌃⌥C (se puede cambiar, pero no a los propios ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H de KIKUmap) | mostrar u ocultar el mapa desde cualquier lugar |
</details>

## <a id="faq"></a>Preguntas frecuentes

<details>
<summary><b>¿Lo ha hecho Anthropic u OpenAI?</b></summary>

No. KIKUmap es un proyecto independiente y de código abierto. La app de Claude no tiene una API pública, así que KIKUmap lee su ventana mediante Accesibilidad; una actualización de Claude o ChatGPT puede romper partes de KIKUmap hasta que se ponga al día.
</details>

<details>
<summary><b>¿Por qué «Abrir igualmente»?</b></summary>

Notarizar requiere una cuenta de desarrollador de Apple de pago, y KIKUmap es gratis. También puedes compilarlo desde el código fuente: Swift puro, sin dependencias.
</details>

<details>
<summary><b>La ventana de Claude está cerrada. ¿Qué pasa?</b></summary>

⌘W solo la oculta. KIKUmap lee los chats de Claude desde la ventana, así que no los ve hasta que la ventana vuelve al escritorio actual; mientras tanto, los chats en marcha muestran "running?" (¿en marcha?). Cuando vuelve, uno que encuentre terminado dice "done after 14:00" (terminado después de las 14:00, la última vez que se vio en marcha), porque no se sabe cuándo terminó. Los chats de Claude Code y Codex no se ven afectados. Los chats normales de ChatGPT se leen de la ventana de ChatGPT de la misma forma, mientras se ve parte de ella.
</details>

<details>
<summary><b>Una sesión terminó mientras la miraba. ¿Por qué sigue sin leer?</b></summary>

KIKUmap marca como leída una sesión terminada por su cuenta solo cuando la ventana que está delante no puede ser otra que la de esa sesión: para Claude Code, la ventana de su carpeta en VS Code o Cursor, o una ventana de terminal cuyo título muestre tanto su carpeta como `claude`; para Codex, la ventana de su carpeta en VS Code. Si otra ventana o pestaña también pudiera estar mostrándola, como otra ventana del editor con su carpeta o una carpeta superior, sigue sin leer. Las sesiones de Codex en una terminal también siguen sin leer (KIKUmap no puede saber qué terminal las ejecuta). Ábrela desde KIKUmap, o selecciónala y pulsa ⇧⌘U, para marcarla como leída.
</details>

<details>
<summary><b>Algo no aparece</b></summary>

- **▸ To-do** (pendientes) en la barra superior lista lo que falta, con un botón para cada cosa.
- Chats de Claude: fíjalos y mantén abierta la barra lateral de Claude en Chat con Pinned desplegado.
- Claude Code: Settings → Access → Claude Code → **Connect** (Ajustes → Acceso → Claude Code → Conectar) y luego inicia una sesión nueva.
- Widget: macOS 14 o posterior, con KIKUmap en Aplicaciones. Haz clic derecho en el escritorio → **Editar widgets**.
- ¿Sigue sin funcionar? Settings → Access → **Diagnostic report** (Ajustes → Acceso → Informe de diagnóstico; no incluye títulos ni mensajes de chats) y [abre un issue](https://github.com/tang1693/KIKUmap/issues).
</details>

<details>
<summary><b>¿Por qué ese nombre?</b></summary>

*Kiku* (菊) significa crisantemo en japonés: la florecita de la barra de menús.
</details>

## Contribuir

Los issues y pull requests son bienvenidos, sobre todo cuando una actualización de Claude o ChatGPT rompe algo. Consulta la [guía de contribución](.github/CONTRIBUTING.md) y el [código de conducta](.github/CODE_OF_CONDUCT.md); los problemas de seguridad se comunican según la [política de seguridad](.github/SECURITY.md).

## <a id="support"></a>Apoyo

KIKUmap es gratis. Si te resulta útil, un café ayuda a que siga adelante ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-en.svg" height="64" alt="Invítame a un café en Ko-fi"></a></p>

## Licencia

[MIT](LICENSE). Claude es una marca registrada de Anthropic y ChatGPT, de OpenAI; este proyecto es independiente y no cuenta con el respaldo de ninguna de las dos.
