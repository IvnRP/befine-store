/* =====================================================================
   admin-clientes.js — Sección "Clientes" del panel (HU-23 · RF-19, CM-03)
   ---------------------------------------------------------------------
   - Indicadores: clientes, nuevos del mes, recurrencia, ticket promedio
     y clientes por recuperar.
   - Lista con buscador (nombre, correo, celular o comuna) y segmentos:
     registrados, invitados, empresas, frecuentes, por recuperar y bloqueados.
   - Ficha en panel lateral: contacto (WhatsApp, llamar, correo), resumen de
     compras, datos de empresa, direcciones, últimos pedidos, Club Befine y
     registro de cambios.
   - Editar datos y Bloquear/Activar (permiso clientes.gestionar). "Eliminar"
     se reemplazó por "Bloquear" (CM-03): los pedidos se conservan por el SII.
   Todo pasa por funciones del servidor (migración 14), que revisan los
   permisos, validan los datos y registran cada cambio en cambios_cliente.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const { esc, fecha, ICONOS, UI } = window.AdminApp;
  const A = () => Befine.admin;
  const clp = (n) => Befine.clp(n || 0);
  const MAX_FILAS = 300;

  let el, app, lista = [], filtro = { segmento: "todos", q: "" }, cargado = false, actual = null;

  const AYUDA = {
    todos: "",
    registrados: "Clientes con cuenta en la tienda.",
    invitados: "Compraron sin crear cuenta: sus datos vienen del pedido y no se editan.",
    empresas: "Clientes marcados como empresa (compran con factura).",
    frecuentes: `Tienen ${L.CLIENTES.frecuenteMin} o más pedidos pagados.`,
    recuperar: `Compraron antes, pero no en los últimos ${L.CLIENTES.recuperarDias} días. Buen momento para escribirles por WhatsApp.`,
    bloqueados: "No pueden comprar en la tienda hasta que los actives.",
  };
  const CAMPOS = { nombre: "Nombre", apellido: "Apellido", telefono: "Celular", es_empresa: "Empresa",
                   rut: "RUT", razon_social: "Razón social", giro: "Giro", activo: "Estado" };

  const badgePedido = (e) => `<span class="pn-est ${(L.ESTADOS[e] || {}).tono || ""}">${esc(L.etiquetaEstado(e))}</span>`;
  function etiquetas(c) {
    return (c.invitado ? '<span class="cl-tag inv">Invitado</span>' : "") +
           (c.empresa ? '<span class="cl-tag emp">Empresa</span>' : "") +
           (c.rol && c.rol !== "cliente" ? '<span class="cl-tag eq">Equipo</span>' : "") +
           (c.activo === false ? '<span class="cl-tag blq">Bloqueado</span>' : "");
  }
  function hace(iso) {
    const d = L.diasDesde(iso);
    if (d == null) return "";
    return d <= 0 ? "hoy" : d === 1 ? "ayer" : `hace ${d} días`;
  }
  const pedidosVisibles = () => L.seccionesVisibles(app.permisos, app.ctx && app.ctx.perfil && app.ctx.perfil.rol)
    .some((s) => s.id === "pedidos");

  function montar(seccion, appCtx) {
    el = seccion; app = appCtx;
    el.innerHTML = `
      <div class="pn-head">
        <div><h1>Clientes</h1><p>Quién te compra, cuánto y cuándo fue la última vez.</p></div>
        <div class="acciones">
          <label class="pn-buscar">${ICONOS.buscar}<input class="pn-inp" id="clBuscar" type="search" placeholder="Nombre, correo, celular o comuna" aria-label="Buscar clientes"></label>
          <button class="pn-btn ghost" type="button" id="clRecargar" title="Actualizar">${ICONOS.recargar}<span>Actualizar</span></button>
        </div>
      </div>
      <div class="pn-kpis" id="clKpis"></div>
      <div class="pn-chips" id="clChips" role="tablist" aria-label="Segmentos de clientes"></div>
      <p class="cl-ayuda" id="clAyuda" aria-live="polite"></p>
      <div class="pn-card pn-lista" id="clLista"><div class="pn-vacio"><span class="pn-spin"></span></div></div>`;

    let t;
    el.querySelector("#clBuscar").addEventListener("input", (e) => {
      clearTimeout(t); t = setTimeout(() => { filtro.q = e.target.value; pintarLista(); }, 150);
    });
    el.querySelector("#clRecargar").addEventListener("click", (e) => UI.conCarga(e.currentTarget, cargar));
    el.querySelector("#clChips").addEventListener("click", (e) => {
      const b = e.target.closest("[data-s]"); if (!b) return;
      filtro.segmento = b.dataset.s; pintarChips(); pintarLista();
    });
    const lst = el.querySelector("#clLista");
    lst.addEventListener("click", (e) => { const f = e.target.closest("tr[data-id]"); if (f) abrir(f.dataset.id); });
    lst.addEventListener("keydown", (e) => { const f = e.target.closest("tr[data-id]"); if (f && e.key === "Enter") abrir(f.dataset.id); });

    // Acciones de la ficha (panel lateral compartido: se usan atributos data-cl propios)
    document.getElementById("pnDrawerIn").addEventListener("click", (e) => {
      const b = e.target.closest("[data-cl]"); if (!b || !actual) return;
      const acc = b.dataset.cl;
      if (acc === "editar") editar();
      else if (acc === "bloquear") cambiarActivo(b, false);
      else if (acc === "activar") cambiarActivo(b, true);
      else if (acc === "pedido") abrirPedido(b.dataset.id);
    });
  }

  async function mostrar() { if (!cargado) await cargar(); }

  async function cargar() {
    try {
      lista = await A().clientes();
      cargado = true;
      pintarKpis(); pintarChips(); pintarLista();
    } catch (e) {
      el.querySelector("#clLista").innerHTML = `<div class="pn-vacio">No pudimos cargar los clientes. ${esc(A().msg(e))}</div>`;
      UI.toast(A().msg(e), "mal");
    }
  }

  function pintarKpis() {
    const r = L.resumenClientes(lista);
    const kpi = (txt, val, sub, tono) => `<div class="pn-kpi ${tono || ""}"><span>${txt}</span><b>${val}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;
    el.querySelector("#clKpis").innerHTML =
      kpi("Clientes", r.total, `${r.compradores} con compras pagadas`) +
      kpi("Nuevos este mes", r.nuevosMes, "primera compra este mes") +
      kpi("Vuelven a comprar", `${r.recurrencia}%`, `${r.recurrentes} con 2 o más pedidos`) +
      kpi("Ticket promedio", clp(r.ticket), "por pedido pagado") +
      kpi("Por recuperar", r.porRecuperar, `sin comprar hace más de ${L.CLIENTES.recuperarDias} días`, r.porRecuperar ? "alerta" : "");
  }

  function pintarChips() {
    const n = L.contarSegmentos(lista);
    el.querySelector("#clChips").innerHTML = Object.entries(L.SEGMENTOS_CLIENTE).map(([k, txt]) =>
      `<button type="button" role="tab" data-s="${k}" aria-selected="${filtro.segmento === k}">${esc(txt)} <span>${n[k] || 0}</span></button>`).join("");
    el.querySelector("#clAyuda").textContent = AYUDA[filtro.segmento] || "";
  }

  function pintarLista() {
    const items = L.filtrarClientes(lista, filtro);
    const box = el.querySelector("#clLista");
    if (!items.length) {
      box.innerHTML = `<div class="pn-vacio">${lista.length ? "No hay clientes con este filtro." : "Aún no hay clientes."}</div>`;
      return;
    }
    const filas = items.slice(0, MAX_FILAS);
    box.innerHTML = `
      <table class="pn-tabla cl-tabla">
        <thead><tr><th>Cliente</th><th>Comuna</th><th class="num">Pedidos</th><th class="num">Gastado</th><th>Último pedido</th><th class="num">Puntos</th></tr></thead>
        <tbody>${filas.map((c) => `
          <tr data-id="${esc(c.id)}" tabindex="0">
            <td data-l="Cliente"><b>${esc(c.nombre || "Sin nombre")}</b>${etiquetas(c)}<small>${esc(c.email || L.telefonoVisible(c.telefono))}</small></td>
            <td data-l="Comuna">${esc(c.comuna || "—")}</td>
            <td data-l="Pedidos" class="num">${c.pedidos}<span class="cl-movil"> pedido${c.pedidos === 1 ? "" : "s"}</span></td>
            <td data-l="Gastado" class="num">${clp(c.gastado)}</td>
            <td data-l="Último pedido">${c.ultimo_pedido ? `${fecha(c.ultimo_pedido)}<small>${hace(c.ultimo_pedido)}</small>` : "Sin compras"}</td>
            <td data-l="Puntos" class="num">${c.invitado ? "—" : esc(c.puntos)}</td>
          </tr>`).join("")}</tbody>
      </table>
      ${items.length > MAX_FILAS ? `<p class="cl-mas">Se muestran ${MAX_FILAS} de ${items.length}. Usa el buscador para encontrar a alguien.</p>` : ""}`;
  }

  /* ---------- Ficha del cliente ---------- */
  async function abrir(id) {
    UI.abrirDetalle(`<div class="pn-vacio"><span class="pn-spin"></span></div>`);
    let c;
    try { c = await A().cliente(id); } catch (e) { actual = null; return UI.abrirDetalle(`<div class="pn-vacio">${esc(A().msg(e))}</div>`); }
    actual = c;

    const k = c.contacto || {};
    const nombre = c.invitado ? (k.nombre || "Invitado") : [c.nombre, c.apellido].filter(Boolean).join(" ");
    const tel = c.telefono || k.telefono;
    const email = c.email || k.email;
    const r = c.resumen || {};
    const ticket = r.pedidos ? Math.round(r.gastado / r.pedidos) : 0;
    const wa = L.linkWhatsApp(tel, `Hola ${nombre.split(" ")[0]}, te escribimos de Befine.`);
    const llamar = L.telLink(tel);
    const gestiona = app.puede("clientes.gestionar") && !c.invitado;
    const verPed = pedidosVisibles();

    const acciones = gestiona ? `
      <button type="button" class="pn-btn" data-cl="editar">Editar datos</button>
      ${c.activo ? (c.rol === "cliente" ? `<button type="button" class="pn-btn peligro" data-cl="bloquear">Bloquear</button>` : "")
                 : `<button type="button" class="pn-btn ok" data-cl="activar">Activar</button>`}
      ${c.activo && c.rol !== "cliente" ? `<p class="pn-nota">Es parte del equipo: su acceso se gestiona en "Equipo y roles".</p>` : ""}` : "";

    const avisos =
      (c.activo === false ? `<p class="cl-aviso blq"><b>Bloqueado:</b> no puede comprar en la tienda. Sus pedidos anteriores se conservan.</p>` : "") +
      (c.invitado ? `<p class="cl-aviso inv"><b>Invitado:</b> compró sin crear cuenta. Sus datos vienen del último pedido y no se editan.</p>` : "");

    const empresa = c.empresa || c.rut ? `
      <section class="pn-det"><h3>Empresa</h3>
        <p>${c.rut ? `RUT ${esc(L.formatoRut(c.rut))}` : "Sin RUT"}${c.empresa ? "" : " · <small>no marcado como empresa</small>"}<br>
        ${esc(c.razon_social || "Sin razón social")}${c.giro ? ` · ${esc(c.giro)}` : ""}</p>
      </section>` : "";

    const dirs = (c.direcciones || []).map((d) => `<li><span>${esc(d.calle)} ${esc(d.numero || "")}${d.depto ? ", depto " + esc(d.depto) : ""} · <b>${esc(d.comuna)}</b>${d.referencia ? `<small> · ${esc(d.referencia)}</small>` : ""}</span></li>`).join("");

    const peds = (c.pedidos || []).map((p) => `<li>
        ${verPed ? `<button type="button" class="pn-link" data-cl="pedido" data-id="${esc(p.id)}">#${esc(p.numero)}</button>` : `<b>#${esc(p.numero)}</b>`}
        <small>${fecha(p.created_at)}</small>${badgePedido(p.estado)}<span class="cl-der">${clp(p.total)}</span></li>`).join("");

    const movs = (c.movimientos || []).map((m) => `<li><small>${fecha(m.created_at)}</small><span>${esc(m.descripcion || m.tipo)}</span>
        <span class="cl-der cl-pts ${m.puntos >= 0 ? "mas" : "menos"}">${m.puntos > 0 ? "+" : ""}${esc(m.puntos)}</span></li>`).join("");

    const valor = (campo, v) => campo === "activo" ? (v ? "Activo" : "Bloqueado")
      : campo === "es_empresa" ? (v ? "Sí" : "No")
      : campo === "telefono" ? (v ? L.telefonoVisible(v) : "—")
      : campo === "rut" ? (v ? L.formatoRut(v) : "—") : (v == null || v === "" ? "—" : v);
    const cambios = (c.cambios || []).map((x) => `<li><b>${fecha(x.created_at, true)}</b><span>${esc(x.por || "—")}</span>
        <small>${Object.keys(x.despues || {}).map((f) => `${esc(CAMPOS[f] || f)}: ${esc(valor(f, (x.antes || {})[f]))} → ${esc(valor(f, x.despues[f]))}`).join(" · ")}</small></li>`).join("");

    UI.abrirDetalle(`
      <div class="pn-det-head"><h2>${esc(nombre || "Sin nombre")}</h2>${etiquetas(c)}<small>${c.invitado ? "Primer pedido" : "Cliente desde"} ${fecha(c.invitado ? r.primer_pedido || c.creado : c.creado)}</small></div>
      ${avisos}
      ${acciones ? `<div class="pn-det-acc">${acciones}</div>` : ""}

      <section class="pn-det"><h3>Contacto</h3>
        <p>${esc(L.telefonoVisible(tel))} · ${esc(email || "sin correo")}</p>
        <div class="pn-det-bot">
          ${wa ? `<a class="pn-btn sm ok" href="${esc(wa)}" target="_blank" rel="noopener">${ICONOS.whatsapp}WhatsApp</a>` : ""}
          ${llamar ? `<a class="pn-btn sm ghost" href="${esc(llamar)}">Llamar</a>` : ""}
          ${email ? `<a class="pn-btn sm ghost" href="mailto:${esc(email)}">Correo</a>` : ""}
        </div>
      </section>

      <section class="pn-det"><h3>Compras</h3>
        <div class="cl-stats">
          <div><span>Pedidos pagados</span><b>${esc(r.pedidos || 0)}</b></div>
          <div><span>Total gastado</span><b>${clp(r.gastado)}</b></div>
          <div><span>Ticket promedio</span><b>${clp(ticket)}</b></div>
          <div><span>Último pedido</span><b>${r.ultimo_pedido ? fecha(r.ultimo_pedido) : "—"}</b>${r.ultimo_pedido ? `<small>${hace(r.ultimo_pedido)}</small>` : ""}</div>
        </div>
      </section>

      ${empresa}

      <section class="pn-det"><h3>Direcciones</h3><ul class="cl-lista">${dirs || "<li>Sin direcciones guardadas</li>"}</ul></section>

      <section class="pn-det"><h3>Últimos pedidos</h3><ul class="cl-lista">${peds || "<li>Sin pedidos</li>"}</ul>
        ${verPed ? "" : `<p class="pn-nota">Tu rol no tiene acceso al detalle de los pedidos.</p>`}</section>

      ${c.invitado ? "" : `<section class="pn-det"><h3>Club Befine</h3>
        <p><b>${esc(c.puntos)} puntos</b>${c.codigo_referido ? ` · código <span class="cl-codigo">${esc(c.codigo_referido)}</span>` : ""}${c.referidos ? ` · invitó a ${esc(c.referidos)} amigo${c.referidos === 1 ? "" : "s"}` : ""}</p>
        <ul class="cl-lista">${movs || "<li>Sin movimientos de puntos</li>"}</ul></section>`}

      ${cambios ? `<section class="pn-det"><h3>Cambios hechos por el negocio</h3><ol class="pn-hist cl-cambios">${cambios}</ol></section>` : ""}`);
  }

  function abrirPedido(id) {
    const P = window.AdminApp.SECCIONES.pedidos;
    if (P && P.abrir) P.abrir(id);
  }

  /* ---------- Editar datos ---------- */
  function editar() {
    const c = actual; if (!c) return;
    const ini = {
      nombre: c.nombre || "", apellido: c.apellido || "",
      telefono: c.telefono ? L.telefonoVisible(c.telefono) : (c.telefono_raw || ""),
      es_empresa: !!c.empresa, rut: c.rut ? L.formatoRut(c.rut) : "",
      razon_social: c.razon_social || "", giro: c.giro || "",
    };
    UI.abrirModal(`<h2>Editar cliente</h2>
      <form class="pn-form" id="clForm" novalidate>
        <label>Nombre<input class="pn-inp" name="nombre" maxlength="80" autocomplete="off" value="${esc(ini.nombre)}"><span class="err" data-err="nombre"></span></label>
        <label>Apellido<input class="pn-inp" name="apellido" maxlength="80" autocomplete="off" value="${esc(ini.apellido)}"></label>
        <label class="full">Celular <small>vacío = sin celular</small><input class="pn-inp" name="telefono" inputmode="tel" placeholder="9 1234 5678" value="${esc(ini.telefono)}"><span class="err" data-err="telefono"></span></label>
        <label class="chk full"><input type="checkbox" name="es_empresa"${ini.es_empresa ? " checked" : ""}> Es empresa (compra con factura)</label>
        <label>RUT<input class="pn-inp" name="rut" placeholder="76.123.456-7" value="${esc(ini.rut)}"><span class="err" data-err="rut"></span></label>
        <label>Giro<input class="pn-inp" name="giro" maxlength="120" value="${esc(ini.giro)}"><span class="err" data-err="giro"></span></label>
        <label class="full">Razón social<input class="pn-inp" name="razon_social" maxlength="120" value="${esc(ini.razon_social)}"><span class="err" data-err="razon_social"></span></label>
        <p class="pn-nota full">El correo es el de su cuenta y no se cambia aquí. Cada cambio queda registrado con tu nombre.</p>
        <div class="pn-form-acc"><button type="button" class="pn-btn ghost" data-cancelar>Cancelar</button><button type="submit" class="pn-btn">Guardar</button></div>
      </form>`);
    const f = document.getElementById("clForm");
    f.querySelector("[data-cancelar]").addEventListener("click", UI.cerrarModal);
    f.addEventListener("submit", async (e) => {
      e.preventDefault();
      const d = {
        nombre: f.nombre.value.trim(), apellido: f.apellido.value.trim(), telefono: f.telefono.value.trim(),
        es_empresa: f.es_empresa.checked, rut: f.rut.value.trim(), razon_social: f.razon_social.value.trim(), giro: f.giro.value.trim(),
      };
      const errs = L.validarCliente(d);
      f.querySelectorAll("[data-err]").forEach((s) => { s.textContent = errs[s.dataset.err] || ""; });
      f.querySelectorAll(".pn-inp").forEach((i) => i.classList.toggle("mal", !!errs[i.name]));
      if (Object.keys(errs).length) return;
      // Solo se envía lo que cambió (el servidor vuelve a validar todo)
      const datos = {};
      Object.keys(d).forEach((key) => { if (d[key] !== ini[key]) datos[key] = d[key]; });
      if (!Object.keys(datos).length) { UI.cerrarModal(); return UI.toast("No hay cambios que guardar."); }
      const r = await UI.conCarga(f.querySelector('[type="submit"]'), () => A().editarCliente(c.id, datos));
      if (!r.ok) return UI.toast(r.error, "mal");
      UI.cerrarModal();
      UI.toast(r.sin_cambios ? "No hay cambios que guardar." : "Cliente actualizado.");
      await cargar(); abrir(c.id);
    });
  }

  async function cambiarActivo(btn, activo) {
    const c = actual; if (!c) return;
    const nombre = [c.nombre, c.apellido].filter(Boolean).join(" ");
    const ok = await UI.confirmar(activo ? `¿Activar a ${nombre}?` : `¿Bloquear a ${nombre}?`,
      activo ? "Podrá volver a comprar en la tienda." : "No podrá comprar en la tienda hasta que lo actives. Sus pedidos y puntos se conservan. El cambio queda registrado.",
      activo ? "Activar" : "Bloquear", !activo);
    if (!ok) return;
    const r = await UI.conCarga(btn, () => A().editarCliente(c.id, { activo }));
    if (!r.ok) return UI.toast(r.error, "mal");
    UI.toast(activo ? "Cliente activado." : "Cliente bloqueado.");
    await cargar(); abrir(c.id);
  }

  window.AdminApp.SECCIONES.clientes = { montar, mostrar };
})();
