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
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const KEY = "befine_avisos_pedidos";      // "off" = desactivados en este navegador
  const CADA_MS = 20000;
  const SONIDO = "assets/sonidos/caja-registradora.mp3";
  const ICONO = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.9 1.9 0 0 0 3.4 0"/></svg>';

  const leer = () => { try { return localStorage.getItem(KEY) !== "off"; } catch (e) { return true; } };
  const guardar = (on) => { try { localStorage.setItem(KEY, on ? "on" : "off"); } catch (e) {} };

  let on = leer(), vistos = null, sinVer = 0, timer = null;
  const tituloBase = document.title;
  const audio = new Audio(SONIDO); audio.preload = "auto";

  function boton() { return document.getElementById("pnAvisos"); }
  function pintar() {
    const b = boton(); if (!b) return;
    b.setAttribute("aria-pressed", String(on));
    const faltaPermiso = on && "Notification" in window && Notification.permission === "default";
    b.innerHTML = `${ICONO}<span class="txt">${faltaPermiso ? "Activar notificaciones" : "Avisos: " + (on ? "sí" : "no")}</span>${sinVer ? `<span class="n">${sinVer}</span>` : ""}`;
  }
  function limpiarContador() { sinVer = 0; document.title = tituloBase; pintar(); }

  function sonar() { try { audio.currentTime = 0; const p = audio.play(); if (p && p.catch) p.catch(() => {}); } catch (e) {} }

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
        // El toque del usuario "desbloquea" el sonido en el navegador y permite pedir notificaciones
        try { audio.muted = true; await audio.play(); audio.pause(); audio.currentTime = 0; audio.muted = false; } catch (err) { audio.muted = false; }
        if ("Notification" in window && Notification.permission === "default") { try { await Notification.requestPermission(); } catch (err) {} }
        pintar();
        AdminApp.UI.toast("Avisos de pedidos activados: sonará la caja con cada pedido pagado.");
        revisar();
      } else AdminApp.UI.toast("Avisos de pedidos desactivados en este navegador.");
    });
    document.addEventListener("visibilitychange", () => { if (!document.hidden) { limpiarContador(); revisar(); } });
    revisar();
    timer = setInterval(revisar, CADA_MS);
  });
})();
