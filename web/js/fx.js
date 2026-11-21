/* =====================================================================
   fx.js — Efectos compartidos por TODAS las páginas (inicio, catálogo, ficha)
   Agua reactiva + color por banda horaria + burbujas + cursor + sonido
   (plip/ambiente/bajo el agua) + oscurecer al bajar. Cada efecto solo se
   activa si su elemento existe en la página. La página de inicio (home.js)
   ya NO los duplica: los toma de aquí.
   ===================================================================== */
(function () {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fine = window.matchMedia("(hover:hover) and (pointer:fine)").matches;

  /* Preferencias persistentes (sonido / animación), compartidas entre páginas */
  function _pref(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v === "1"; } catch (e) { return d; } }
  function _setPref(k, on) { try { localStorage.setItem(k, on ? "1" : "0"); } catch (e) {} }

  document.addEventListener("DOMContentLoaded", () => {

    /* ---------- Agua + banda horaria ---------- */
    if (document.getElementById("water") && window.BefineWater)
      window.BefineWater.init({ selector: "#water", ambient: true });
    if (window.Bands) window.Bands.apply();

    /* ---------- Animación on/off (persistente entre páginas) ----------
       Lee la preferencia guardada y la aplica en TODAS las páginas. El botón
       "Apagar animación" (solo en el inicio) usa window.BefineFx.set(). */
    (function () {
      let fxOn = _pref("befine_fx", true);
      function applyFxState() {
        document.body.classList.toggle("fx-off", !fxOn);
        if (window.BefineWater) {
          if (fxOn) { if (BefineWater.resume) BefineWater.resume(); }
          else { if (BefineWater.pause) BefineWater.pause(); }
        }
        if (fine && !reduce) document.documentElement.style.cursor = fxOn ? "none" : "";
      }
      window.BefineFx = { isOn: () => fxOn, set(on, persist) { fxOn = on; if (persist !== false) _setPref("befine_fx", on); applyFxState(); } };
      applyFxState();
    })();

    /* ---------- Burbujas de fondo ---------- */
    (function () {
      const box = document.getElementById("bubbles");
      if (!box || reduce) return;
      const N = window.innerWidth < 680 ? 5 : 8;
      for (let i = 0; i < N; i++) {
        const b = document.createElement("i");
        const sz = 6 + Math.random() * 20;
        b.style.width = b.style.height = sz + "px";
        b.style.left = (Math.random() * 100) + "%";
        b.style.animationDuration = (14 + Math.random() * 16) + "s";
        b.style.animationDelay = (-Math.random() * 20) + "s";
        box.appendChild(b);
      }
    })();

    /* ---------- Cursor personalizado ---------- */
    (function () {
      const dot = document.getElementById("curDot"), ring = document.getElementById("curRing");
      if (!dot || !ring || !fine || reduce) return;
      if (window.BefineFx && !window.BefineFx.isOn()) return; // animación apagada: cursor normal
      document.documentElement.style.cursor = "none";
      let rx = 0, ry = 0, tx = 0, ty = 0;
      window.addEventListener("pointermove", (e) => { tx = e.clientX; ty = e.clientY;
        dot.style.transform = `translate(${tx}px,${ty}px) translate(-50%,-50%)`; }, { passive: true });
      (function follow() { rx += (tx - rx) * .18; ry += (ty - ry) * .18;
        ring.style.transform = `translate(${rx}px,${ry}px) translate(-50%,-50%)`; requestAnimationFrame(follow); })();
      document.addEventListener("pointerover", (e) => { if (e.target.closest("button,a,.card,input,.float,.opt")) ring.classList.add("big"); });
      document.addEventListener("pointerout", (e) => { if (e.target.closest("button,a,.card,input,.float,.opt")) ring.classList.remove("big"); });
    })();

    /* ---------- Sonido: "plip" al tocar + ARPA SUAVE DE FONDO ----------
       Se genera con Web Audio (sin archivos externos). Muy de vez en cuando suena una
       frase corta de arpa (3–5 notas pulsadas de la escala pentatónica de Do), y luego
       20–35 s de silencio. Sin graves ni vibrato: nada que "vibre" o zumbe. Como música
       ambiente de una tienda tranquila: acompaña sin distraer.
       Empieza en el primer clic del usuario (regla de autoplay). Expone window.BefineSound
       para que el modo ligero (perf.js) pueda silenciar todo. */
    (function () {
      // SONIDO_ACTIVO = false: la página no emite ningún sonido (decisión del dueño, 21-nov-2026).
      // El motor queda listo: para volver a activarlo basta con poner true.
      const SONIDO_ACTIVO = false;
      let actx = null, soundOn = SONIDO_ACTIVO && _pref("befine_sound", true), ambient = null, started = false;
      let uwFilter = null, ambDepth = null; // efecto "bajo el agua" al bajar por la página
      const AMB_VOL = 0.05;      // volumen del arpa (súbelo/bájalo aquí). Historial: 0.45 → 0.15 → 0.06 → arpa 0.05 (21-nov-2026)
      const VOL_EFECTOS = 0.25;  // multiplica la gotita al tocar
      const PAUSA_MIN = 20, PAUSA_MAX = 35;   // segundos de silencio entre frases de arpa
      // El botón inferior izquierdo es el "modo ligero" (js/perf.js). Aquí solo vive el motor de audio.
      function ctx() { if (!actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) {} } if (actx && actx.state === "suspended") actx.resume(); return actx; }

      // Gotita de agua al tocar (muy suave)
      function plip(v) { if (!soundOn) return; const a = ctx(); if (!a) return; const t = a.currentTime;
        const o = a.createOscillator(), g = a.createGain(); const f0 = 540 + Math.random() * 280;
        o.type = "sine"; o.frequency.setValueAtTime(f0, t); o.frequency.exponentialRampToValueAtTime(f0 * 0.34, t + 0.09);
        g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime((v || 0.14) * VOL_EFECTOS, t + 0.006); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.17);
        o.connect(g).connect(a.destination); o.start(t); o.stop(t + 0.2); }

      const ESCALA = [60, 62, 64, 67, 69, 72, 74, 76, 79];   // Do pentatónica (MIDI), registro medio-agudo
      const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
      let arpaBus = null, proxFrase = 0;
      function eco(a) {
        const n = Math.floor(a.sampleRate * 2.5), b = a.createBuffer(2, n, a.sampleRate);
        for (let c = 0; c < 2; c++) { const d = b.getChannelData(c); for (let i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * Math.exp(-i / a.sampleRate / 0.8); }
        const cv = a.createConvolver(); cv.buffer = b; return cv;
      }
      function buildAmbient(a) {
        const master = a.createGain(); master.gain.value = 0;
        // master -> sin graves (nada vibra) -> filtro "bajo el agua" -> volumen -> salida
        const sinGraves = a.createBiquadFilter(); sinGraves.type = "highpass"; sinGraves.frequency.value = 200;
        uwFilter = a.createBiquadFilter(); uwFilter.type = "lowpass"; uwFilter.frequency.value = 20000; uwFilter.Q.value = 0.7;
        ambDepth = a.createGain(); ambDepth.gain.value = 1;
        master.connect(sinGraves); sinGraves.connect(uwFilter); uwFilter.connect(ambDepth); ambDepth.connect(a.destination);
        // Arpa: suave (pasa-bajos 3,5 kHz) + eco corto para que "respire" en la sala
        arpaBus = a.createBiquadFilter(); arpaBus.type = "lowpass"; arpaBus.frequency.value = 3500; arpaBus.Q.value = 0.5;
        const seco = a.createGain(); seco.gain.value = 0.75; arpaBus.connect(seco).connect(master);
        const rev = eco(a), mojado = a.createGain(); mojado.gain.value = 0.25; arpaBus.connect(rev); rev.connect(mojado).connect(master);
        return master;
      }
      function fadeAmbient(on) { const a = ctx(); if (!a) return; if (!ambient) ambient = buildAmbient(a);
        const t = a.currentTime; ambient.gain.cancelScheduledValues(t);
        ambient.gain.linearRampToValueAtTime(on ? AMB_VOL : 0, t + (on ? 1.5 : 1.2)); }

      // Una cuerda de arpa pulsada: ataque rápido y apagado natural (armónicos agudos se apagan antes)
      function cuerda(a, t, nota, vel) {
        [[1, 1, 1.8], [2, 0.35, 0.9], [3, 0.12, 0.5], [4, 0.05, 0.3]].forEach(([arm, amp, dur]) => {
          const o = a.createOscillator(), g = a.createGain(); o.type = "sine"; o.frequency.value = hz(nota) * arm;
          g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(amp * vel, t + 0.004);
          g.gain.exponentialRampToValueAtTime(0.0001, t + dur * 1.6);
          o.connect(g).connect(arpaBus); o.start(t); o.stop(t + dur * 1.6 + 0.05);
        });
      }
      // Frase corta: 3–5 notas que suben (a veces bajan), separadas 0,3–0,5 s
      function frase(a, t0) {
        const n = 3 + Math.floor(Math.random() * 3), sube = Math.random() < 0.7;
        let i = Math.floor(Math.random() * (ESCALA.length - n)), t = t0;
        for (let k = 0; k < n; k++) {
          const nota = ESCALA[sube ? i + k : i + n - 1 - k];
          cuerda(a, t, nota, 0.5 + Math.random() * 0.2);
          t += 0.3 + Math.random() * 0.2;
        }
        return t - t0;
      }

      // Programador: solo con sonido activo y pestaña visible (no gasta batería en segundo plano)
      let timer = null;
      function programar() {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const a = actx;
          if (a && arpaBus && soundOn && started && document.visibilityState === "visible") {
            if (proxFrase < a.currentTime) proxFrase = a.currentTime + 2;            // primera frase a los ~2 s
            if (proxFrase < a.currentTime + 1) {
              const largo = frase(a, proxFrase);
              proxFrase += largo + PAUSA_MIN + Math.random() * (PAUSA_MAX - PAUSA_MIN);
            }
          }
          programar();
        }, 500);
      }

      // Profundidad 0..1: al bajar por la página el arpa se amortigua ("bajo el agua"). Lo llama el scroll.
      function setDepth(t) {
        if (!SONIDO_ACTIVO) return;               // sin sonido: ni siquiera se crea el motor de audio
        t = Math.min(Math.max(t, 0), 1);
        const a = ctx(); if (!a || !uwFilter) return; const now = a.currentTime;
        const cut = 420 * Math.pow(42, 1 - t);          // ~17600 Hz en superficie → 420 Hz profundo
        uwFilter.frequency.setTargetAtTime(cut, now, 0.2);
        ambDepth.gain.setTargetAtTime(1 - 0.6 * t, now, 0.2);
      }

      // El sonido arranca en el primer gesto (autoplay bloquea antes de eso)
      function firstGesture() { if (!SONIDO_ACTIVO || started) return; started = true; if (soundOn) fadeAmbient(true); programar(); }
      window.addEventListener("pointerdown", () => { firstGesture(); plip(0.14); }, { passive: true });

      function setSound(on, persist) {
        soundOn = SONIDO_ACTIVO && on; if (persist !== false) _setPref("befine_sound", on);
        if (started) fadeAmbient(on);
        if (on) plip(0.14);
      }
      window.BefineSound = { setEnabled: setSound, isOn: () => soundOn, setDepth: setDepth };
    })();


    /* ---------- Navbar: se oculta al bajar y reaparece AL INSTANTE al subir ----------
       Patrón robusto: rAF + umbral anti-jitter. Aparece ante cualquier gesto
       hacia arriba y cerca del tope; se oculta solo al bajar pasado HIDE_AFTER. */
    (function () {
      const bar = document.querySelector(".topbar");
      if (!bar) return;
      const HIDE_AFTER = 120, DELTA = 5;
      let lastY = Math.max(0, window.scrollY), ticking = false;
      function onScroll() {
        const y = Math.max(0, window.scrollY), diff = y - lastY;
        if (y < HIDE_AFTER || diff < -DELTA) bar.classList.remove("nav-hidden");
        else if (diff > DELTA) bar.classList.add("nav-hidden");
        if (Math.abs(diff) > DELTA) lastY = y;
        ticking = false;
      }
      window.addEventListener("scroll", () => {
        if (!ticking) { ticking = true; requestAnimationFrame(onScroll); }
      }, { passive: true });
    })();

    /* ---------- Descenso: oscurecer al bajar (efecto "hundirse") ----------
       Cuanto más scroll, más opaca la capa #depth (de 0 en la superficie a
       ~0.82 en lo profundo). Ajusta 'max' y el 0.82 para más/menos oscuridad. */
    const depth = document.getElementById("depth");
    if (depth) {
      const onScroll = () => {
        const max = window.innerHeight * 1.4;              // a qué profundidad llega al máximo
        const t = Math.min(window.scrollY / max, 1);       // 0 superficie → 1 profundo
        depth.style.opacity = (t * 0.82).toFixed(3);       // oscurecer visual
        if (window.BefineSound && window.BefineSound.setDepth) window.BefineSound.setDepth(t); // amortiguar audio
      };
      window.addEventListener("scroll", onScroll, { passive: true });
      onScroll();
    }


  });
})();
