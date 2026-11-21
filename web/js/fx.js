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

    /* ---------- Sonido: "plip" al tocar + AMBIENTE ARMÓNICO DE FONDO ----------
       Se genera con Web Audio (sin archivos externos): acordes suaves que respiran
       lento y, de vez en cuando, ~3 s de agua muy suave. Como la música ambiente de
       una tienda física: acompaña sin distraer. Empieza en el primer clic del usuario (regla de autoplay).
       Expone window.BefineSound para que el botón "apagar animación" también
       pueda silenciar todo. */
    (function () {
      let actx = null, soundOn = _pref("befine_sound", true), ambient = null, started = false;
      let uwFilter = null, ambDepth = null, submerged = false; // efecto "bajo el agua"
      const AMB_VOL = 0.15;     // volumen del ambiente (súbelo/bájalo aquí). Antes 0.45: el dueño lo pidió mucho más bajo (21-nov-2026)
      const VOL_EFECTOS = 0.4;  // multiplica las gotitas al tocar y el "whoomp" al sumergirse
      const ON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16 9a3 3 0 0 1 0 6"/><path d="M18.6 6.4a7 7 0 0 1 0 11.2"/></svg>';
      const OFF = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M17 9.5l4.5 5M21.5 9.5l-4.5 5"/></svg>';
      // El botón inferior izquierdo ahora es el "modo ligero" (js/perf.js). Aquí solo vive el motor de audio (window.BefineSound).
      function ctx() { if (!actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) {} } if (actx && actx.state === "suspended") actx.resume(); return actx; }

      // Gotita de agua al tocar
      function plip(v) { if (!soundOn) return; const a = ctx(); if (!a) return; const t = a.currentTime;
        const o = a.createOscillator(), g = a.createGain(); const f0 = 540 + Math.random() * 280;
        o.type = "sine"; o.frequency.setValueAtTime(f0, t); o.frequency.exponentialRampToValueAtTime(f0 * 0.34, t + 0.09);
        g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime((v || 0.14) * VOL_EFECTOS, t + 0.006); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.17);
        o.connect(g).connect(a.destination); o.start(t); o.stop(t + 0.2); }

      // Ambiente ARMÓNICO de fondo (sin archivos, generado con Web Audio): solo acordes suaves, sin
      // instrumentos ni ruido, como la música ambiente de una tienda física. No distrae.
      //   - Ciclo de 4 acordes (Do, La menor, Fa, Sol), 8 s cada uno, que entran y salen despacio.
      //   - Cada voz "respira" a su propio ritmo, así nunca suena plano ni repetitivo.
      //   - Agua muy suave en episodios: ~3 s de un hilo de agua con 2–4 gotitas, y luego silencio de
      //     6–12 s antes del siguiente (nunca constante).
      //   - Sin graves (no zumba) y con un eco corto. Ajusta AMB_VOL (arriba) para el volumen.
      const ACORDES = [[48, 55, 64, 67, 72], [45, 52, 60, 64, 69], [41, 48, 57, 60, 65], [43, 50, 59, 62, 67]];   // notas MIDI
      const DUR_ACORDE = 8;
      const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
      let fondoBus = null, aguaBus = null, compas = 0, proximo = 0, proxAgua = 0;
      function eco(a) {
        const n = Math.floor(a.sampleRate * 3), b = a.createBuffer(2, n, a.sampleRate);
        for (let c = 0; c < 2; c++) { const d = b.getChannelData(c); for (let i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * Math.exp(-i / a.sampleRate / 1.0); }
        const cv = a.createConvolver(); cv.buffer = b; return cv;
      }
      function buildAmbient(a) {
        const master = a.createGain(); master.gain.value = 0;
        // Cadena "bajo el agua": master -> sin graves -> filtro (se cierra al bajar) -> volumen -> salida
        uwFilter = a.createBiquadFilter(); uwFilter.type = "lowpass"; uwFilter.frequency.value = 20000; uwFilter.Q.value = 0.7;
        ambDepth = a.createGain(); ambDepth.gain.value = 1;
        const sinGraves = a.createBiquadFilter(); sinGraves.type = "highpass"; sinGraves.frequency.value = 90;
        master.connect(sinGraves); sinGraves.connect(uwFilter); uwFilter.connect(ambDepth); ambDepth.connect(a.destination);
        // Bus de los acordes: suave (pasa-bajos 900 Hz) + eco sin graves
        fondoBus = a.createBiquadFilter(); fondoBus.type = "lowpass"; fondoBus.frequency.value = 900; fondoBus.Q.value = 0.5;
        const seco = a.createGain(); seco.gain.value = 0.7; fondoBus.connect(seco).connect(master);
        const rev = eco(a), revFiltro = a.createBiquadFilter(); revFiltro.type = "bandpass"; revFiltro.frequency.value = 800; revFiltro.Q.value = 0.4;
        const mojado = a.createGain(); mojado.gain.value = 0.3; fondoBus.connect(rev); rev.connect(revFiltro).connect(mojado).connect(master);
        // Bus del agua: directo + el mismo eco (no pasa por el pasa-bajos de los acordes)
        aguaBus = a.createGain(); aguaBus.gain.value = 1;
        const aguaSeca = a.createGain(); aguaSeca.gain.value = 0.7; aguaBus.connect(aguaSeca).connect(master); aguaBus.connect(rev);
        return master;
      }
      function fadeAmbient(on) { const a = ctx(); if (!a) return; if (!ambient) ambient = buildAmbient(a);
        const t = a.currentTime; ambient.gain.cancelScheduledValues(t);
        ambient.gain.linearRampToValueAtTime(on ? AMB_VOL : 0, t + (on ? 3 : 1.2)); }

      // Un acorde que entra (2,5 s), se mantiene y sale (3 s) encima del siguiente: transición sin cortes
      function tocarAcorde(a, t0, acorde) {
        acorde.forEach((nota, i) => {
          const voz = a.createGain(); voz.gain.value = 0;
          const v = 0.07 / (1 + 0.45 * i);
          voz.gain.setValueAtTime(0, t0); voz.gain.linearRampToValueAtTime(v, t0 + 2.5);
          voz.gain.setValueAtTime(v, t0 + DUR_ACORDE); voz.gain.linearRampToValueAtTime(0, t0 + DUR_ACORDE + 3);
          // respiración propia de cada voz (0,8–1,0 del volumen)
          const lfo = a.createOscillator(); lfo.frequency.value = 0.07 + 0.02 * i; const lg = a.createGain(); lg.gain.value = v * 0.2;
          lfo.connect(lg).connect(voz.gain); lfo.start(t0); lfo.stop(t0 + DUR_ACORDE + 3.1);
          voz.connect(fondoBus);
          [[1, 1], [1.002, 0.3]].forEach(([det, amp]) => {
            const o = a.createOscillator(), g = a.createGain(); o.type = "sine"; o.frequency.value = hz(nota) * det; g.gain.value = amp;
            o.connect(g).connect(voz); o.start(t0); o.stop(t0 + DUR_ACORDE + 3.1);
          });
        });
      }
      // Episodio de agua (~3 s): hilo de agua que aparece y se va + 2–4 gotitas suaves
      let ruidoAgua = null;
      function episodioAgua(a, t0) {
        if (!ruidoAgua) {
          const n = Math.floor(a.sampleRate * 3), b = a.createBuffer(1, n, a.sampleRate), d = b.getChannelData(0);
          for (let i = 0; i < n; i++) d[i] = Math.random() * 2 - 1;
          ruidoAgua = b;
        }
        const src = a.createBufferSource(); src.buffer = ruidoAgua;
        const bp = a.createBiquadFilter(); bp.type = "bandpass"; bp.frequency.value = 1500; bp.Q.value = 0.8;
        const g = a.createGain(); g.gain.setValueAtTime(0, t0);
        g.gain.linearRampToValueAtTime(0.012, t0 + 1.5); g.gain.linearRampToValueAtTime(0, t0 + 3);
        src.connect(bp).connect(g).connect(aguaBus); src.start(t0); src.stop(t0 + 3);
        const n = 2 + Math.floor(Math.random() * 3);
        for (let k = 0; k < n; k++) {
          const t = t0 + 0.3 + Math.random() * 2.2, f = 700 + Math.random() * 400, d = 0.14;
          const o = a.createOscillator(), gg = a.createGain(); o.type = "sine";
          o.frequency.setValueAtTime(f, t); o.frequency.exponentialRampToValueAtTime(f * 0.6, t + d);
          gg.gain.setValueAtTime(0.0001, t); gg.gain.exponentialRampToValueAtTime(0.03 + Math.random() * 0.02, t + 0.004);
          gg.gain.exponentialRampToValueAtTime(0.0001, t + d);
          o.connect(gg).connect(aguaBus); o.start(t); o.stop(t + d + 0.02);
        }
      }

      // Programador: deja listo el siguiente acorde antes de que termine el actual
      // (solo con sonido activo y pestaña visible: no gasta batería en segundo plano)
      let chimeTimer = null;
      function scheduleChime() {
        clearTimeout(chimeTimer);
        chimeTimer = setTimeout(() => {
          const a = actx;
          if (a && fondoBus && soundOn && started && document.visibilityState === "visible") {
            if (proximo < a.currentTime) proximo = a.currentTime + 0.1;
            while (proximo < a.currentTime + 1.5) { tocarAcorde(a, proximo, ACORDES[compas % ACORDES.length]); compas++; proximo += DUR_ACORDE; }
            if (proxAgua < a.currentTime) proxAgua = a.currentTime + 3;            // primer episodio a los ~3 s
            if (proxAgua < a.currentTime + 1) { episodioAgua(a, proxAgua); proxAgua += 3 + 6 + Math.random() * 6; }   // 3 s de agua + 6–12 s de silencio
          }
          scheduleChime();
        }, 500);
      }

      // Sumergirse: un "whoomp" grave, suave y breve. Relajante, no molesto.
      function submerge() {
        if (!soundOn) return; const a = ctx(); if (!a) return; const t = a.currentTime, dur = 1.1;
        const o = a.createOscillator(), g = a.createGain(); o.type = "sine";
        o.frequency.setValueAtTime(170, t); o.frequency.exponentialRampToValueAtTime(80, t + dur);
        g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(0.05 * VOL_EFECTOS, t + 0.25); g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
        o.connect(g).connect(a.destination); o.start(t); o.stop(t + dur + 0.05);
      }

      // Profundidad 0..1: amortigua la música (pasa-bajos) y baja un poco el
      // volumen, como estar bajo el agua. Lo llama el scroll (js/home.js).
      function setDepth(t) {
        t = Math.min(Math.max(t, 0), 1);
        // (sin sonido al bajar; la música solo se amortigua como "bajo el agua")
        const a = ctx(); if (!a || !uwFilter) return; const now = a.currentTime;
        // la música se amortigua (pasa-bajos) y baja de volumen = sensación bajo el agua
        const cut = 420 * Math.pow(42, 1 - t);          // ~17600 Hz en superficie → 420 Hz profundo
        uwFilter.frequency.setTargetAtTime(cut, now, 0.2);
        ambDepth.gain.setTargetAtTime(1 - 0.6 * t, now, 0.2);
      }

      // La música arranca en el primer gesto (autoplay bloquea antes de eso)
      function firstGesture() { if (started) return; started = true; if (soundOn) fadeAmbient(true); scheduleChime(); }
      window.addEventListener("pointerdown", () => { firstGesture(); plip(0.14); }, { passive: true });

      function setSound(on, persist) {
        soundOn = on; if (persist !== false) _setPref("befine_sound", on);
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
