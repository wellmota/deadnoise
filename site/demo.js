// Os textos vêm dos atributos data-on/data-off do #state, para servir às duas línguas.
// Demonstração: barras caóticas (ruído) que morrem e viram só a onda calma da voz.
const bars = document.getElementById('bars');
const toggle = document.getElementById('toggle');
const state = document.getElementById('state');
const COUNT = 44;
const els = [];
for (let i = 0; i < COUNT; i++) { const b = document.createElement('i'); bars.appendChild(b); els.push(b); }
const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
let clean = false, mix = 0, t = 0;

function frame() {
  t += 0.045;
  mix += ((clean ? 1 : 0) - mix) * 0.07;            // 0 = ruído, 1 = só voz
  for (let i = 0; i < COUNT; i++) {
    const x = i / (COUNT - 1);
    const envelope = Math.sin(Math.PI * x) ** 1.4;    // voz: concentrada no meio
    const voice = envelope * (0.45 + 0.4 * Math.sin(t * 2.1 + i * 0.55) * Math.sin(t * 0.7 + i * 0.17));
    const noise = 0.25 + 0.75 * Math.abs(Math.sin(i * 12.9898 + Math.floor(t * 9) * 78.233) * 43758.5453 % 1);
    const h = Math.max(0.04, voice * mix + noise * (1 - mix));
    els[i].style.height = (h * 100).toFixed(1) + '%';
  }
  if (!still) requestAnimationFrame(frame);
}
function render() {
  toggle.setAttribute('aria-checked', String(clean));
  document.body.classList.toggle('clean', clean);
  state.innerHTML = clean ? state.dataset.on : state.dataset.off;
  if (still) { mix = clean ? 1 : 0; frame(); }
}
toggle.addEventListener('click', () => { clean = !clean; render(); });
render();
if (!still) requestAnimationFrame(frame);
