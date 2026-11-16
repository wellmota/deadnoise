#!/bin/sh
# Host de native messaging da extensão "DeadNoise: volume por aba".
# O navegador abre este script quando a extensão conecta; ele só liga a entrada/saída padrão ao socket
# local do DeadNoise, que entende o formato do native messaging (tamanho de 4 bytes + JSON).
# Se o DeadNoise estiver fechado, o nc sai na hora e a extensão tenta de novo mais tarde.
exec /usr/bin/nc -U "$HOME/Library/Application Support/DeadNoise/browser.sock"
