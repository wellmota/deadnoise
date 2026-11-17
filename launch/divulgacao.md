# Divulgação do DeadNoise

Textos prontos para colar. Cada um leva direto ao repositório: https://github.com/wellmota/deadnoise
## Comece por aqui: r/macapps e Show HN

Faça os dois em dias diferentes, para conseguir responder tudo com calma.

### Antes de postar (uma vez só)

- [ ] Grave um GIF ou vídeo de 10–20 s: barulho de teclado com "Kill my noise" desligado e depois ligado.
      É o que mais convence no Reddit (o HN não aceita imagem, então lá não precisa).
- [ ] Teste o download do zero (`DeadNoise.dmg` > Aplicativos > "Install virtual microphone"), porque é o
      que todo mundo vai fazer primeiro.
- [ ] Reserve 2–3 horas livres depois de postar. Responder rápido é o que mantém o post subindo.

### Dia 1: r/macapps

1. O sub limita autopromoção. Pelo que sites de terceiros contam (confira na barra lateral e no wiki do sub,
   que podem ter mudado): é preciso ter **10 de karma no próprio r/macapps** (ganhe comentando em outros posts
   alguns dias antes), no máximo **1 post a cada 30 dias** por desenvolvedor, e alguns posts precisam de
   aprovação dos moderadores. Se não se encaixar, o lugar é o megathread mensal de autopromoção.
2. Escolha a flair de app grátis/open source e use o título no formato `[OS] DeadNoise — ...` (abaixo).
3. Deixe claro no texto que você é o desenvolvedor.
4. Poste numa terça, quarta ou quinta, entre 9h e 11h no horário de Brasília (manhã nos EUA).
5. Anexe o GIF/vídeo no próprio post e coloque o link do GitHub no texto.

### Dia 2 ou 3: Show HN

1. Use uma conta do HN que já tenha algum histórico (comentários). Conta nova costuma ter post filtrado.
2. Em https://news.ycombinator.com/submit: título abaixo, URL = link do GitHub, campo de texto vazio.
3. Assim que o post aparecer, publique o "primeiro comentário" abaixo como resposta.
4. Melhor horário: terça a quinta, 9h–11h no horário de Brasília.
5. **Não peça upvote para ninguém**, nem em grupo de amigos. O HN detecta e derruba o post.
6. Se não pegar, os moderadores às vezes repescam bons Show HN. Dá para escrever para hn@ycombinator.com
   pedindo para considerarem o "second chance pool".

### Respondendo comentários

- Agradeça a crítica e responda com fatos; não discuta.
- Pergunta comum esperada: "por que não usar o Isolamento de Voz da Central de Controle?" → ele só aparece para
  apps que usam o processamento de voz do próprio macOS; o DeadNoise vira um microfone que qualquer app enxerga.
  (Antes de postar, confira em quais dos seus apps de chamada ele aparece, para responder com exemplos reais.)
- Pergunta comum: "é seguro instalar um driver?" → é um driver de áudio (HAL plug-in) open source, assinado e
  notarizado pela Apple; `./uninstall.sh` remove tudo.
- Bug reportado no comentário? Peça para abrir uma issue e responda com o link.

## Hacker News (Show HN)

Enviar em https://news.ycombinator.com/submit, com o link do GitHub (não do site).

**Título:** Show HN: DeadNoise – Free, open-source mic noise cancellation for macOS

**Primeiro comentário:**

> I didn't want to pay a subscription (or send my voice to someone's cloud) just to keep my keyboard and fan off calls.
> macOS already ships a good on-device voice isolation model (AUSoundIsolation), but only some apps use it.
> DeadNoise is a menu bar app that runs your real mic through it and exposes the result as a virtual microphone,
> "DeadNoise Microphone", via a small Core Audio HAL driver. Pick it in Meet, Zoom or Teams. It only processes
> while some app is reading the virtual mic, and adds ~0.1 s of latency.
>
> It also does per-app volume (0–150%) with Core Audio process taps, per-tab volume in Chromium browsers through
> an extension, and local meeting recording/transcription split into "Me" and "Others".
>
> Swift, MIT, signed and notarized, Sparkle updates. Limits: it cleans your mic, not other people's audio; macOS 15+.
> Happy to answer questions about process taps and HAL drivers, there were plenty of sharp edges (AirPods switching
> to call mode mid-stream was a fun one).

## Reddit

Subreddits: r/macapps (o principal), r/MacOS, r/opensource, r/swift (foco técnico), r/brdev (em português).
Leia as regras de cada um antes: alguns pedem flair "Self-promotion" ou só aceitam em dias específicos.

**r/macapps — título:** [OS] DeadNoise — free, on-device noise cancellation for your Mac's mic (Meet, Zoom, Teams)

> I'm the developer. DeadNoise is a menu bar app that removes background noise from your microphone using Apple's on-device voice
> isolation, so it works in any call app: you pick "DeadNoise Microphone" as your mic and that's it.
> No account, no subscription, nothing leaves your Mac.
>
> It also has per-app volume (turn Spotify down without turning the meeting down), per-tab volume in Chrome,
> and local meeting recording + transcription.
>
> Free, MIT-licensed, signed and notarized: https://github.com/wellmota/deadnoise
> Feedback welcome, especially with Bluetooth headsets.

**r/brdev — título:** Fiz um app open source pra tirar o ruído do microfone no Mac (Meet, Zoom, Teams), sem nuvem

> Cansei de pagar assinatura pra cortar barulho de teclado e ventilador nas calls. O macOS já tem um modelo de
> isolamento de voz que roda no aparelho, mas só alguns apps usam. O DeadNoise pega o seu microfone, passa por esse
> modelo e entrega num microfone virtual ("DeadNoise Microphone") feito com um driver HAL do Core Audio.
>
> De brinde: volume por app (0–150%) com process taps, volume por aba no Chrome e gravação/transcrição local de reunião.
> Swift, MIT, assinado e notarizado: https://github.com/wellmota/deadnoise
> Aceito críticas e PRs.

## TabNews

Mesmo texto do r/brdev, com um pouco mais de detalhe técnico (process taps, driver HAL, o bug dos AirPods
mudando para o modo de chamada). O TabNews valoriza post que ensina algo.

## X / LinkedIn

Poste com um vídeo curto (10–20 s): um áudio com teclado batendo, liga "Kill my noise", o barulho some.

> Built a free, open-source alternative to paid noise cancellation apps for Mac.
> Your mic → Apple's on-device voice isolation → "DeadNoise Microphone". Works in Meet, Zoom, Teams.
> No account, no cloud. MIT. ⭐ https://github.com/wellmota/deadnoise

## Listas "awesome" (Pull Request)

Leia o CONTRIBUTING de cada uma e siga o formato exato da lista.

- https://github.com/serhii-londar/open-source-mac-os-apps — seção "Audio"
- https://github.com/jaywcjlove/awesome-mac — seção de áudio (marcam apps open source com um ícone)

Linha sugerida:

> [DeadNoise](https://github.com/wellmota/deadnoise) - Noise cancellation for your microphone, per-app volume and meeting transcription, on-device.

## Comunidade

- Criar 2–3 issues com a etiqueta `good first issue` (ex.: tradução para outro idioma; publicar a extensão na Chrome Web Store).
- Ativar Discussions para perguntas que não são bug.
