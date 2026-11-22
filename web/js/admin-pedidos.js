/* =====================================================================
   admin-pedidos.js — Sección "Pedidos" del panel (RF-16)
   ---------------------------------------------------------------------
   - Indicadores del día y del mes, filtros por estado, por fecha de
     entrega (hoy, siguiente día hábil, esta semana o rango) y búsqueda.
   - Detalle del pedido en panel lateral: cliente (WhatsApp/llamar),
     dirección, productos, montos, documento e historial de estados.
   - Cambios de estado según el flujo (AdminLogic.TRANSICIONES), solo si
     el rol tiene pedidos.gestionar. El chofer (pedidos.ver) solo consulta.
   - Boleta o factura (migración 19, opción A): se emite en Haulmer con los
     datos que muestra el panel y se sube el PDF; el cliente lo descarga en
     Mis pedidos. Solo con el permiso documentos.gestionar.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const { esc, fecha, ICONOS, UI } = window.AdminApp;
  const A = () => Befine.admin;
  const clp = (n) => Befine.clp(n || 0);

  const HAULMER = "https://espacio.haulmer.com";
  let el, app, lista = [], filtro = { estado: "activos", q: "", entrega: "todas", desde: "", hasta: "" }, cargado = false, timer = null;

  const badge = (e) => `<span class="pn-est ${(L.ESTADOS[e] || {}).tono || ""}">${esc(L.etiquetaEstado(e))}</span>`;
  const dir = (d) => d ? `${esc(d.calle)} ${esc(d.numero)}${d.depto ? ", depto " + esc(d.depto) : ""}` : "—";

  function montar(seccion, appCtx) {
    el = seccion; app = appCtx;
    el.innerHTML = `
      <div class="pn-head">
        <div><h1>Pedidos</h1><p>Últimos 90 días · se actualiza cada 2 minutos</p></div>
        <div class="acciones">
          <label class="pn-buscar">${ICONOS.buscar}<input class="pn-inp" id="pqBuscar" type="search" placeholder="N°, cliente, teléfono o comuna" aria-label="Buscar pedidos"></label>
          <button class="pn-btn ghost" type="button" id="pqRecargar" title="Actualizar">${ICONOS.recargar}<span>Actualizar</span></button>
        </div>
      </div>
      <div class="pn-kpis" id="pqKpis"></div>
      <div class="pn-chips" id="pqChips" role="tablist" aria-label="Filtrar por estado"></div>
      <div class="pn-entrega">
        <span class="pn-entrega-tit">Entrega</span>
        <div class="pn-chips sm" id="pqEntrega" role="tablist" aria-label="Filtrar por fecha de entrega"></div>
        <div class="pn-rango" id="pqRango" hidden>
          <label>Desde <input class="pn-inp" type="date" id="pqDesde"></label>
          <label>Hasta <input class="pn-inp" type="date" id="pqHasta"></label>
        </div>
        <small class="pn-rango-txt" id="pqRangoTxt" aria-live="polite"></small>
      </div>
      <div class="pn-card pn-lista" id="pqLista"><div class="pn-vacio"><span class="pn-spin"></span></div></div>`;

    let t;
    el.querySelector("#pqBuscar").addEventListener("input", (e) => {
      clearTimeout(t); t = setTimeout(() => { filtro.q = e.target.value; pintarLista(); }, 150);
    });
    el.querySelector("#pqRecargar").addEventListener("click", (e) => UI.conCarga(e.currentTarget, cargar));
    el.querySelector("#pqChips").addEventListener("click", (e) => {
      const b = e.target.closest("[data-f]"); if (!b) return;
      filtro.estado = b.dataset.f; pintarChips(); pintarKpis(); pintarLista();
    });
    el.querySelector("#pqKpis").addEventListener("click", (e) => {
      if (!e.target.closest("[data-kpi-doc]")) return;
      filtro.estado = filtro.estado === "sin_documento" ? "activos" : "sin_documento";
      pintarChips(); pintarKpis(); pintarLista();
    });
    el.querySelector("#pqEntrega").addEventListener("click", (e) => {
      const b = e.target.closest("[data-e]"); if (!b) return;
      filtro.entrega = b.dataset.e;
      el.querySelector("#pqRango").hidden = filtro.entrega !== "rango";
      if (filtro.entrega === "rango" && !filtro.desde && !filtro.hasta) el.querySelector("#pqDesde").focus();
      pintarChips(); pintarLista();
    });
    ["#pqDesde", "#pqHasta"].forEach((id) => el.querySelector(id).addEventListener("change", () => {
      filtro.desde = el.querySelector("#pqDesde").value; filtro.hasta = el.querySelector("#pqHasta").value;
      pintarChips(); pintarLista();
    }));
    el.querySelector("#pqLista").addEventListener("click", (e) => {
      const fila = e.target.closest("[data-id]"); if (fila) abrir(fila.dataset.id);
    });
    // Acciones dentro del panel lateral (cambiar estado, copiar datos para Haulmer, ver/subir documento)
    const drawer = document.getElementById("pnDrawerIn");
    drawer.addEventListener("click", async (e) => {
      const cp = e.target.closest("[data-copiar]");
      if (cp) return copiar(cp.dataset.copiar);
      const ver = e.target.closest("[data-ver-doc]");
      if (ver) return verDocumento(ver);
      const env = e.target.closest("[data-enviar-doc]");
      if (env) return enviarCorreoDoc(env, env.dataset.enviarDoc, env.dataset.reenviar === "1");
      const rem = e.target.closest("[data-reemplazar]");
      if (rem) { const f = drawer.querySelector("#dteForm"); if (f) { f.hidden = false; rem.hidden = true; } return; }
      const b = e.target.closest("[data-estado]"); if (!b) return;
      await cambiar(b, b.dataset.id, b.dataset.de, b.dataset.estado);
    });
    drawer.addEventListener("change", (e) => {
      if (e.target.id !== "dteArchivo") return;
      const f = e.target.files && e.target.files[0], leido = f && L.leerNombreDTE(f.name);
      const folio = drawer.querySelector("#dteFolio"), aviso = drawer.querySelector("#dteAviso");
      if (leido && folio) folio.value = leido.folio;   // Haulmer pone el folio en el nombre del PDF
      aviso.textContent = leido ? `Detectado: ${leido.tipo} N° ${leido.folio}` : (f ? "Escribe el folio del documento." : "");
    });
    drawer.addEventListener("submit", (e) => {
      if (e.target.id !== "dteForm") return;
      e.preventDefault(); guardarDocumento(e.target);
    });
  }

  async function mostrar() {
    if (!cargado) await cargar();
    clearInterval(timer);
    timer = setInterval(() => { if (!document.hidden && !el.hidden) cargar(true); }, 120000);
  }

  async function cargar(silencioso) {
    try {
      lista = await A().listPedidos();
      cargado = true;
      pintarKpis(); pintarChips(); pintarLista();
    } catch (e) {
      if (!silencioso) {
        el.querySelector("#pqLista").innerHTML = `<div class="pn-vacio">No pudimos cargar los pedidos. ${esc(A().msg(e))}</div>`;
        UI.toast(A().msg(e), "mal");
      }
    }
  }

  function pintarKpis() {
    const r = L.resumenPedidos(lista);
    const kpi = (txt, val, sub, tono) => `<div class="pn-kpi ${tono || ""}"><span>${txt}</span><b>${val}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;
    el.querySelector("#pqKpis").innerHTML =
      kpi("Pedidos de hoy", r.hoy) +
      kpi("Por preparar", r.porPreparar, r.entregaHoy ? `${r.entregaHoy} se entregan hoy` : "pagados sin despachar", r.porPreparar ? "alerta" : "") +
      kpi("En camino", r.enRuta) +
      kpi("Ventas del mes", clp(r.ventasMes), `${r.pedidosMes} pedido${r.pedidosMes === 1 ? "" : "s"} pagado${r.pedidosMes === 1 ? "" : "s"}`) +
      kpi("Esperando pago", r.pendientesPago, "Mercado Pago confirma solo") +
      (app.puede("documentos.gestionar") ? (() => {
        const n = lista.filter(L.pendienteDocumento).length;
        // Tarjeta clicable: filtra la lista a los pedidos sin boleta/factura (y vuelve a "Para gestionar")
        return `<button type="button" class="pn-kpi ${n ? "alerta" : ""}" data-kpi-doc aria-pressed="${filtro.estado === "sin_documento"}" title="Ver solo los pedidos sin boleta o factura"><span>Boletas por subir</span><b>${n}</b><small>${n ? "pagados sin documento · ver" : "todo al día"}</small></button>`;
      })() : "");
    const cnt = document.getElementById("cnt-pedidos");
    if (cnt) { cnt.textContent = r.porPreparar; cnt.hidden = !r.porPreparar; }
  }

  const rango = () => L.rangoEntrega(filtro.entrega, new Date(), filtro.desde, filtro.hasta);

  function pintarChips() {
    const r = rango();
    // Los contadores por estado consideran el filtro de entrega elegido
    const c = L.contarPorEstado(L.filtrarPedidos(lista, { entrega: r }));
    const ops = [["activos", "Para gestionar"], ["todos", "Todos"],
      ...(app.puede("documentos.gestionar") ? [["sin_documento", "Sin boleta/factura"]] : []),
      ...L.ORDEN_ESTADOS.map((e) => [e, L.etiquetaEstado(e)])];
    el.querySelector("#pqChips").innerHTML = ops.map(([k, t]) =>
      `<button type="button" role="tab" data-f="${k}" aria-selected="${filtro.estado === k}">${esc(t)} <span>${c[k] || 0}</span></button>`).join("");
    el.querySelector("#pqEntrega").innerHTML = Object.entries(L.OPCIONES_ENTREGA).map(([k, t]) =>
      `<button type="button" role="tab" data-e="${k}" aria-selected="${filtro.entrega === k}">${esc(t)}</button>`).join("");
    el.querySelector("#pqRangoTxt").textContent = r ? L.textoRango(r) : "";
  }

  function pintarLista() {
    const r = rango();
    const items = L.filtrarPedidos(lista, { estado: filtro.estado, q: filtro.q, entrega: r });
    // Con un filtro de entrega, la lista se ordena por fecha de entrega (para planificar el reparto)
    if (r) items.sort((a, b) => String(a.fecha_entrega).localeCompare(String(b.fecha_entrega)) || a.numero - b.numero);
    const box = el.querySelector("#pqLista");
    if (!items.length) {
      box.innerHTML = `<div class="pn-vacio">${lista.length ? "No hay pedidos con este filtro." : "Aún no hay pedidos en los últimos 90 días."}</div>`;
      return;
    }
    box.innerHTML = `
      <table class="pn-tabla pn-ped">
        <thead><tr><th>N°</th><th>Fecha</th><th>Cliente</th><th>Comuna</th><th>Entrega</th><th class="num">Total</th><th>Estado</th></tr></thead>
        <tbody>${items.map((p) => `
          <tr data-id="${esc(p.id)}" tabindex="0">
            <td data-l="N°"><button type="button" class="pn-link">#${esc(p.numero)}</button></td>
            <td data-l="Fecha">${fecha(p.created_at, true)}</td>
            <td data-l="Cliente"><b>${esc(p.contacto_nombre || "—")}</b><small>${p.unidades} producto${p.unidades === 1 ? "" : "s"}${p.tipo_documento === "factura" ? " · factura" : ""}</small></td>
            <td data-l="Comuna">${esc((p.direccion && p.direccion.comuna) || "—")}</td>
            <td data-l="Entrega">${fecha(p.fecha_entrega)}</td>
            <td data-l="Total" class="num">${clp(p.total)}</td>
            <td data-l="Estado">${badge(p.estado)}${app.puede("documentos.gestionar") && L.pendienteDocumento(p) ? `<small class="pn-doc-pend">${p.tipo_documento === "factura" ? "Factura" : "Boleta"} pendiente</small>` : ""}</td>
          </tr>`).join("")}</tbody>
      </table>`;
    box.querySelectorAll("tr[data-id]").forEach((tr) => tr.addEventListener("keydown", (e) => { if (e.key === "Enter") abrir(tr.dataset.id); }));
  }

  /* ---------- Detalle ---------- */
  async function abrir(id) {
    UI.abrirDetalle(`<div class="pn-vacio"><span class="pn-spin"></span></div>`);
    let p;
    try { p = await A().getPedido(id); } catch (e) { return UI.abrirDetalle(`<div class="pn-vacio">${esc(A().msg(e))}</div>`); }
    if (!p) return UI.abrirDetalle(`<div class="pn-vacio">No encontramos el pedido.</div>`);

    const nom = (p.contacto_nombre || "").split(" ")[0] || "";
    const wa = L.linkWhatsApp(p.contacto_telefono, `Hola ${nom}, te escribimos de Befine por tu pedido #${p.numero}.`);
    const items = (p.detalle_pedido || []).map((d) => {
      const v = d.variante || {}, pr = v.producto || {};
      return `<li><span class="q">${d.cantidad}×</span><span class="n">${esc(pr.nombre || "Producto")}${v.nombre && v.nombre !== "Estándar" ? ` <small>${esc(v.nombre)}</small>` : ""}<small>${esc(v.sku || "")} · ${clp(d.precio_unitario)} c/u</small></span><b>${clp(d.subtotal)}</b></li>`;
    }).join("");
    const hist = (p.historial_pedido || []).map((h) =>
      `<li><b>${esc(L.etiquetaEstado(h.estado_nuevo))}</b><span>${fecha(h.created_at, true)}</span>${h.nota ? `<small>${esc(h.nota)}</small>` : ""}</li>`).join("");

    const gestiona = app.puede("pedidos.gestionar");
    const sig = gestiona ? L.siguientesEstados(p.estado) : [];
    const acciones = sig.map((e) => `<button type="button" class="pn-btn ${e === "cancelado" ? "peligro" : e === "entregado" ? "ok" : ""}"
        data-id="${esc(p.id)}" data-de="${esc(p.estado)}" data-estado="${e}">${esc(L.ACCION_ESTADO[e] || L.etiquetaEstado(e))}</button>`).join("");
    const nota = p.estado === "pendiente_pago"
      ? `<p class="pn-nota">El pedido pasa a <b>Pagado</b> automáticamente cuando Mercado Pago confirma el pago. Un pedido sin pagar no sale a reparto.</p>` : "";

    UI.abrirDetalle(`
      <div class="pn-det-head"><h2>Pedido #${esc(p.numero)}</h2>${badge(p.estado)}<small>Creado el ${fecha(p.created_at, true)}</small></div>
      ${acciones || nota ? `<div class="pn-det-acc">${acciones}${nota}</div>` : ""}

      <section class="pn-det"><h3>Cliente</h3>
        <p><b>${esc(p.contacto_nombre || "—")}</b><br>${esc(L.telefonoVisible(p.contacto_telefono))} · ${esc(p.contacto_email || "—")}</p>
        <div class="pn-det-bot">
          ${wa ? `<a class="pn-btn sm ok" href="${esc(wa)}" target="_blank" rel="noopener">${ICONOS.whatsapp}WhatsApp</a>` : ""}
          ${p.contacto_telefono ? `<a class="pn-btn sm ghost" href="tel:+${esc(String(p.contacto_telefono).replace(/\D/g, ""))}">Llamar</a>` : ""}
        </div>
      </section>

      <section class="pn-det"><h3>Entrega</h3>
        <p>${dir(p.direccion)}<br>${esc((p.direccion && p.direccion.comuna) || "")}${p.zona && p.zona.nombre !== (p.direccion && p.direccion.comuna) ? ` · zona ${esc(p.zona.nombre)}` : ""}</p>
        ${p.direccion && p.direccion.referencia ? `<p class="pn-ref">Referencia: ${esc(p.direccion.referencia)}</p>` : ""}
        <p>Fecha de entrega: <b>${fecha(p.fecha_entrega)}</b></p>
        ${p.notas ? `<p class="pn-ref">Nota del cliente: ${esc(p.notas)}</p>` : ""}
      </section>

      <section class="pn-det"><h3>Productos</h3>
        <ul class="pn-items">${items || "<li>Sin productos</li>"}</ul>
        <dl class="pn-tot">
          <div><dt>Subtotal</dt><dd>${clp(p.subtotal)}</dd></div>
          <div><dt>Despacho</dt><dd>${p.costo_despacho ? clp(p.costo_despacho) : "Gratis"}</dd></div>
          ${p.descuento_cupon ? `<div><dt>Cupón ${p.cupon ? esc(p.cupon.codigo) : ""}</dt><dd>−${clp(p.descuento_cupon)}</dd></div>` : ""}
          <div class="t"><dt>Total</dt><dd>${clp(p.total)}</dd></div>
        </dl>
      </section>

      ${htmlDocumento(p)}

      <section class="pn-det"><h3>Historial</h3><ol class="pn-hist">${hist || "<li>Sin movimientos</li>"}</ol></section>`);
  }

  /* ---------- Boleta o factura (migración 19) ---------- */
  function htmlDocumento(p) {
    const doc = L.documentoDe(p), puede = app.puede("documentos.gestionar");
    const nombre = p.tipo_documento === "factura" ? "Factura" : "Boleta";
    const cab = p.tipo_documento === "factura"
      ? `<p>Factura · RUT ${esc(L.formatoRut(p.doc_rut))}<br>${esc(p.doc_razon_social)} · ${esc(p.doc_giro)}</p>` : `<p>Boleta electrónica</p>`;
    if (!puede) return `<section class="pn-det"><h3>Documento</h3>${cab}${doc ? `<p><b>${nombre} N° ${esc(doc.folio)}</b> emitida</p>` : ""}</section>`;

    const form = (oculto) => `
      <form class="pn-dte-form" id="dteForm" data-id="${esc(p.id)}" data-tipo="${esc(p.tipo_documento || "boleta")}" data-actual="${esc((doc && doc.archivo) || "")}"${oculto ? " hidden" : ""}>
        <label>PDF descargado de Haulmer<input class="pn-inp" type="file" id="dteArchivo" accept="application/pdf,.pdf" required></label>
        <label>Folio<input class="pn-inp" type="number" id="dteFolio" min="1" step="1" inputmode="numeric" placeholder="Ej. 11298" required></label>
        <small id="dteAviso" class="pn-nota" aria-live="polite"></small>
        <button class="pn-btn ok" type="submit">Guardar y enviar al cliente</button>
      </form>`;

    if (doc) {
      const c = L.estadoCorreoDoc(doc);
      return `
      <section class="pn-det"><h3>Documento</h3>${cab}
        <p class="pn-dte-ok">${nombre} N° <b>${esc(doc.folio)}</b> · subida el ${fecha(doc.fecha_emision, true)}</p>
        <p class="pn-dte-correo ${c.estado}">${esc(c.texto)}</p>
        <div class="pn-det-bot">
          ${doc.archivo ? `<button type="button" class="pn-btn sm ghost" data-ver-doc="${esc(doc.archivo)}">Ver PDF</button>` : ""}
          ${doc.archivo ? `<button type="button" class="pn-btn sm ghost" data-enviar-doc="${esc(p.id)}" data-reenviar="${c.estado === "enviado" ? 1 : 0}">${c.estado === "enviado" ? "Reenviar correo" : "Enviar por correo"}</button>` : ""}
          <button type="button" class="pn-btn sm ghost" data-reemplazar>Reemplazar</button>
        </div>${form(true)}
      </section>`;
    }

    if (!L.pendienteDocumento(p)) return `<section class="pn-det"><h3>Documento</h3>${cab}
      <p class="pn-nota">${(Number(p.total) || 0) <= 0 ? "Canje de $0: no lleva documento." : "Se emite cuando el pedido esté pagado."}</p></section>`;

    const d = L.datosHaulmer(p);
    const fila = (k, v, pegar) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}${pegar != null && pegar !== ""
      ? ` <button type="button" class="pn-copiar" data-copiar="${esc(pegar)}" aria-label="Copiar ${esc(k)}">Copiar</button>` : ""}</dd></div>`;
    const receptor = d.receptor ? `
        <h4>Receptor</h4>
        <dl class="pn-dte-datos">
          ${fila("RUT", d.receptor.rut, d.receptor.rut)}${fila("Razón social", d.receptor.razon_social, d.receptor.razon_social)}
          ${fila("Giro", d.receptor.giro, d.receptor.giro)}${fila("Dirección", d.receptor.direccion, d.receptor.direccion)}
          ${fila("Comuna", d.receptor.comuna, d.receptor.comuna)}${fila("Correo", d.receptor.email, d.receptor.email)}
        </dl>
        <p class="pn-nota">Forma de pago: cámbiala a <b>Contado</b> (Haulmer trae "Crédito").</p>` : "";
    const lineas = d.lineas.map((l) => `
          <li><span class="n">${esc(l.nombre)}<small>${l.codigo ? "Código " + esc(l.codigo) + " · " : ""}cantidad ${esc(l.cantidad)} · ${d.receptor ? "precio neto" : "precio con IVA"} ${esc(L.fmtCLP(l.precio, l.dec))}</small></span>
            <span class="b"><button type="button" class="pn-copiar" data-copiar="${esc(l.cantidad)}">Cantidad</button><button type="button" class="pn-copiar" data-copiar="${esc(L.valorPegar(l.precio, l.dec))}">Precio</button></span></li>`).join("");
    return `
      <section class="pn-det"><h3>Documento · ${nombre} pendiente</h3>${cab}
        <ol class="pn-dte-pasos">
          <li><a class="pn-btn sm" href="${HAULMER}" target="_blank" rel="noopener">Abrir Haulmer</a> → Emitir → <b>${nombre} Electrónica</b>.</li>
          <li>Copia estos datos en el formulario:</li>
        </ol>
        ${receptor}
        <h4>Detalle</h4>
        <ul class="pn-dte-lineas">${lineas}</ul>
        ${d.descuento ? `<p class="pn-nota">Descuento del cupón: <b>${esc(L.fmtCLP(d.descuento))}</b> (con IVA) en "Dsto/Rcgo".</p>` : ""}
        <dl class="pn-dte-datos pn-dte-tot">
          <div><dt>Monto neto</dt><dd>${esc(L.fmtCLP(d.montos.neto))}</dd></div>
          <div><dt>IVA 19%</dt><dd>${esc(L.fmtCLP(d.montos.iva))}</dd></div>
          <div><dt>Total (debe coincidir)</dt><dd><b>${esc(L.fmtCLP(d.montos.total))}</b></dd></div>
        </dl>
        <ol class="pn-dte-pasos" start="3"><li>Emite en Haulmer, descarga el PDF y súbelo aquí. Le llega al cliente por correo (${esc(p.contacto_email || "su correo")}) con el PDF adjunto:</li></ol>
        ${form(false)}
      </section>`;
  }

  async function copiar(texto) {
    try { await navigator.clipboard.writeText(texto); UI.toast("Copiado: " + texto); }
    catch (e) { UI.toast("No se pudo copiar. Selecciona el texto y cópialo a mano.", "mal"); }
  }

  async function verDocumento(btn) {
    const w = window.open("", "_blank");   // se abre al tocar (si no, el navegador la bloquea)
    try {
      const url = await UI.conCarga(btn, () => A().urlDocumento(btn.dataset.verDoc));
      if (w) w.location.href = url; else location.href = url;
    } catch (e) { if (w) w.close(); UI.toast(A().msg(e), "mal"); }
  }

  async function guardarDocumento(form) {
    const id = form.dataset.id, tipo = form.dataset.tipo;
    const archivo = form.querySelector("#dteArchivo").files[0];
    const folio = Number(form.querySelector("#dteFolio").value);
    const err = L.validarDocumento(archivo, tipo, folio);
    if (err) return UI.toast(err, "mal");
    const btn = form.querySelector("[type=submit]");
    try {
      // Se guarda y, apenas queda registrada, se envía al cliente con el PDF adjunto
      // (si ese mismo folio ya se le había enviado, no se repite)
      const r = await UI.conCarga(btn, async () => {
        const x = await A().subirDocumento(id, archivo, tipo, folio, form.dataset.actual || null);
        if (x.ok) x.correo = await A().enviarDocumento(id);
        return x;
      });
      if (!r.ok) return UI.toast(r.mensaje || "No pudimos registrar el documento.", "mal");
      const nom = tipo === "factura" ? "Factura" : "Boleta", c = r.correo;
      if (c.enviado) UI.toast(`${nom} N° ${folio} guardada y enviada a ${c.destino || "el cliente"}.`);
      else if (c.ok) UI.toast(`${nom} N° ${folio} guardada${c.motivo === "ya_enviado" ? " (el cliente ya la había recibido por correo)" : ""}.`);
      else UI.toast(`${nom} N° ${folio} guardada. ${c.mensaje} Usa "Enviar por correo" para reintentar.`, "mal");
      await cargar(true);
      abrir(id);
    } catch (e) { UI.toast(A().msg(e), "mal"); }
  }

  async function enviarCorreoDoc(btn, id, reenviar) {
    const c = await UI.conCarga(btn, () => A().enviarDocumento(id, reenviar));
    if (c.enviado) UI.toast(`Enviada a ${c.destino || "el cliente"}.`);
    else if (c.ok) UI.toast(c.mensaje || "Ya se había enviado por correo.");
    else UI.toast(c.mensaje || "No se pudo enviar el correo.", "mal");
    await cargar(true);
    abrir(id);
  }

  async function cambiar(btn, id, de, a) {
    if (a === "cancelado") {
      const p = lista.find((x) => x.id === id) || {};
      const ok = await UI.confirmar(`¿Cancelar el pedido #${p.numero || ""}?`,
        "El pedido queda cerrado y no se podrá reactivar. Si usó un cupón, ese uso se libera para el cliente.",
        "Sí, cancelar", true);
      if (!ok) return;
    }
    const r = await UI.conCarga(btn, () => A().cambiarEstado(id, de, a));
    if (!r.ok) UI.toast(r.error, "mal"); else UI.toast(`Pedido actualizado: ${L.etiquetaEstado(a)}.`);
    await cargar(true);
    if (r.ok || r.recargar) abrir(id);
  }

  window.AdminApp.SECCIONES.pedidos = { montar, mostrar, abrir };   // abrir(id): también desde la ficha del cliente
})();
