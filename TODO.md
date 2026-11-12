# Pendências

- [ ] **Imagem de disco (.dmg) com arte de fundo**: janela que abre ao montar, com o ícone do DeadNoise,
      a seta e o atalho de Aplicativos para arrastar, no visual da marca (creme, preto e vermelho).
      Atenção: arrastar o app não instala o driver do microfone virtual, que precisa de senha de
      administrador. Opções: (a) o .dmg leva o app e o app instala o driver na primeira abertura;
      (b) o .dmg com a arte leva o `DeadNoise.pkg` dentro. Assinar e notarizar o .dmg.
- [ ] Testar o instalador `.pkg` num Mac limpo (Apple Silicon e Intel).
- [ ] Confirmar que volume por app e gravação funcionam na versão notarizada (hardened runtime).
- [ ] Esconder o microfone virtual quando o app estiver fechado (hoje ele entrega silêncio).
- [ ] Atualização automática (Sparkle) e fórmula do Homebrew.
- [ ] Conectar a Vercel ao GitHub para o site atualizar a cada push.
- [ ] Checar o nome "DeadNoise" contra marcas existentes e afastar mais a logo da referência.
