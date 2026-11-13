# DeadNoise

> Antes chamado VolMix. A pasta do projeto, o alvo do SwiftPM, o identificador do app e os UIDs do driver mantêm o nome antigo.

Logo em `Resources/logo/` (SVG).

Site: https://deadnoise.vercel.app (código em `site/`).

App de barra de menu para macOS (15+) que controla o volume de saída de cada app separadamente
(ex.: Teams e Google Meet em calls ao mesmo tempo).

## Instalar

Os dois downloads são assinados com Developer ID e notarizados pela Apple:

- [DeadNoise.dmg](https://github.com/wellmota/deadnoise/releases/latest/download/DeadNoise.dmg): abra, arraste o app
  para Aplicativos e, no menu do app, ligue "Cancelar meu ruído" > "Instalar microfone virtual" (pede a senha).
- [DeadNoise.pkg](https://github.com/wellmota/deadnoise/releases/latest/download/DeadNoise.pkg): instalador do macOS
  que já coloca o app em Aplicativos e o driver em `/Library/Audio/Plug-Ins/HAL`.

Nos dois casos o áudio do Mac reinicia por alguns segundos quando o driver entra.

Requisitos: macOS 15 ou mais novo. A transcrição exige o macOS 26.

Para remover: `./uninstall.sh` (ou apague `/Applications/DeadNoise.app` e
`/Library/Audio/Plug-Ins/HAL/VolMixAudio.driver` e reinicie o Mac).

Do código:

```bash
git clone https://github.com/wellmota/deadnoise && cd deadnoise
./build.sh install           # app
./Driver/build.sh install    # microfone virtual (pede senha, reinicia o áudio)
```

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

## Publicar uma versão

1. Aumente `CFBundleShortVersionString` **e** `CFBundleVersion` em `Resources/Info.plist`. O app instalado só
   reconhece a versão nova se o `CFBundleVersion` for maior (o `release.sh` recusa se não for).
   Mudou o driver (`Driver/`)? Aumente também o `CFBundleVersion` de `Driver/Info.plist`: o app compara com o
   driver instalado e oferece "Atualizar microfone virtual".
2. Escreva as notas em `release-notes/<versão>.md` (Markdown curto). Elas aparecem na janela de atualização e no GitHub.
3. Commit e `git push`.
4. `./release.sh` gera `dist/DeadNoise.dmg`, `dist/DeadNoise.pkg` (universais, assinados com Developer ID e
   notarizados) e `dist/appcast.xml` (a lista de versões, assinada). Os pré-requisitos estão no topo do script.
5. `./publish.sh` confere tudo (commit no GitHub, versão, assinaturas, notarização) e cria o release `vX.Y.Z`.
   Os apps instalados encontram a versão nova na próxima procura diária, e o download do site já aponta para ela.

### Atualização automática (Sparkle)

O app usa o [Sparkle](https://sparkle-project.org) (versão fixa em `Package.swift`). Ele lê o `appcast.xml` do
release mais recente do GitHub e só aceita uma atualização com a assinatura EdDSA da chave do projeto
(`SUPublicEDKey` no `Info.plist`) e com o próprio appcast assinado (`SURequireSignedFeed`).

A chave privada fica nas Chaves do Mac de quem publica, na conta `deadnoise`. **Sem ela não dá para publicar
atualizações para quem já tem o app.** Guarde uma cópia num gerenciador de senhas:

    .build/artifacts/sparkle/Sparkle/bin/generate_keys --account deadnoise -x deadnoise-sparkle.key

(e apague o arquivo depois de guardar). Para usar em outro Mac: `generate_keys --account deadnoise -f deadnoise-sparkle.key`.

O site (`site/`) é publicado pela Vercel a cada push na `main`.

`./package.sh` gera um zip com assinatura genérica, para testar sem a conta de desenvolvedor.

Pendências em `TODO.md`.

## Licença

MIT. Veja `LICENSE`.
