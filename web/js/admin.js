/* =====================================================================
   admin.js — Núcleo del panel de administración
   ---------------------------------------------------------------------
   1. Verifica la sesión y los permisos (Befine.admin.contexto()).
   2. Muestra SOLO las secciones que el rol puede usar (AdminLogic).
   3. Ofrece utilidades comunes a las secciones: aviso, panel lateral,
      modal, confirmación y escape de HTML.
   Cada sección vive en su propio archivo (admin-pedidos.js, …) y se
   registra en AdminApp.SECCIONES[id] = { montar(el, app), mostrar() }.
   Carga: data.js → admin-logic.js → admin-data.js → admin.js → secciones.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const $ = (id) => document.getElementById(id);

  /* Escapa texto antes de ponerlo en HTML (los datos del cliente NUNCA se insertan crudos) */
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const svg = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
  const ICONOS = {
    pedidos: svg('<path d="M6 2 3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6l-3-4z"/><path d="M3 6h18M16 10a4 4 0 0 1-8 0"/>'),
    catalogo: svg('<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>'),
    inventario: svg('<path d="M21 8 12 3 3 8v8l9 5 9-5z"/><path d="m3 8 9 5 9-5M12 13v8"/>'),
    cupones: svg('<path d="M3 9a2 2 0 0 0 0 6v3a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1v-3a2 2 0 0 1 0-6V6a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1z"/><path d="M14 5v2M14 11v2M14 17v2"/>'),
    reparto: svg('<path d="M1 3h15v13H1z"/><path d="M16 8h4l3 3v5h-7z"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/>'),
    equipo: svg('<circle cx="9" cy="7" r="4"/><path d="M2 21v-2a4 4 0 0 1 4-4h6a4 4 0 0 1 4 4v2"/><path d="M16 3.1a4 4 0 0 1 0 7.8M22 21v-2a4 4 0 0 0-3-3.9"/>'),
    telefono: svg('<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.4 1.8.7 2.7a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.5c.9.3 1.8.6 2.7.7a2 2 0 0 1 1.7 2z"/>'),
    mapa: svg('<path d="M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11z"/><circle cx="12" cy="10" r="2.5"/>'),
    buscar: svg('<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>'),
    recargar: svg('<path d="M21 12a9 9 0 1 1-2.6-6.4L21 8"/><path d="M21 3v5h-5"/>'),
    mas: svg('<path d="M12 5v14M5 12h14"/>'),
    whatsapp: svg('<path d="M3 21l1.7-5A8.5 8.5 0 1 1 8 19.3z"/><path d="M9 10c.5 2 2 3.5 4 4l1.2-1.2 2 1-1 2c-3 0-7-4-7-7l2-1 1 2z"/>'),
  };

  /* ---------- Estado de la aplicación ---------- */
  const App = {
    ctx: null,
    permisos: [],
    puede: (p) => L.puede(App.permisos, p),
  };

  /* ---------- Utilidades de interfaz ---------- */
  let toastT;
  function toast(texto, tipo) {
    const t = $("pnToast");
    t.textContent = texto; t.className = "pn-toast show" + (tipo === "mal" ? " mal" : "");
    clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove("show"), 3200);
  }

  let focoPrevio = null;
  function abrirDetalle(html) {
    focoPrevio = document.activeElement;
    $("pnDrawerIn").innerHTML = `<button class="pn-x" type="button" data-cerrar aria-label="Cerrar">×</button>` + html;
    $("pnDrawer").classList.add("abierto"); $("pnDrawer").setAttribute("aria-hidden", "false");
    $("pnVelo").hidden = false; $("pnDrawer").focus();
  }
  function cerrarDetalle() {
    $("pnDrawer").classList.remove("abierto"); $("pnDrawer").setAttribute("aria-hidden", "true");
    $("pnVelo").hidden = true; if (focoPrevio && focoPrevio.focus) focoPrevio.focus();
  }
  function abrirModal(html) {
    $("pnModalIn").innerHTML = html; $("pnModal").hidden = false;
    const f = $("pnModalIn").querySelector("input, select, textarea, button"); if (f) f.focus();
  }
  const cerrarModal = () => { $("pnModal").hidden = true; $("pnModalIn").innerHTML = ""; };

  /* Confirmación propia (no se usan alert/confirm del navegador) → Promise<boolean> */
  function confirmar(titulo, texto, boton = "Confirmar", peligro = false) {
    return new Promise((ok) => {
      abrirModal(`<h2>${esc(titulo)}</h2><p style="margin:0 0 16px;color:var(--pn-muted)">${esc(texto)}</p>
        <div class="pn-form-acc"><button class="pn-btn ghost" type="button" data-r="0">Volver</button>
        <button class="pn-btn${peligro ? " peligro" : ""}" type="button" data-r="1">${esc(boton)}</button></div>`);
      $("pnModalIn").addEventListener("click", function h(e) {
        const b = e.target.closest("[data-r]"); if (!b) return;
        $("pnModalIn").removeEventListener("click", h); cerrarModal(); ok(b.dataset.r === "1");
      });
    });
  }

  /* Bloquea un botón mientras se guarda */
  async function conCarga(btn, fn) {
    const txt = btn ? btn.innerHTML : ""; if (btn) { btn.disabled = true; btn.innerHTML = '<span class="pn-spin"></span>'; }
    try { return await fn(); } finally { if (btn) { btn.disabled = false; btn.innerHTML = txt; } }
  }

  const fecha = (iso, conHora) => {
    if (!iso) return "—";
    const d = /^\d{4}-\d{2}-\d{2}$/.test(iso) ? new Date(iso + "T12:00:00") : new Date(iso);
    return d.toLocaleDateString("es-CL", { day: "numeric", month: "short", ...(conHora ? { hour: "2-digit", minute: "2-digit" } : {}) });
  };

  window.AdminApp = {
    App, SECCIONES: {}, esc, ICONOS, fecha,
    UI: { toast, abrirDetalle, cerrarDetalle, abrirModal, cerrarModal, confirmar, conCarga },
  };

  /* ---------- Navegación entre secciones (#pedidos, #catalogo, …) ---------- */
  let visibles = [];
  function ir(id) {
    if (!visibles.some((s) => s.id === id)) id = visibles[0].id;
    visibles.forEach((s) => {
      const el = $("sec-" + s.id); if (el) el.hidden = s.id !== id;
      const b = document.querySelector(`.pn-nav [data-sec="${s.id}"]`);
      if (b) { if (s.id === id) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current"); }
    });
    const sec = AdminApp.SECCIONES[id];
    if (sec && sec.mostrar) sec.mostrar();
    if (location.hash !== "#" + id) history.replaceState(null, "", "#" + id);
  }

  function mostrarEstado(id) {
    ["vCarga", "vSinSesion", "vSinPermiso"].forEach((v) => { $(v).hidden = v !== id; });
  }

  document.addEventListener("DOMContentLoaded", async () => {
    // Cierre del panel lateral y del modal
    document.addEventListener("click", (e) => {
      if (e.target.closest("[data-cerrar]") || e.target === $("pnVelo")) cerrarDetalle();
      if (e.target === $("pnModal")) cerrarModal();
    });
    document.addEventListener("keydown", (e) => {
      if (e.key !== "Escape") return;
      if (!$("pnModal").hidden) cerrarModal(); else if ($("pnDrawer").classList.contains("abierto")) cerrarDetalle();
    });
    $("pnSalir").addEventListener("click", async () => { await Befine.auth.salir(); location.href = "index.html"; });

    let ctx;
    try { ctx = await Befine.admin.contexto(); }
    catch (e) { mostrarEstado("vSinPermiso"); return toast(Befine.admin.msg(e), "mal"); }
    App.ctx = ctx; App.permisos = ctx.permisos;

    if (!ctx.usuario) return mostrarEstado("vSinSesion");
    $("pnSalir").hidden = false;
    visibles = L.seccionesVisibles(App.permisos, ctx.perfil && ctx.perfil.rol);
    if (!visibles.length) return mostrarEstado("vSinPermiso");

    // Usuario y rol en la barra
    const nombre = (ctx.perfil && ctx.perfil.nombre) || ctx.usuario.email || "";
    $("pnNombre").textContent = nombre.split(" ")[0];
    $("pnAvatar").textContent = (nombre[0] || "B").toUpperCase();
    $("pnRol").textContent = await Befine.admin.nombreRol(ctx.perfil.rol);
    $("pnUser").hidden = false;

    // Menú y secciones permitidas
    $("pnNav").innerHTML = visibles.map((s) =>
      `<button type="button" data-sec="${s.id}">${ICONOS[s.id] || ""}<span>${esc(s.txt)}</span><span class="cnt" id="cnt-${s.id}" hidden></span></button>`).join("");
    $("pnNav").hidden = false;
    $("pnNav").addEventListener("click", (e) => { const b = e.target.closest("[data-sec]"); if (b) ir(b.dataset.sec); });
    mostrarEstado(null);
    visibles.forEach((s) => { const sec = AdminApp.SECCIONES[s.id]; if (sec && sec.montar) sec.montar($("sec-" + s.id), App); });
    ir(location.hash.slice(1));
    window.addEventListener("hashchange", () => ir(location.hash.slice(1)));
  });
})();
