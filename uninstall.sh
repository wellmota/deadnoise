#!/bin/bash
# Remove o DeadNoise e o driver do microfone virtual (pede a senha do Mac e reinicia o áudio).
set -euo pipefail
pkill -x DeadNoise 2>/dev/null || true
sudo /bin/rm -rf /Applications/DeadNoise.app /Library/Audio/Plug-Ins/HAL/VolMixAudio.driver
sudo pkgutil --forget com.wellingtonmota.volmix.pkg >/dev/null 2>&1 || true
sudo killall coreaudiod 2>/dev/null || true
echo "DeadNoise removido. Suas gravações em ~/Documents/DeadNoise foram mantidas."
