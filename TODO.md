# Pendências

- [ ] Testar num Mac limpo (Apple Silicon e Intel): o `.dmg`, o botão "Instalar microfone virtual" do app
      (pede senha de administrador) e o `.pkg`.
- [ ] Confirmar que volume por app e gravação funcionam na versão notarizada (hardened runtime).
- [ ] Esconder o microfone virtual quando o app estiver fechado (hoje ele entrega silêncio). Mexe no driver:
      só publicar depois de testar instalando, porque um erro aqui deixa o microfone invisível.
- [ ] Atualização automática (Sparkle) e fórmula do Homebrew.
- [ ] Afastar mais a logo da referência original.

## Feito

- [x] Imagem de disco (.dmg) com arte de fundo e atalho de Aplicativos, assinada e notarizada.
- [x] O app instala o driver do microfone virtual sozinho (para quem usa o .dmg).
- [x] Vercel conectada ao GitHub: o site atualiza a cada push.
- [x] Busca pelo nome "DeadNoise": nenhum app ou marca com esse nome apareceu (busca simples na web,
      não substitui uma consulta formal de marcas).
