<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.png">
  <img src="docs/banner-en-light.png" width="100%" alt="KIKUmap: um mapa mental para suas conversas no Claude e no ChatGPT">
</picture>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <b>Português</b> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a></p>

<p align="center">Um mapa mental para suas conversas no Claude e no ChatGPT, na barra de menus do Mac.<br>Veja o que está rodando, o que terminou e o que precisa de você.</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-en.svg" height="56" alt="Baixar o KIKUmap para macOS"></a>&nbsp;&nbsp;<a href="https://tang1693.github.io/KIKUmap/?lang=pt-BR"><img src="docs/website-en.svg" height="56" alt="Visitar o site do KIKUmap"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=version&color=187DFE" alt="Versão mais recente"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 ou posterior">
  <img src="https://img.shields.io/badge/languages-9-7A5AF8" alt="9 languages">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift, sem dependências">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="Licença MIT"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="Estrelas no GitHub"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white" alt="Apoie no Ko-fi"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/?lang=pt-BR">Site</a> ·
  <a href="#features">Recursos</a> ·
  <a href="#install">Instalação</a> ·
  <a href="#privacy">Privacidade</a> ·
  <a href="#faq">Perguntas frequentes</a> ·
  <a href="#support">Apoie ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="Arrastando o tópico Work pelo mapa: os outros tópicos se afastam para abrir espaço e ele cai onde ficou o vão"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/#tour"><img src="docs/demo/intro-poster.jpg" width="100%" alt="Assista ao tour do KIKUmap"></a></p>

## <a id="features"></a>Recursos

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="O ícone da barra de menus contando as conversas em andamento com um anel girando, depois um selo vermelho de não lidas e, por fim, um ponto de exclamação quando uma conversa está esperando por você"></td>
<td>

### 1. Status na barra de menus
Um anel conta as conversas em andamento. Um selo vermelho conta as que terminaram e ainda não foram lidas, com **!** quando alguma está esperando por você (para aprovar ou responder, ou porque parou em um erro). Um som ou uma voz opcional diz qual conversa terminou.

</td>
</tr>
<tr>
<td>

### 2. Conversas como um mapa
As conversas fixadas no Claude e no app do ChatGPT, além das sessões do Claude Code, ficam alinhadas na coluna da esquerda. Arraste-as para os seus próprios tópicos. Cada conversa recebe a etiqueta **Claude** ou **GPT**.

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="Selecionando três conversas e arrastando todas juntas para Side projects"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="Clicar na etiqueta In progress destaca as conversas que a têm; depois a etiqueta é arrastada para uma conversa"></td>
<td>

### 3. Cores, formas e etiquetas
Dê uma cor e uma forma a um tópico. Coloque etiquetas nas conversas e clique em uma etiqueta para destacar todas as conversas que a têm. Arraste a borda superior das etiquetas para deixá-las mais altas ou mais baixas, ou guarde-as (⌃⌘G). Em uma janela baixa com zoom, elas saem do caminho até haver espaço: deixe a janela mais alta ou pressione ⌘-.

Settings → Colors (Ajustes → Cores) tem oito conjuntos de cores para a janela inteira (Classic, KIKU flower, Bauhaus black, Retro, Deep sea, Neon, Sunset, Candy), ou você pode escolher cada cor.

</td>
</tr>
<tr>
<td>

### 4. Feito para o teclado
⇥ subtópico · ⏎ tópico irmão · ⌥↑↓ mover · ⌘Z desfazer · ⌘F buscar · espaço abre uma conversa.

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab adiciona um subtópico, Return adiciona um tópico irmão, Option-Seta para cima o move, Command-Z desfaz"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="A linha do tempo: execuções anteriores com seus horários e tarefas agendadas com contagem regressiva"></td>
<td>

### 5. Linha do tempo
Quando cada conversa rodou e as próximas tarefas agendadas, com contagem regressiva.

</td>
</tr>
<tr>
<td>

### 6. Exportar e importar
Cada conversa do Claude como arquivos: um resumo, os prompts, a conversa e os artefatos. Importe-os em outra conta do Claude.

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="A janela de exportação e a pasta de arquivos Markdown e artefatos que ela gera"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget.png" width="100%" alt="Widgets do KIKUmap em três tamanhos: tempo trabalhado nas últimas 24 horas, uso e, no grande, as conversas mais ativas e os últimos 7 dias"></td>
<td>

### 7. Widget de mesa
Tempo trabalhado nas últimas 24 horas e nos últimos 7 dias, além do uso do Claude e do ChatGPT com o nome do plano. Três tamanhos, macOS 14 ou posterior.

</td>
</tr>
<tr>
<td>

