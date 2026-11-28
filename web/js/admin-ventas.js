/* =====================================================================
   admin-ventas.js — Sección "Ventas" del panel (migración 23)
   ---------------------------------------------------------------------
   CHOFER (pedidos.registrar): su planilla del día, pensada para el celular en la calle.
     - "Anotar venta": productos con + y −, cómo pagó, celular (+56 9) y dirección. Al escribir el
       celular de un cliente que ya compró, se completan su dirección, trato y nombre.
     - Al guardar se cierra solo y sigue trabajando: NO se envía nada al cliente.
     - Lo vendido hoy, el efectivo a rendir y la lista de ventas (puede anular las de hoy).
   ADMIN (caja.ver): la caja del día, la semana, el mes o un rango, de todo el equipo o de un chofer:
     ventas anotadas + pedidos entregados (web y fuera de la página), por medio de pago, por chofer
     y por día, con descarga en CSV para cuadrar el dinero.
   El servidor pone los precios, descuenta stock y valida todo; el navegador solo muestra.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const { esc, ICONOS, UI } = window.AdminApp;
  const A = () => Befine.admin;
  const clp = (n) => Befine.clp(n || 0);

  let el, app, esCaja = false, cargado = false, sucio = false;
  let opciones = null, opcionesAt = 0;
  // Chofer
  let diaChofer = "hoy", planilla = null;
  // Admin
  let periodo = "hoy", rDesde = "", rHasta = "", chofer = "", caja = null;

  const hoyIso = () => L.diaLocal(new Date());
  const ayerIso = () => L.diaLocal(new Date(Date.now() - 864e5));
  const fmtDia = (iso) => new Date(iso + "T12:00:00").toLocaleDateString("es-CL", { weekday: "long", day: "numeric", month: "long" });
  const fmtCorto = (iso) => new Date(iso + "T12:00:00").toLocaleDateString("es-CL", { weekday: "short", day: "numeric", month: "short" });
  const medio = (m) => `<span class="vt-medio ${esc(m)}">${esc(L.METODOS_PAGO[m] || m)}</span>`;
  const movs = (n) => `${n || 0} movimiento${n === 1 ? "" : "s"}`;   // ventas anotadas + pedidos entregados
  const itemsTxt = (v) => (v.items || []).map((i) => `${i.cantidad} × ${esc(i.producto)}${i.variante ? ` <small>(${esc(i.variante)})</small>` : ""}`).join("<br>");

  function montar(seccion, appCtx) {
    el = seccion; app = appCtx;
    esCaja = app.puede("caja.ver");
    const anota = app.puede("pedidos.registrar");
    el.innerHTML = esCaja ? `
      <div class="pn-head">
        <div><h1>Ventas y caja</h1><p id="vtSub">Lo vendido por el equipo</p></div>
        <div class="acciones">
          ${anota ? `<button class="pn-btn" type="button" data-anotar>${ICONOS.mas}<span>Anotar venta</span></button>` : ""}
          <button class="pn-btn ghost" type="button" id="vtCsv" title="Descargar las ventas anotadas en CSV (Excel)">CSV</button>
          <button class="pn-btn ghost" type="button" id="vtRecargar" title="Actualizar">${ICONOS.recargar}<span>Actualizar</span></button>
        </div>
      </div>
      <div class="vt-filtros">
        <div class="pn-chips sm" role="tablist" aria-label="Periodo" id="vtPeriodo">
          <button type="button" role="tab" data-p="hoy" aria-selected="true">Hoy</button>
          <button type="button" role="tab" data-p="semana" aria-selected="false">Esta semana</button>
          <button type="button" role="tab" data-p="mes" aria-selected="false">Este mes</button>
          <button type="button" role="tab" data-p="rango" aria-selected="false">Elegir fechas</button>
        </div>
        <div class="vt-rango" id="vtRango" hidden>
          <label>Desde<input class="pn-inp" type="date" id="vtDesde"></label>
          <label>Hasta<input class="pn-inp" type="date" id="vtHasta"></label>
        </div>
        <label class="vt-chofer">Chofer<select class="pn-inp" id="vtChofer"><option value="">Todo el equipo</option></select></label>
      </div>
      <div id="vtCaja"><div class="pn-vacio"><span class="pn-spin"></span></div></div>` : `
      <div class="pn-head">
        <div><h1>Mis ventas</h1><p id="vtSub"></p></div>
        <div class="acciones"><button class="pn-btn ghost" type="button" id="vtRecargar" title="Actualizar">${ICONOS.recargar}<span>Actualizar</span></button></div>
      </div>
      <button class="vt-anotar" type="button" data-anotar>${ICONOS.mas}<span>Anotar venta</span></button>
      <div class="pn-chips sm" role="tablist" aria-label="Día" id="vtDia">
        <button type="button" role="tab" data-d="hoy" aria-selected="true">Hoy</button>
        <button type="button" role="tab" data-d="ayer" aria-selected="false">Ayer</button>
      </div>
      <div id="vtPlanilla"><div class="pn-vacio"><span class="pn-spin"></span></div></div>`;

    el.addEventListener("click", (e) => {
      if (e.target.closest("[data-anotar]")) return abrirAnotar(e.target.closest("[data-anotar]"));
      const an = e.target.closest("[data-anular]"); if (an) return anular(an.dataset.anular, an.dataset.num);
      const p = e.target.closest("#vtPeriodo [data-p]");
      if (p) {
        periodo = p.dataset.p;
        el.querySelectorAll("#vtPeriodo [data-p]").forEach((x) => x.setAttribute("aria-selected", String(x === p)));
        el.querySelector("#vtRango").hidden = periodo !== "rango";
        if (periodo === "rango") {
          const r = L.rangoPeriodo("semana", new Date());
          const d = el.querySelector("#vtDesde"), h = el.querySelector("#vtHasta");
          if (!d.value) d.value = rDesde = r.desde;
          if (!h.value) h.value = rHasta = r.hasta;
        }
        return cargar();
      }
      const d = e.target.closest("#vtDia [data-d]");
      if (d && d.dataset.d !== diaChofer) {
        diaChofer = d.dataset.d;
        el.querySelectorAll("#vtDia [data-d]").forEach((x) => x.setAttribute("aria-selected", String(x === d)));
        return cargar();
      }
    });
    el.querySelector("#vtRecargar").addEventListener("click", (e) => UI.conCarga(e.currentTarget, cargar));
    if (esCaja) {
      el.querySelector("#vtChofer").addEventListener("change", (e) => { chofer = e.target.value; cargar(); });
      el.querySelector("#vtDesde").addEventListener("change", (e) => { rDesde = e.target.value; if (periodo === "rango") cargar(); });
      el.querySelector("#vtHasta").addEventListener("change", (e) => { rHasta = e.target.value; if (periodo === "rango") cargar(); });
      el.querySelector("#vtCsv").addEventListener("click", descargarCsv);
    }
  }

  async function mostrar() { if (!cargado || sucio) await cargar(); }

  async function cargar() {
    sucio = false;
    try {
      if (esCaja) {
        const r = L.rangoPeriodo(periodo, new Date(), rDesde, rHasta);
        caja = await A().caja(r.desde, r.hasta, chofer || null);
        el.querySelector("#vtSub").textContent = r.desde === r.hasta ? `Caja del ${fmtDia(r.desde)}` : `${r.txt}: del ${fmtCorto(r.desde)} al ${fmtCorto(r.hasta)}`;
        pintarCaja();
      } else {
        const f = diaChofer === "ayer" ? ayerIso() : hoyIso();
        planilla = await A().misVentas(f);
        el.querySelector("#vtSub").textContent = (diaChofer === "ayer" ? "Ayer, " : "Hoy, ") + fmtDia(f);
        pintarPlanilla();
      }
      cargado = true;
    } catch (e) {
      const caj = el.querySelector(esCaja ? "#vtCaja" : "#vtPlanilla");
      caj.innerHTML = `<div class="pn-vacio pn-card">No pudimos cargar las ventas. ${esc(A().msg(e))}</div>`;
    }
  }

  /* ---------- Lista de ventas (chofer y admin) ---------- */
  function filaVenta(v, conChofer) {
    const hoy = v.fecha === hoyIso();
    // Solo el admin tiene el atajo para escribirle al cliente; el chofer no envía nada
    const wa = esCaja && v.telefono && !v.anulada ? L.linkWhatsApp(v.telefono, `${L.saludo(v.nombre, v.trato)}. Le saluda Agua Purificada Befine.`) : null;
    const puedeAnular = !v.anulada && (esCaja || hoy);
    return `<li class="pn-card vt-venta${v.anulada ? " anulada" : ""}">
      <header><b>${clp(v.total)}</b>${medio(v.metodo_pago)}<span class="vt-hora">${esc(v.hora)} · N° ${esc(v.numero)}${conChofer ? ` · ${esc(v.chofer)}` : ""}</span>
        ${v.anulada ? `<span class="pn-est mal">Anulada</span>` : ""}</header>
      <p class="vt-items">${itemsTxt(v)}${v.descuento ? `<small class="vt-desc">Descuento ${clp(v.descuento)}</small>` : ""}</p>
      <p class="vt-dir">${ICONOS.mapa}<span>${esc(v.direccion)}${v.nombre ? ` · ${esc(L.TRATOS[v.trato] ? L.TRATOS[v.trato] + " " : "")}${esc(v.nombre)}` : ""}${v.nota ? `<small>${esc(v.nota)}</small>` : ""}</span></p>
      ${wa || puedeAnular ? `<div class="vt-acc">
        ${wa ? `<a class="pn-btn sm ghost" href="${esc(wa)}" target="_blank" rel="noopener">${ICONOS.whatsapp}<span>WhatsApp</span></a>` : ""}
        ${puedeAnular ? `<button class="pn-btn sm peligro" type="button" data-anular="${esc(v.id)}" data-num="${esc(v.numero)}">Anular</button>` : ""}
      </div>` : ""}
    </li>`;
  }

  function pintarPlanilla() {
    const ventas = planilla.ventas || [], r = L.resumenVentas(ventas), en = planilla.entregas || {};
    const efectivo = r.efectivo + (Number(en.efectivo) || 0);
    el.querySelector("#vtPlanilla").innerHTML = `
      <div class="pn-kpis vt-kpis">
        <div class="pn-kpi"><span>Vendido</span><b>${clp(r.total)}</b><small>${r.ventas} venta${r.ventas === 1 ? "" : "s"} · ${r.unidades} u.</small></div>
        <div class="pn-kpi ${efectivo ? "alerta" : ""}"><span>Efectivo a rendir</span><b>${clp(efectivo)}</b><small>incluye entregas de ruta</small></div>
      </div>
      <p class="vt-desglose">Transferencia <b>${clp(r.transferencia)}</b> · Tarjeta <b>${clp(r.tarjeta)}</b>${Number(en.cantidad) ? ` · Entregas de ruta: <b>${en.cantidad}</b> (${clp(en.total)})` : ""}</p>
      ${ventas.length ? `<ul class="vt-lista">${ventas.map((v) => filaVenta(v, false)).join("")}</ul>`
        : `<div class="pn-vacio pn-card">Aún no hay ventas anotadas${diaChofer === "ayer" ? " ayer" : " hoy"}. Toca <b>Anotar venta</b> después de cada entrega.</div>`}`;
  }

  function pintarCaja() {
    const t = caja.totales || {}, sel = el.querySelector("#vtChofer");
    // Lista de choferes (se conserva la elección)
    const ops = `<option value="">Todo el equipo</option>` + (caja.choferes || []).map((c) =>
      `<option value="${esc(c.id)}"${c.id === chofer ? " selected" : ""}>${esc(c.nombre || "Sin nombre")}</option>`).join("");
    if (sel.innerHTML !== ops) sel.innerHTML = ops;
    const kpi = (txt, val, sub, tono) => `<div class="pn-kpi ${tono || ""}"><span>${txt}</span><b>${val}</b>${sub ? `<small>${sub}</small>` : ""}</div>`;
    const variosDias = (caja.por_dia || []).length > 1 || caja.desde !== caja.hasta;
    const porChofer = caja.por_chofer || [];
    const ventas = caja.ventas || [];
    el.querySelector("#vtCaja").innerHTML = `
      <div class="pn-kpis vt-kpis-caja">
        ${kpi("Total vendido", clp(t.total), `${movs(t.movimientos)} · ${t.unidades || 0} u.`)}
        ${kpi("Efectivo a rendir", clp(t.efectivo), "lo que deben entregar los choferes", t.efectivo ? "alerta" : "")}
        ${kpi("Transferencia", clp(t.transferencia), "revisa tu banco")}
        ${kpi("Tarjeta", clp(t.tarjeta), "revisa tu máquina")}
        ${kpi("Mercado Pago", clp(t.mercado_pago), "pedidos web entregados")}
      </div>
      <p class="vt-desglose">Anotadas por choferes <b>${clp(t.ventas_chofer)}</b> (${t.n_ventas_chofer || 0}) · Pedidos web <b>${clp(t.pedidos_web)}</b> (${t.n_pedidos_web || 0}) · Fuera de la página <b>${clp(t.pedidos_fuera)}</b> (${t.n_pedidos_fuera || 0})</p>
      ${porChofer.length ? `<h2 class="vt-tit">Por chofer</h2>
      <div class="pn-card vt-tabla-wrap"><table class="pn-tabla vt-tabla"><thead><tr><th>Chofer</th><th class="num">Total</th><th class="num">Efectivo a rendir</th><th class="num">Transferencia</th><th class="num">Tarjeta</th><th class="num">Mercado Pago</th></tr></thead><tbody>
        ${porChofer.map((c) => `<tr><td><b>${esc(c.chofer)}</b><small>${movs(c.movimientos)} · ${c.unidades} u.</small></td>
          <td class="num" data-l="Total"><b>${clp(c.total)}</b></td><td class="num" data-l="Efectivo">${clp(c.efectivo)}</td>
          <td class="num" data-l="Transferencia">${clp(c.transferencia)}</td><td class="num" data-l="Tarjeta">${clp(c.tarjeta)}</td>
          <td class="num" data-l="Mercado Pago">${clp(c.mercado_pago)}</td></tr>`).join("")}
      </tbody></table></div>` : ""}
      ${variosDias && (caja.por_dia || []).length ? `<h2 class="vt-tit">Por día</h2>
      <div class="pn-card vt-tabla-wrap"><table class="pn-tabla vt-tabla"><thead><tr><th>Día</th><th class="num">Total</th><th class="num">Anotadas</th><th class="num">Pedidos</th><th class="num">Efectivo</th></tr></thead><tbody>
        ${caja.por_dia.map((d) => `<tr><td><b>${esc(fmtCorto(d.fecha))}</b><small>${movs(d.movimientos)} · ${d.unidades} u.</small></td>
          <td class="num" data-l="Total"><b>${clp(d.total)}</b></td><td class="num" data-l="Anotadas">${clp(d.ventas_chofer)}</td>
          <td class="num" data-l="Pedidos">${clp(d.pedidos)}</td><td class="num" data-l="Efectivo">${clp(d.efectivo)}</td></tr>`).join("")}
      </tbody></table></div>` : ""}
      <h2 class="vt-tit">Ventas anotadas <small>${ventas.length}</small></h2>
      ${ventas.length ? `<ul class="vt-lista">${ventas.map((v) => filaVenta(v, true)).join("")}</ul>`
        : `<div class="pn-vacio pn-card">No hay ventas anotadas en este periodo.</div>`}`;
  }

  function descargarCsv() {
    if (!caja || !(caja.ventas || []).length) return UI.toast("No hay ventas anotadas para descargar en este periodo.", "mal");
    const blob = new Blob([L.csvCaja(caja.ventas)], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `ventas_befine_${caja.desde}_${caja.hasta}.csv`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
  }

  async function anular(id, numero) {
    const ok = await UI.confirmar(`¿Anular la venta N° ${numero}?`,
      "Deja de contar en la caja y el stock vuelve al inventario. Queda registrada como anulada.", "Anular venta", true);
    if (!ok) return;
    const r = await A().anularVenta(id, esCaja ? "Anulada por el administrador" : "Anulada por el chofer");
    if (!r.ok) return UI.toast(r.error, "mal");
    UI.toast(`Venta N° ${numero} anulada.`);
    cargar();
  }

  /* ---------- Anotar venta (formulario rápido) ---------- */
  async function abrirAnotar(btn) {
    if (!opciones || Date.now() - opcionesAt > 10 * 60 * 1000) {
      try { opciones = await UI.conCarga(btn, () => A().opcionesPedidoManual()); opcionesAt = Date.now(); }
      catch (e) { return UI.toast(A().msg(e), "mal"); }
    }
    const prods = L.ordenarProductosVenta(opciones.productos || []);
    const chip = (name, v, t, sel) => `<label class="vt-chip"><input type="radio" name="${name}" value="${esc(v)}"${sel ? " checked" : ""}><span>${esc(t)}</span></label>`;
    UI.abrirModal(`<h2>Anotar venta</h2>
      <form class="vt-form" id="vtForm" novalidate autocomplete="off">
        <ul class="vt-prods" aria-label="Productos">${prods.map((p) => `
          <li data-v="${esc(p.variante_id)}">
            <span class="n">${esc(p.producto)}${p.variante ? ` <small>${esc(p.variante)}</small>` : ""}<small>${clp(p.precio)}</small></span>
            <span class="vt-cant">
              <button type="button" data-paso="-1" aria-label="Quitar uno de ${esc(p.producto)}">−</button>
              <output aria-live="polite">0</output>
              <button type="button" data-paso="1" aria-label="Agregar uno de ${esc(p.producto)}">+</button>
            </span>
          </li>`).join("") || "<li>No hay productos activos.</li>"}</ul>
        <span class="err" data-err="lineas"></span>
        <fieldset><legend>¿Cómo pagó?</legend>
          <div class="vt-chips">${L.METODOS_VENTA.map((m, i) => chip("pago", m, L.METODOS_PAGO[m], i === 0)).join("")}</div>
          <span class="err" data-err="pago"></span></fieldset>
        <label class="vt-campo">Celular <small>opcional</small>
          <span class="vt-tel"><span aria-hidden="true">+56 9</span><input class="pn-inp" name="telefono" inputmode="numeric" maxlength="9" placeholder="1234 5678" aria-label="Celular: 8 números después de +56 9"></span>
          <span class="err" data-err="telefono"></span><small class="vt-pista" id="vtPista" hidden></small></label>
        <label class="vt-campo">Dirección<input class="pn-inp" name="direccion" maxlength="160" placeholder="Calle y número, comuna"><span class="err" data-err="direccion"></span></label>
        <details class="vt-mas">
          <summary>Nombre, descuento o nota <small>opcional</small></summary>
          <fieldset><legend>Trato</legend><div class="vt-chips">${chip("trato", "", "—", true)}${Object.keys(L.TRATOS).map((k) => chip("trato", k, L.TRATOS[k], false)).join("")}</div></fieldset>
          <label class="vt-campo">Nombre<input class="pn-inp" name="nombre" maxlength="60" placeholder="Ej.: Juan"></label>
          <label class="vt-campo">Descuento en pesos<input class="pn-inp" name="descuento" type="number" min="0" step="100" inputmode="numeric" value="0"><span class="err" data-err="descuento"></span></label>
          <label class="vt-campo">Nota<input class="pn-inp" name="nota" maxlength="200" placeholder="Ej.: dejó 2 bidones vacíos"></label>
        </details>
        <div class="vt-pie">
          <p id="vtTotal" aria-live="polite"></p>
          <div class="pn-form-acc"><button type="button" class="pn-btn ghost" data-cancelar>Cancelar</button><button type="submit" class="pn-btn ok">Guardar venta</button></div>
        </div>
      </form>`);

    const f = document.getElementById("vtForm");
    const cant = {};
    const val = (n) => { const x = f.querySelector(`[name="${n}"]:checked`) || f.elements[n]; return x ? String(x.value || "").trim() : ""; };
    const calc = () => L.calcularVenta(cant, prods, val("descuento"));
    const totales = () => {
      const t = calc();
      f.querySelector("#vtTotal").innerHTML = t.unidades
        ? `<b>${clp(t.total)}</b><span>${t.unidades} u.${t.descuento ? ` · descuento ${clp(t.descuento)}` : ""}</span>`
        : `<span>Toca + en lo que vendiste</span>`;
    };
    const limpiar = (n) => { const e = f.querySelector(`[data-err="${n}"]`); if (e) e.textContent = ""; const i = f.querySelector(`.pn-inp[name="${n}"]`); if (i) i.classList.remove("mal"); };
    totales();

    f.querySelector("[data-cancelar]").addEventListener("click", UI.cerrarModal);
    f.addEventListener("click", (e) => {
      const b = e.target.closest("[data-paso]"); if (!b) return;
      const li = b.closest("li"), v = li.dataset.v;
      cant[v] = Math.max(0, Math.min(200, (cant[v] || 0) + Number(b.dataset.paso)));
      li.querySelector("output").textContent = cant[v];
      li.classList.toggle("con", cant[v] > 0);
      limpiar("lineas"); totales();
    });
    // Celular: solo números, se agrupa 1234 5678; al completar 8 dígitos se buscan sus datos
    let ultimo = "";
    f.elements.telefono.addEventListener("input", async (e) => {
      const d = L.celular8(e.target.value);
      e.target.value = d.length > 4 ? d.slice(0, 4) + " " + d.slice(4) : d;
      limpiar("telefono");
      const pista = f.querySelector("#vtPista");
      if (d.length !== 8 || d === ultimo) { if (d.length !== 8) pista.hidden = true; return; }
      ultimo = d;
      const c = await A().clienteReparto(d);
      if (!c || L.celular8(f.elements.telefono.value) !== d) return;
      if (!f.elements.direccion.value.trim()) { f.elements.direccion.value = c.direccion || ""; limpiar("direccion"); }
      if (c.nombre && !f.elements.nombre.value.trim()) f.elements.nombre.value = c.nombre;
      if (c.trato) { const r = f.querySelector(`[name="trato"][value="${c.trato}"]`); if (r) r.checked = true; }
      pista.textContent = `Cliente conocido: ${c.nombre ? (L.TRATOS[c.trato] ? L.TRATOS[c.trato] + " " : "") + c.nombre + " · " : ""}se completó su dirección.`;
      pista.hidden = false;
    });
    f.addEventListener("input", (e) => { if (e.target.name && e.target.name !== "telefono") limpiar(e.target.name); if (e.target.name === "descuento") totales(); });
    f.addEventListener("change", (e) => { if (e.target.name === "pago") limpiar("pago"); });

    f.addEventListener("submit", async (e) => {
      e.preventDefault();
      const t = calc();
      const d = { lineas: t.lineas, pago: val("pago"), direccion: val("direccion"), telefono: L.celular8(val("telefono")),
                  trato: val("trato"), nombre: val("nombre"), descuento: Number(val("descuento")) || 0, nota: val("nota"), subtotal: t.subtotal };
      const errs = L.validarVenta(d);
      f.querySelectorAll("[data-err]").forEach((s) => { s.textContent = errs[s.dataset.err] || ""; });
      f.querySelectorAll(".pn-inp[name]").forEach((i) => i.classList.toggle("mal", !!errs[i.name]));
      if (errs.descuento) f.querySelector(".vt-mas").open = true;
      if (Object.keys(errs).length) {
        const p = f.querySelector(".err:not(:empty)"); if (p) p.scrollIntoView({ block: "center", behavior: "smooth" });
        return;
      }
      const r = await UI.conCarga(f.querySelector('[type="submit"]'), () => A().registrarVenta(d));
      if (!r.ok) return UI.toast(r.error, "mal");
      sucio = true;
      UI.cerrarModal();
      UI.toast(`Venta N° ${r.numero} anotada · ${clp(r.total)} · ${L.METODOS_PAGO[r.metodo_pago] || r.metodo_pago}`);
      if (!el.hidden) cargar();
    });
  }

  window.AdminApp.SECCIONES.ventas = { montar, mostrar };
  window.AdminApp.Ventas = { abrirAnotar };
})();
