# DeadNoise

> Antes chamado VolMix. A pasta do projeto, o alvo do SwiftPM, o identificador do app e os UIDs do driver mantêm o nome antigo.

Logo em `Resources/logo/` (SVG).

Site: https://deadnoise.vercel.app (código em `site/`).

App de barra de menu para macOS (15+) que controla o volume de saída de cada app separadamente
(ex.: Teams e Google Meet em calls ao mesmo tempo).

## Instalar

Requisitos: macOS 15 ou mais novo em Apple Silicon. A transcrição exige o macOS 26.

Do código (recomendado enquanto não houver versão notarizada):

```bash
git clone <url-do-repositório> && cd <pasta>
./build.sh install           # app
./Driver/build.sh install    # microfone virtual (pede senha, reinicia o áudio)
```

O zip dos Releases não é notarizado pela Apple: o macOS bloqueia na primeira abertura e é preciso
liberar em Ajustes > Privacidade e Segurança.

Gravar chamadas pode exigir o consentimento dos participantes, conforme a lei do seu país.

## Recursos

- **Volume por app** (0–150%) e mudo por app.
- **Cancelar meu ruído**: o DeadNoise lê o seu microfone, remove o ruído com o isolamento de voz da Apple
  (`AUSoundIsolation`, no aparelho) e entrega o resultado no microfone virtual **DeadNoise Microphone**.
  No app da chamada, escolha esse microfone. Só processa enquanto algum app está usando o microfone
  virtual; o atraso fica em torno de 0,1 s. Exige o driver (veja abaixo).
- **Chamada detectada**: mostra quais apps estão com o microfone aberto e avisa por notificação.
- **Mudo do microfone** pelo menu, com aviso quando você está no mudo durante uma chamada.
- **Gravar e transcrever**: grava o áudio do Mac ("Outros") e o seu microfone ("Eu") em trilhas
  separadas e gera `transcricao.md` em `~/Documents/DeadNoise/<data> <app>/`. A transcrição roda no
  aparelho (macOS 26+); o resumo usa o modelo local e só aparece com a Apple Intelligence ativada.
- **Gravar chamadas automaticamente**: começa quando um app abre o microfone e para ~6 s depois que fecha.

## Build

```bash
./build.sh          # gera build/DeadNoise.app
./build.sh install  # instala em /Applications e abre
```

Também dá para abrir `Package.swift` no Xcode.

### Driver do microfone virtual

```bash
./Driver/build.sh install    # pede a senha e reinicia o áudio do Mac por alguns segundos
./Driver/build.sh uninstall  # remove
```

O driver (`Driver/VolMixAudio.c`) publica o "DeadNoise Microphone" e um dispositivo oculto, "DeadNoise App IO".
O que o DeadNoise toca no App IO aparece no microfone. Com o DeadNoise fechado, o microfone virtual fica em silêncio.

## Como funciona

Usa **Core Audio Process Taps** (macOS 14.2+): para cada app com volume ≠ 100%, cria um tap que
silencia o áudio original, junta o tap com a saída atual num aggregate device privado e toca de novo
com o ganho aplicado (0–150%). Em 100% o tap é removido, e o áudio do app fica intocado.

- Processos auxiliares (ex.: "Google Chrome Helper") são agrupados no app principal.
- Volumes ficam salvos por app e são reaplicados quando o app volta a tocar.
- Ao trocar de fone/alto-falante, os taps são recriados no novo dispositivo.

## Limitações

- Se o "DeadNoise Microphone" estiver escolhido num app e o DeadNoise estiver fechado (ou com "Cancelar meu
  ruído" desligado), o app recebe silêncio.
- Em Entrada, mantenha o microfone de verdade: o "DeadNoise Microphone" é só para os apps de chamada.
- A gravação pega todo o áudio do Mac, não só o do app da chamada.
- Sem fone, o microfone também capta a voz dos outros, e ela pode aparecer duplicada como "Eu".
- A detecção de chamada é "algum app está usando o microfone" (ditado e gravadores também contam).

- O controle é **por app, não por aba**: todas as abas do Chrome compartilham um processo de áudio.
  Para separar o Meet, use outro navegador (Safari, Arc, Edge…) só para ele.
- Na primeira vez o macOS pede a permissão **Gravação de Tela e Áudio do Sistema**. Se um app ficar
  mudo ao mexer no slider, confira essa permissão em Ajustes > Privacidade e Segurança.

## Licença

MIT. Veja `LICENSE`.
