/* =====================================================================
   admin-avisos.js — "¡Cha-ching!": aviso de pedidos nuevos en el panel
   ---------------------------------------------------------------------
   Mientras el panel está abierto (PC o celular), revisa cada 20 s si hay
   pedidos PAGADOS nuevos. Si llega uno: suena la caja registradora, aparece
   un aviso en el panel y una notificación del sistema (si se dio permiso),
   y el título de la pestaña muestra cuántos llegaron.
   - Solo para quien puede ver pedidos (pedidos.ver).
   - El botón de la campana activa/desactiva los avisos (se recuerda en este
     navegador) y, al tocarlo, pide permiso de notificaciones.
   - Sin servicios externos: consulta la misma base del panel (RLS).
   - El navegador solo deja sonar audio después de un toque en la página: el
     primer toque en cualquier parte del panel "desbloquea" el sonido, y al
     activar la campana suena una vez para probarlo.
   - Con avisos activos, la pantalla del celular no se apaga mientras el panel
     está a la vista (Wake Lock): con la pantalla apagada el navegador detiene
     la página y no puede sonar.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const KEY = "befine_avisos_pedidos";      // "off" = desactivados en este navegador
  const CADA_MS = 20000;
  const SONIDO = "assets/sonidos/caja-registradora.mp3?v=3";   // ?v=: /assets tiene caché de 30 días; subir el número al cambiar el sonido
  const ICONO = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.9 1.9 0 0 0 3.4 0"/></svg>';

  const leer = () => { try { return localStorage.getItem(KEY) !== "off"; } catch (e) { return true; } };
  const guardar = (on) => { try { localStorage.setItem(KEY, on ? "on" : "off"); } catch (e) {} };

  let on = leer(), vistos = null, sinVer = 0, timer = null, desbloqueado = false, bloqueoPantalla = null;
  const tituloBase = document.title;
  const audio = new Audio(SONIDO); audio.preload = "auto";

  // Primer toque en el panel: reproduce en silencio para que el navegador permita sonar después
  async function desbloquear() {
    if (desbloqueado) return true;
    try { audio.muted = true; await audio.play(); audio.pause(); audio.currentTime = 0; desbloqueado = true; }
    catch (e) { /* se intentará en el próximo toque */ }
    audio.muted = false;
    return desbloqueado;
  }
  ["pointerdown", "keydown"].forEach((ev) => document.addEventListener(ev, () => { if (on) desbloquear(); }, { capture: true, passive: true }));

  // Pantalla encendida mientras el panel está a la vista y los avisos activos
  async function mantenerPantalla() {
    if (!on || document.hidden || bloqueoPantalla || !("wakeLock" in navigator)) return;
    try { bloqueoPantalla = await navigator.wakeLock.request("screen"); bloqueoPantalla.addEventListener("release", () => { bloqueoPantalla = null; }); }
    catch (e) { bloqueoPantalla = null; }
  }
  function soltarPantalla() { if (bloqueoPantalla) { bloqueoPantalla.release().catch(() => {}); bloqueoPantalla = null; } }

  function boton() { return document.getElementById("pnAvisos"); }
  function pintar() {
    const b = boton(); if (!b) return;
    b.setAttribute("aria-pressed", String(on));
    const faltaPermiso = on && "Notification" in window && Notification.permission === "default";
    b.innerHTML = `${ICONO}<span class="txt">${faltaPermiso ? "Activar notificaciones" : "Avisos: " + (on ? "sí" : "no")}</span>${sinVer ? `<span class="n">${sinVer}</span>` : ""}`;
  }
  function limpiarContador() { sinVer = 0; document.title = tituloBase; pintar(); }

  // Devuelve una promesa: true si sonó. Si el navegador lo bloqueó, avisa que falta un toque.
  async function sonar() {
    try { audio.muted = false; audio.currentTime = 0; await audio.play(); desbloqueado = true; return true; }
    catch (e) {
      desbloqueado = false;
      if (window.AdminApp && AdminApp.UI) AdminApp.UI.toast("Llegó un pedido. Toca la pantalla una vez para que el sonido funcione.");
      return false;
    }
  }

  function avisar(p) {
    const texto = `Nuevo pedido #${p.numero} · ${Befine.clp(p.total)} · ${p.contacto_nombre || "Cliente"}`;
    if (window.AdminApp && AdminApp.UI) AdminApp.UI.toast(texto);
    if ("Notification" in window && Notification.permission === "granted") {
      try {
        const n = new Notification("Befine · Nuevo pedido pagado", { body: texto, icon: "assets/icon-192.png", tag: "pedido-" + p.id });
        n.onclick = () => { window.focus(); n.close(); const s = AdminApp.SECCIONES.pedidos; if (s && s.abrir) s.abrir(p.id); };
      } catch (e) {}
    }
  }

  async function revisar() {
    if (!on) return;
    let lista;
    try { lista = await Befine.admin.pedidosPagadosRecientes(3); } catch (e) { return; }   // sin conexión: se reintenta en 20 s
    if (!vistos) { vistos = new Set(lista.map((p) => p.id)); return; }                      // primera vez: lo que ya existía no suena
    const nuevos = L.pedidosNuevos(vistos, lista);
    if (!nuevos.length) return;
    nuevos.forEach((p) => vistos.add(p.id));
    sonar();
    nuevos.forEach(avisar);
    if (document.hidden) { sinVer += nuevos.length; document.title = `(${sinVer}) ${tituloBase}`; pintar(); }
    // La lista de pedidos se actualiza sola si está a la vista
    const s = AdminApp.SECCIONES.pedidos; if (s && s.mostrar && location.hash.slice(1) === "pedidos") { try { s.mostrar(); } catch (e) {} }
  }

  document.addEventListener("admin:listo", (e) => {
    const app = e.detail;
    if (!L.puede(app.permisos, "pedidos.ver")) return;
    const b = boton(); if (!b) return;
    b.hidden = false; pintar();
    b.addEventListener("click", async () => {
      // Avisos activos pero sin permiso de notificaciones todavía: este toque solo lo pide (no apaga)
      const faltaPermiso = on && "Notification" in window && Notification.permission === "default";
      if (!faltaPermiso) { on = !on; guardar(on); }
      pintar();
      if (on) {
        // El toque del usuario permite sonar: suena una vez para probar el volumen
        const sono = await sonar();
        if ("Notification" in window && Notification.permission === "default") { try { await Notification.requestPermission(); } catch (err) {} }
        pintar();
        mantenerPantalla();
        AdminApp.UI.toast(sono ? "Avisos activados: así sonará cada pedido pagado. Deja el panel abierto." : "Sube el volumen y vuelve a tocar la campana.");
        revisar();
      } else { soltarPantalla(); AdminApp.UI.toast("Avisos de pedidos desactivados en este navegador."); }
    });
    document.addEventListener("visibilitychange", () => { if (!document.hidden) { limpiarContador(); mantenerPantalla(); revisar(); } });
    mantenerPantalla();
    revisar();
    timer = setInterval(revisar, CADA_MS);
  });
})();
