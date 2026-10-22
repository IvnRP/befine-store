/* =====================================================================
   cuenta.js — Ingresar, crear cuenta, recuperar contraseña y panel del cliente
   Autenticación REAL con Supabase Auth a través de Befine.auth (data.js).
   Parámetros de URL:
     ?modo=registro|recuperar|nueva   abre esa vista
     ?volver=checkout.html            al ingresar, vuelve a esa página
   ===================================================================== */
(function () {
  const { Val, setError, clearError, autoLimpiar, cargando, GOOGLE_SVG } = window.BefineForms;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const url = new URLSearchParams(location.search);
  // Solo se permite volver a páginas propias (evita redirecciones a otros sitios)
  const volver = /^[\w-]+\.html$/.test(url.get("volver") || "") ? url.get("volver") : null;
  const VISTAS = ["fIngresar", "fRegistro", "fRecuperar", "fNueva", "vRevisa"];
  // Estado del pedido como lo ve el cliente (mismo enum estado_pedido de la base)
  const ESTADO_TXT = { pendiente_pago: "Pendiente de pago", pagado: "Pagado", en_preparacion: "En preparación",
    en_ruta: "En camino", entregado: "Entregado", cancelado: "Cancelado" };

  document.addEventListener("DOMContentLoaded", async () => {
    document.querySelectorAll("[data-google]").forEach((b) => { b.innerHTML = GOOGLE_SVG + b.textContent; });
    ["fIngresar", "fRegistro", "fRecuperar", "fNueva"].forEach((id) => autoLimpiar($(id)));

    // Evento de Supabase al abrir el enlace de recuperación → pedir nueva contraseña
    Befine.auth.onCambio((ev) => { if (ev === "PASSWORD_RECOVERY") mostrarAuth("fNueva"); });

    const sesion = await Befine.auth.sesion();
    $("vCarga").hidden = true;
    const modo = url.get("modo");
    if (modo === "nueva") return mostrarAuth("fNueva");
    if (sesion) { if (volver) return location.replace(volver); return pintarPanel(sesion); }
    mostrarAuth(modo === "registro" ? "fRegistro" : modo === "recuperar" ? "fRecuperar" : "fIngresar");
  });

  /* ================= Vistas ================= */
  function mostrarAuth(id) {
    $("vPanel").hidden = true; $("vAuth").hidden = false;
    VISTAS.forEach((v) => { $(v).hidden = v !== id; });
    const tabs = id === "fIngresar" || id === "fRegistro";
    $("accTabs").hidden = !tabs;
    document.querySelector(".acc-google").hidden = !tabs;
    $("tabIn").setAttribute("aria-selected", String(id === "fIngresar"));
    $("tabReg").setAttribute("aria-selected", String(id === "fRegistro"));
    const primero = $(id).querySelector("input"); if (primero && matchMedia("(hover:hover)").matches) setTimeout(() => primero.focus(), 60);
  }
  $("tabIn").addEventListener("click", () => mostrarAuth("fIngresar"));
  $("tabReg").addEventListener("click", () => mostrarAuth("fRegistro"));
  document.addEventListener("click", (e) => {
    const a = e.target.closest("[data-ir]"); if (!a) return;
    e.preventDefault(); mostrarAuth(a.dataset.ir === "recuperar" ? "fRecuperar" : "fIngresar");
    if (a.dataset.ir === "recuperar" && $("inEmail").value) $("recEmail").value = $("inEmail").value;
  });
  document.querySelectorAll("[data-google]").forEach((b) => b.addEventListener("click", async () => {
    const r = await Befine.auth.google(volver || "cuenta.html");
    if (!r.ok) window.toast(r.error);
  }));
  const msg = (el, texto, tipo) => { el.className = "aviso " + (tipo || ""); el.textContent = texto; el.hidden = !texto; };
  const alEntrar = async () => {
    if (volver) return location.replace(volver);
    const s = await Befine.auth.sesion();
    if (s) { pintarPanel(s); window.scrollTo({ top: 0, behavior: "smooth" }); }
  };

  /* ================= Ingresar ================= */
  $("fIngresar").addEventListener("submit", async (e) => {
    e.preventDefault();
    const em = $("inEmail"), cl = $("inClave"); let ok = true;
    if (!Val.email(em.value)) { setError(em, "Escribe un correo válido."); ok = false; }
    if (!cl.value) { setError(cl, "Escribe tu contraseña."); ok = false; }
    if (!ok) return;
    cargando($("inBtn"), true, "Ingresando…"); msg($("inMsg"), "");
    const r = await Befine.auth.ingresar(em.value.trim(), cl.value);
    cargando($("inBtn"), false);
    if (!r.ok) return msg($("inMsg"), r.error, "mal");
    alEntrar();
  });

  /* ================= Crear cuenta ================= */
  $("regTel").addEventListener("input", (e) => { e.target.value = Val.formatoTel(e.target.value); });
  /* Lista de requisitos de la contraseña, marcados en vivo */
  const pintarReqs = (input, lista) => {
    lista.innerHTML = Val.reqsClave(input.value).map((r) =>
      `<li class="${r.ok ? "ok" : ""}"><span aria-hidden="true">${r.ok ? "✓" : "•"}</span>${r.txt}</li>`).join("");
  };
  const errorClave = (input) => {
    const falta = Val.claveFaltante(input.value);
    if (falta.length) { setError(input, "Tu contraseña necesita: " + falta.join(", ") + "."); return false; }
    return true;
  };
  [["regClave", "regReqs"], ["nvClave", "nvReqs"]].forEach(([i, l]) => {
    pintarReqs($(i), $(l));
    $(i).addEventListener("input", () => pintarReqs($(i), $(l)));
  });
  $("regClave").addEventListener("input", (e) => {
    const n = e.target.value ? Math.max(1, Val.fuerza(e.target.value)) : 0;
    document.querySelector(".fuerza").dataset.n = n;
  });
  $("fRegistro").addEventListener("submit", async (e) => {
    e.preventDefault();
    const n = $("regNombre"), em = $("regEmail"), tel = $("regTel"), cl = $("regClave"), ac = $("regAcepto"); let ok = true;
    if (n.value.trim().length < 3) { setError(n, "Escribe tu nombre y apellido."); ok = false; }
    if (!Val.email(em.value)) { setError(em, "Escribe un correo válido."); ok = false; }
    if (tel.value && !Val.telefono(tel.value)) { setError(tel, "Celular de 9 dígitos que empiece con 9."); ok = false; }
    if (!errorClave(cl)) ok = false;
    if (!ac.checked) { msg($("regMsg"), "Para crear tu cuenta debes aceptar los términos y la política de privacidad.", "mal"); ok = false; }
    if (!ok) return;
    cargando($("regBtn"), true, "Creando cuenta…"); msg($("regMsg"), "");
    const r = await Befine.auth.registrar({ nombre: n.value.trim(), email: em.value.trim().toLowerCase(), password: cl.value,
      telefono: tel.value ? "+56" + Val.limpiarTel(tel.value) : null });
    cargando($("regBtn"), false);
    if (!r.ok) return msg($("regMsg"), r.error, "mal");
    if (r.confirmar) { $("revisaTxt").innerHTML = `Te enviamos un enlace a <b>${esc(em.value.trim())}</b> para activar tu cuenta.`; return mostrarAuth("vRevisa"); }
    alEntrar();
  });

  /* ================= Recuperar / nueva contraseña ================= */
  $("fRecuperar").addEventListener("submit", async (e) => {
    e.preventDefault();
    const em = $("recEmail");
    if (!Val.email(em.value)) return setError(em, "Escribe un correo válido.");
    cargando($("recBtn"), true, "Enviando…");
    const r = await Befine.auth.recuperar(em.value.trim());
    cargando($("recBtn"), false);
    // Por seguridad no revelamos si el correo existe
    msg($("recMsg"), r.ok ? "Si el correo está registrado, te llegará un enlace en unos minutos. Revisa también spam." : r.error, r.ok ? "ok" : "mal");
  });
  $("fNueva").addEventListener("submit", async (e) => {
    e.preventDefault();
    const cl = $("nvClave");
    if (!errorClave(cl)) return;
    cargando($("nvBtn"), true, "Guardando…");
    const r = await Befine.auth.nuevaClave(cl.value);
    cargando($("nvBtn"), false);
    if (!r.ok) return msg($("nvMsg"), r.error, "mal");
    msg($("nvMsg"), "¡Contraseña actualizada!", "ok");
    setTimeout(alEntrar, 900);
  });

  /* ================= Panel del cliente ================= */
  async function pintarPanel(s) {
    $("vAuth").hidden = true; $("vPanel").hidden = false;
    $("pcAvatar").textContent = (s.nombre || "?")[0].toUpperCase();
    $("pcHola").textContent = "Hola, " + (s.nombre || "").split(" ")[0];
    $("pcEmail").textContent = s.email;
    // Equipo de Befine (cualquier rol distinto de cliente): acceso al panel. El panel vuelve a
    // verificar los permisos y el RLS de Supabase bloquea cualquier acción no permitida.
    $("pcAdmin").hidden = !s.rol || s.rol === "cliente";
    $("pcPuntos").textContent = (s.puntos || 0).toLocaleString("es-CL");
    const fila = (k, v) => `<div><dt>${k}</dt><dd>${v ? esc(v) : '<span class="muted">—</span>'}</dd></div>`;
    $("pcDatos").innerHTML = fila("Nombre", [s.nombre, s.apellido].filter(Boolean).join(" ")) + fila("Correo", s.email) + fila("Celular", s.telefono) +
      (s.es_empresa ? fila("Empresa", s.razon_social) + fila("RUT", s.rut) : "");
    const peds = await Befine.misPedidos(s.email);
    $("pcPedidos").innerHTML = peds.length ? peds.map((p) => `
      <div class="ped"><span class="num">#${p.numero}</span><span class="fe">${new Date(p.created_at).toLocaleDateString("es-CL", { day: "numeric", month: "short", year: "numeric" })}
        · ${p.items.reduce((n, i) => n + i.cantidad, 0)} producto(s)</span><span class="tot">${Befine.clp(p.total)}</span>
        <span class="est ${p.estado}">${ESTADO_TXT[p.estado] || "Pendiente de pago"}</span></div>`).join("")
      : `<div class="vacio-p">Aún no tienes pedidos.<br><a class="btn btn-primary" href="catalogo.html">Hacer mi primer pedido</a></div>`;
  }
  $("pcSalir").addEventListener("click", async () => { await Befine.auth.salir(); location.href = "index.html"; });
})();
