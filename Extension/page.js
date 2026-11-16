// Roda dentro de cada página (mundo "MAIN") e deixa o DeadNoise mudar o volume da aba inteira.
// A extensão chama window.__deadnoiseSetGain(g) com g entre 0 e 1.
//
// - <audio>/<video>: o volume real vira (volume que a página pediu) × g. A página continua lendo o
//   volume que ela mesma escolheu, então players como o do YouTube não percebem a diferença.
// - Web Audio: tudo que ia para o alto-falante (ctx.destination) passa antes por um GainNode nosso.
(() => {
  if (window.__deadnoiseSetGain) return;

  let gain = 1;
  const proto = HTMLMediaElement.prototype;
  const volume = Object.getOwnPropertyDescriptor(proto, "volume");
  const pageVolume = new WeakMap();   // elemento -> volume pedido pela página
  const media = new Set();            // WeakRef dos elementos que já tocaram
  const masters = new Set();          // WeakRef dos GainNodes de cada AudioContext
  const masterOf = new WeakMap();     // AudioContext -> GainNode

  const apply = (el) => {
    const wanted = pageVolume.has(el) ? pageVolume.get(el) : volume.get.call(el);
    volume.set.call(el, Math.min(1, Math.max(0, wanted * gain)));
  };

  const track = (el) => {
    if (!(el instanceof HTMLMediaElement) || el.__deadnoise) return;
    Object.defineProperty(el, "__deadnoise", { value: true });
    if (!pageVolume.has(el)) pageVolume.set(el, volume.get.call(el));
    media.add(new WeakRef(el));
    if (gain !== 1) apply(el);
  };

  Object.defineProperty(proto, "volume", {
    configurable: true,
    enumerable: true,
    get() {
      return pageVolume.has(this) ? pageVolume.get(this) : volume.get.call(this);
    },
    set(v) {
      volume.set.call(this, v); // valida (e lança erro) como o original
      pageVolume.set(this, Number(v));
      track(this);
      if (gain !== 1) apply(this);
    },
  });

  const play = proto.play;
  proto.play = function (...args) {
    track(this);
    return play.apply(this, args);
  };
  // Elementos com autoplay não chamam play(): pega pelo evento.
  window.addEventListener("play", (e) => track(e.target), true);

  // Web Audio: troca ctx.destination pelo nosso GainNode na hora de conectar.
  const masterFor = (ctx) => {
    let m = masterOf.get(ctx);
    if (!m) {
      m = ctx.createGain();
      m.gain.value = gain;
      connect.call(m, ctx.destination);
      masterOf.set(ctx, m);
      masters.add(new WeakRef(m));
    }
    return m;
  };
  const isSpeaker = (node) =>
    typeof AudioDestinationNode !== "undefined" &&
    node instanceof AudioDestinationNode &&
    typeof AudioContext !== "undefined" &&
    node.context instanceof AudioContext;

  const connect = AudioNode.prototype.connect;
  const disconnect = AudioNode.prototype.disconnect;
  AudioNode.prototype.connect = function (dest, ...rest) {
    if (isSpeaker(dest)) {
      const m = masterFor(dest.context);
      if (this !== m) {
        connect.call(this, m, ...rest);
        return dest;
      }
    }
    return connect.call(this, dest, ...rest);
  };
  AudioNode.prototype.disconnect = function (dest, ...rest) {
    if (isSpeaker(dest) && masterOf.has(dest.context) && this !== masterOf.get(dest.context)) {
      return disconnect.call(this, masterOf.get(dest.context), ...rest);
    }
    return disconnect.call(this, ...(dest === undefined ? [] : [dest, ...rest]));
  };

  Object.defineProperty(window, "__deadnoiseSetGain", {
    value(g) {
      gain = Math.min(1, Math.max(0, Number(g) || 0));
      for (const ref of media) {
        const el = ref.deref();
        if (el) apply(el); else media.delete(ref);
      }
      for (const ref of masters) {
        const m = ref.deref();
        if (m) m.gain.setTargetAtTime(gain, m.context.currentTime, 0.02); else masters.delete(ref);
      }
    },
  });
})();