### 8. Estatísticas
Tempo por conversa e sessão em 7, 14, 30 ou 90 dias. ⌘Y.

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="Estatísticas: tempo por conversa e sessão em barras ao longo de sete dias"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="Conversas concluídas se acendem"><br><b>Conversas concluídas se acendem</b> no mapa.</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="Busca"><br><b>Busque</b> tópicos, conversas e etiquetas.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="Today no menu"><br><b>Today</b> (hoje): quais conversas e sessões trabalharam, e por quanto tempo.</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="Usage no menu"><br><b>Uso</b> da sessão e da semana.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="O mapa em PDF"><br><b>PDF</b> do mapa inteiro.</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="Backups diários"><br><b>Backups diários</b> do mapa.</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="Claro ou escuro"><br><b>Claro ou escuro.</b></td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="Inglês e chinês"><br><b>9 idiomas:</b> English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Português · Deutsch · Français</td>
</tr>
</table>

**Funciona com:** o app de desktop do Claude · Claude Code (Terminal, VS Code, Cursor, o modo Code do app) · o app de desktop do ChatGPT · Codex no VS Code ou no terminal.

**Nativo e leve:** só Swift e AppKit. Sem Electron, sem web view, sem código de terceiros (ícones de linha do [Lucide](https://lucide.dev), ISC).

## <a id="install"></a>Instalação

1. [Baixe o Kikumap.dmg](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg) (macOS 13 ou posterior, Apple silicon e Intel) e arraste o KIKUmap para Aplicativos.
2. Na primeira abertura, o macOS não consegue verificar o app (ele não é notarizado). Clique em **OK** e depois em **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim**.
3. Permita **Acessibilidade** quando a introdução pedir. Todo o resto é opcional.
4. Fixe conversas no Claude ou no ChatGPT para acompanhá-las.

<details>
<summary>Compilar a partir do código-fonte</summary>

Requer as Xcode Command Line Tools.

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command` compila com `swiftc`, instala em `~/Applications` e assina com um certificado local, para que as permissões sobrevivam a novas compilações. `scripts/build-release.sh` gera a imagem de disco.
</details>

## <a id="privacy"></a>Privacidade

- Tudo fica no Mac, em `~/Library/Application Support/ClaudeConsole/`.
- Uma permissão é obrigatória: **Acessibilidade**, para ler as listas de conversas nas janelas do Claude e do ChatGPT. Cada permissão é explicada antes de o macOS pedir.
- Nenhuma requisição de rede, exceto as consultas de uso opcionais (desativadas por padrão) à Anthropic e à OpenAI. Elas leem os logins que o Claude Code e o Codex já guardam no Mac, e nunca os salvam. Nenhuma das duas empresas disse que apps podem fazer isso, então essas consultas podem ser bloqueadas.
- Exportar (com resumos) e Importar colam pela área de transferência. O que o KIKUmap cola é marcado para que apps de histórico da área de transferência o ignorem e não vai para os seus outros dispositivos. Cada resumo passa pelo próprio botão Copiar do Claude, que um app de histórico da área de transferência pode guardar. Sua área de transferência é restaurada depois de cada etapa.

<details>
<summary>Para que serve cada fonte e permissão</summary>

| Mostra | Vem de | Permissão |
|---|---|---|
| Conversas do Claude em andamento, não lidas e fixadas | A barra lateral do app do Claude | Acessibilidade |
| Claude esperando por você (para aprovar ou responder) e tarefas do Cowork concluídas, mesmo com a janela do Claude fechada (opcional) | As notificações do Claude na Central de Notificações | Acesso Total ao Disco |
| Sessões do Claude Code | Hooks do Claude Code em `~/.claude/settings.json` (com backup antes) | nenhuma |
| Conversas do ChatGPT | Os arquivos do app do ChatGPT em `~/.codex` (somente leitura) | nenhuma |
| Em andamento, concluída e não lida para conversas comuns do ChatGPT (não Codex) | A barra lateral da janela do ChatGPT, enquanto parte da janela estiver visível | Acessibilidade |
| Uma sessão concluída que você está olhando conta como lida | Os títulos de janela do editor ou terminal dela, enquanto esse app estiver na frente | Acessibilidade |
| Widget de mesa | Um arquivo que o KIKUmap escreve para ele (`widget.json`) | nenhuma |
| Uso do Claude e tarefas agendadas (opcional) | A API de uso da Anthropic, com o login do Claude Code | Chaves |
| Uso do ChatGPT (opcional, experimental) | A interface de uso da OpenAI, com o login do Codex | nenhuma |

ChatGPT: as conversas do Codex têm o melhor suporte (lidas dos arquivos do app, corretas mesmo com a janela fechada). As conversas comuns têm suporte menor: são lidas da janela do ChatGPT, só enquanto parte dela estiver visível.

Não aparece: conversas não fixadas, nem nada rodando em outro computador, em um servidor ou na nuvem.
</details>

<details>
<summary>Todos os atalhos de teclado</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | novo tópico filho / novo tópico pai |
| ⏎ / ⌥⏎ / ⇧⏎ | novo tópico irmão abaixo / acima / novo tópico principal |
| ⌘⏎, clique duplo | renomear |
| ⌫ / ⌥⌫ | apagar (conversas fixadas ficam na coluna da esquerda) / apagar só o tópico, mantendo seus itens (também com vários selecionados) |
| ⌥. | recolher / expandir |
| ↑ ↓ ← → | selecionar o item mais próximo naquela direção |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | mover para cima ou para baixo / mudar de nível |
| ⌘↓, toque no espaço | abrir a conversa no app dela |
| ⌘↑ | subir para o tópico em que está |
| arrastar em espaço vazio, ⇧/⌘-clique | selecionar vários |
| segurar espaço, deslizar com dois dedos | percorrer o mapa |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | coluna da esquerda / etiquetas / linha do tempo |
| ↑ ↓ na coluna da esquerda | escolher a linha de cima ou de baixo (o mapa também seleciona a conversa) |
| ⏎, espaço na coluna da esquerda | abrir a conversa no app dela |
| ⌘Y | estatísticas |
| ⌘R | atualizar |
| ⌘Z / ⇧⌘Z | desfazer / refazer |
| ⌘F | buscar |
| ⌘E / ⇧⌘E | mapa em PDF / exportar conversas |
| ⇧⌘U | marcar como não lida / lida |
| ⌘+ / ⌘- / pinça / ⌘0 | maior / menor / zoom / ajustar |
| ⌃⌥C (pode ser alterado, mas não para os próprios ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H do KIKUmap) | mostrar ou ocultar o mapa de qualquer lugar |
</details>

## <a id="faq"></a>Perguntas frequentes

<details>
<summary><b>Isto é feito pela Anthropic ou pela OpenAI?</b></summary>

Não. O KIKUmap é um projeto independente e de código aberto. O app do Claude não tem API pública, então o KIKUmap lê a janela dele por meio da Acessibilidade; uma atualização do Claude ou do ChatGPT pode quebrar partes dele até o KIKUmap se atualizar.
</details>

<details>
<summary><b>Por que "Abrir Mesmo Assim"?</b></summary>

Notarizar exige uma conta paga de desenvolvedor da Apple, e o KIKUmap é gratuito. Compilar a partir do código-fonte também funciona: Swift puro, sem dependências.
</details>

<details>
<summary><b>A janela do Claude está fechada. O que acontece?</b></summary>

⌘W só a oculta. O KIKUmap lê as conversas do Claude pela janela, então não consegue vê-las até a janela voltar para a mesa atual; enquanto isso, as conversas em andamento mostram "running?" (rodando?). Quando ela volta, uma que estiver concluída mostra "done after 14:00" (concluída depois das 14:00, a última vez que foi vista rodando), já que não se sabe quando terminou. As conversas do Claude Code e do Codex não são afetadas. As conversas comuns do ChatGPT são lidas da janela do ChatGPT do mesmo jeito, enquanto parte dela estiver visível.
</details>

<details>
<summary><b>Uma sessão terminou enquanto eu olhava. Por que ainda está como não lida?</b></summary>

O KIKUmap marca sozinho uma sessão concluída como lida só quando a janela da frente só pode ser dessa sessão: no Claude Code, a janela da pasta dela no VS Code ou no Cursor, ou uma janela de terminal cujo título mostre a pasta e `claude`; no Codex, a janela da pasta dela no VS Code. Se outra janela ou aba também puder estar mostrando a sessão, como outra janela do editor na mesma pasta ou em uma pasta acima, ela continua não lida. Sessões do Codex em um terminal também continuam não lidas (o KIKUmap não tem como saber qual terminal as executa). Abra-a pelo KIKUmap, ou selecione-a e pressione ⇧⌘U, para marcá-la como lida.
</details>

<details>
<summary><b>Algo não está aparecendo</b></summary>

- **▸ To-do** (pendências) na barra superior lista o que está faltando, com um botão para cada item.
- Conversas do Claude: fixe-as e mantenha a barra lateral do Claude aberta em Chat, com Pinned expandido.
- Claude Code: Settings → Access → Claude Code → **Connect** (Ajustes → Acesso → Claude Code → Conectar) e depois inicie uma nova sessão.
- Widget: macOS 14 ou posterior, com o KIKUmap em Aplicativos. Clique com o botão direito na mesa → **Editar Widgets**.
- Ainda com problema? Settings → Access → **Diagnostic report** (Ajustes → Acesso → Relatório de diagnóstico; sem títulos nem mensagens de conversas) e [abra uma issue](https://github.com/tang1693/KIKUmap/issues).
</details>

<details>
<summary><b>Por que esse nome?</b></summary>

*Kiku* (菊) é crisântemo em japonês: a florzinha na barra de menus.
</details>

## Contribuindo

Issues e pull requests são bem-vindos, principalmente quando uma atualização do Claude ou do ChatGPT quebra algo. Veja o [guia de contribuição](.github/CONTRIBUTING.md) e o [código de conduta](.github/CODE_OF_CONDUCT.md); problemas de segurança seguem a [política de segurança](.github/SECURITY.md).

## <a id="support"></a>Apoie

O KIKUmap é gratuito. Se ele te ajuda, um café mantém o projeto vivo ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-en.svg" height="64" alt="Me pague um café no Ko-fi"></a></p>

## Licença

[MIT](LICENSE). Claude é uma marca registrada da Anthropic e ChatGPT, da OpenAI; este projeto é independente e não é endossado por nenhuma delas.
