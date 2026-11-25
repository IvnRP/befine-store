/* =====================================================================
   admin-reparto.js — Sección "Reparto" del panel (HU-16 + HU-17 + pedidos fuera de la página)
   ---------------------------------------------------------------------
   Pensada para el celular del chofer:
   - Pedidos PAGADOS de hoy (con los atrasados), de mañana o del día que se elija, agrupados por
     comuna y ordenados para salir a ruta. Los trae reparto_del_dia() (migración 02): el chofer no
     lee la tabla de pedidos.
   - "En camino" y "Entregado" cambian el estado en el servidor (marcar_reparto) y abren WhatsApp
     con el aviso al cliente, que arma el servidor. "Reenviar aviso" lo vuelve a abrir sin cambiar
     el estado.
   - La pestaña de WhatsApp se abre en el mismo clic (antes de esperar al servidor) para que el
     navegador del celular no la bloquee.
   - Migración 21: "Pedido fuera de la página" (WhatsApp, llamada, presencial) con productos del
     catálogo, cobro en efectivo, tarjeta o transferencia (ya pagado o por cobrar al entregar),
     registro del cobro al entregar y resumen de lo entregado en el día (efectivo a rendir).
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const { esc, ICONOS, UI } = window.AdminApp;
  const A = () => Befine.admin;
  const clp = (n) => Befine.clp(n || 0);

  let el, app, lista = [], dia = "hoy", diaOtro = "", ver = "todos", cargado = false, timer = null, opciones = null;

  const badge = (e) => `<span class="pn-est ${(L.ESTADOS[e] || {}).tono || ""}">${esc(L.etiquetaEstado(e))}</span>`;
  const fechaDe = (d) => {
    if (d === "otro" && /^\d{4}-\d{2}-\d{2}$/.test(diaOtro)) return diaOtro;
    const x = new Date(); if (d === "manana") x.setDate(x.getDate() + 1); return L.diaLocal(x);
  };
  const fmtDia = (iso) => new Date(iso + "T12:00:00").toLocaleDateString("es-CL", { weekday: "long", day: "numeric", month: "long" });
  const hoyIso = () => L.diaLocal(new Date());
  /* Qué pedidos muestra cada filtro (los de las tarjetas usan las mismas reglas que sus contadores) */
  const VER_KPI = { por_salir: "Por salir", en_ruta: "En camino", atrasados: "Atrasados" };
  function verPedido(p, v) {
    switch (v) {
      case "entregados": return p.estado === "entregado";
      case "pendientes": return p.estado !== "entregado";
      case "por_salir": return p.estado === "en_preparacion";
      case "en_ruta": return p.estado === "en_ruta";
      case "atrasados": return !!p.atrasado && p.estado !== "entregado";
      default: return true;
    }
  }

  function montar(seccion, appCtx) {
    el = seccion; app = appCtx;
    const registra = app && app.puede("pedidos.registrar");
    el.innerHTML = `
      <div class="pn-head">
        <div><h1>Reparto</h1><p id="rpSub">Pedidos para entregar</p></div>
        <div class="acciones">
          ${registra ? `<button class="pn-btn" type="button" id="rpNuevo">${ICONOS.mas}<span>Pedido fuera de la página</span></button>` : ""}
          <button class="pn-btn ghost" type="button" id="rpRecargar" title="Actualizar">${ICONOS.recargar}<span>Actualizar</span></button>
        </div>
      </div>
      <div class="rp-filtros">
        <div class="pn-chips sm" role="tablist" aria-label="Día de reparto" id="rpDias">
          <button type="button" role="tab" data-dia="hoy" aria-selected="true">Hoy</button>
          <button type="button" role="tab" data-dia="manana" aria-selected="false">Mañana</button>
          <button type="button" role="tab" data-dia="otro" aria-selected="false">Otro día</button>
        </div>
        <input class="pn-inp rp-otro" type="date" id="rpOtro" aria-label="Elegir día de reparto" hidden>
        <div class="pn-chips sm" role="tablist" aria-label="Qué mostrar" id="rpVer"></div>
      </div>
      <div class="pn-kpis rp-kpis" id="rpKpis"></div>
      <div id="rpResumen"></div>
      <div id="rpLista"><div class="pn-vacio"><span class="pn-spin"></span></div></div>`;

    el.querySelector("#rpDias").addEventListener("click", (e) => {
      const b = e.target.closest("[data-dia]"); if (!b) return;
      const otro = el.querySelector("#rpOtro");
      otro.hidden = b.dataset.dia !== "otro";
      if (b.dataset.dia === "otro" && !diaOtro) { otro.value = hoyIso(); otro.focus(); }
      if (b.dataset.dia === dia && dia !== "otro") return;
      dia = b.dataset.dia;
      el.querySelectorAll("#rpDias [data-dia]").forEach((x) => x.setAttribute("aria-selected", String(x === b)));
      if (dia !== "otro" || diaOtro) cargar();
    });
    el.querySelector("#rpOtro").addEventListener("change", (e) => { diaOtro = e.target.value; if (dia === "otro" && diaOtro) cargar(); });
    el.querySelector("#rpVer").addEventListener("click", (e) => {
      const b = e.target.closest("[data-ver]"); if (!b) return;
      ver = b.dataset.ver;
      pintar();
    });
    // Tarjetas clicables: muestran esos pedidos (otro toque vuelve a "Todos")
    el.querySelector("#rpKpis").addEventListener("click", (e) => {
      const b = e.target.closest("[data-kpi-ver]"); if (!b) return;
      ver = ver === b.dataset.kpiVer ? "todos" : b.dataset.kpiVer;
      pintar();
      if (ver !== "todos") el.querySelector("#rpLista").scrollIntoView({ behavior: "smooth", block: "start" });
    });
    el.querySelector("#rpRecargar").addEventListener("click", (e) => UI.conCarga(e.currentTarget, cargar));
    const nuevo = el.querySelector("#rpNuevo");
    if (nuevo) nuevo.addEventListener("click", (e) => abrirFormulario(e.currentTarget));
    el.querySelector("#rpLista").addEventListener("click", (e) => {
      const b = e.target.closest("[data-rp]"); if (!b) return;
      if (b.dataset.rp === "avisar") reenviar(b);
      else if (b.dataset.rp === "cobrar") cobrar(b);
      else marcar(b);
    });
  }

  async function mostrar() {
    if (!cargado) await cargar();
    clearInterval(timer);
    timer = setInterval(() => { if (!document.hidden && !el.hidden) cargar(true); }, 120000);
  }

  async function cargar(silencioso) {
    const f = fechaDe(dia);
    el.querySelector("#rpSub").textContent = `Pedidos para el ${fmtDia(f)}${f === hoyIso() ? " (incluye atrasados)" : ""}`;
    try {
      lista = await A().reparto(f);
      cargado = true;
      pintar();
    } catch (e) {
      if (!silencioso) {
        el.querySelector("#rpLista").innerHTML = `<div class="pn-vacio pn-card">No pudimos cargar el reparto. ${esc(A().msg(e))}</div>`;
        UI.toast(A().msg(e), "mal");
      }
    }
  }

  function pintar() {
    const r = L.resumenReparto(lista);
    const kpi = (v, txt, val, tono) =>
      `<button type="button" class="pn-kpi ${tono || ""}" data-kpi-ver="${v}" aria-pressed="${ver === v}" title="Ver estos pedidos"><span>${txt}</span><b>${val}</b></button>`;
    el.querySelector("#rpKpis").innerHTML =
      kpi("por_salir", "Por salir", r.porSalir, r.porSalir ? "alerta" : "") + kpi("en_ruta", "En camino", r.enRuta) +
      kpi("entregados", "Entregados", r.entregados) + (r.atrasados ? kpi("atrasados", "Atrasados", r.atrasados, "alerta") : "");
    const chips = [["todos", "Todos"], ["pendientes", "Por entregar"], ["entregados", "Entregados"]];
    if (VER_KPI[ver]) chips.unshift([ver, VER_KPI[ver]]);   // abierto desde una tarjeta
    el.querySelector("#rpVer").innerHTML = chips.map(([k, t]) =>
      `<button type="button" role="tab" data-ver="${k}" aria-selected="${ver === k}">${esc(t)}</button>`).join("");
    const cnt = document.getElementById("cnt-reparto");
    if (cnt && fechaDe(dia) === hoyIso()) { cnt.textContent = r.porSalir + r.enRuta; cnt.hidden = !(r.porSalir + r.enRuta); }

    el.querySelector("#rpResumen").innerHTML = htmlResumen(L.resumenEntregas(lista));

    const visibles = lista.filter((p) => verPedido(p, ver));
    const box = el.querySelector("#rpLista");
    if (!visibles.length) {
      const que = { entregados: "entregados", pendientes: "por entregar", por_salir: "por salir", en_ruta: "en camino", atrasados: "atrasados" }[ver] || "para entregar";
      box.innerHTML = `<div class="pn-vacio pn-card">No hay pedidos ${que} el ${esc(fmtDia(fechaDe(dia)))}.</div>`;
      return;
    }
    box.innerHTML = L.agruparPorComuna(visibles).map((g) => `
      <section class="rp-grupo">
        <h2>${esc(g.comuna)} <span>${g.pedidos.length}</span></h2>
        ${g.pedidos.map(tarjeta).join("")}
      </section>`).join("");
  }

  /* Resumen de lo entregado: total, por medio de pago, efectivo a rendir y lo que quedó por cobrar */
  function htmlResumen(s) {
    if (!s.entregados) return "";
    const fila = (k, v, cls) => `<div class="${cls || ""}"><dt>${k}</dt><dd>${v}</dd></div>`;
    return `
      <section class="pn-card rp-resumen" aria-label="Resumen de lo entregado">
        <h2>Entregados: ${s.entregados} pedido${s.entregados === 1 ? "" : "s"} · ${clp(s.monto)}</h2>
        <dl>
          ${s.porMetodo.mercado_pago ? fila("Mercado Pago (página web)", clp(s.porMetodo.mercado_pago)) : ""}
          ${s.porMetodo.efectivo ? fila("Efectivo", clp(s.porMetodo.efectivo)) : ""}
          ${s.porMetodo.tarjeta ? fila("Tarjeta", clp(s.porMetodo.tarjeta)) : ""}
          ${s.porMetodo.transferencia ? fila("Transferencia", clp(s.porMetodo.transferencia)) : ""}
          ${s.porCobrar.cantidad ? fila(`Por cobrar (${s.porCobrar.cantidad})`, clp(s.porCobrar.monto), "alerta") : ""}
          ${fila("Efectivo a rendir", clp(s.efectivoARendir), "t")}
        </dl>
        ${s.fueraPagina ? `<p class="pn-nota">Fuera de la página: ${s.fueraPagina} de ${s.entregados}.</p>` : ""}
      </section>`;
  }

  function tarjeta(p) {
    const paso = L.accionReparto(p.estado);
    const maps = L.linkMaps(p), tel = L.telLink(p.telefono);
    const fuera = L.esFueraPagina(p), porCobrar = fuera && p.cobro_estado === "por_cobrar";
    const items = (p.items || []).map((i) => `<li><b>${esc(i.cantidad)} ×</b> ${esc(i.producto)}${i.variante ? ` <small>(${esc(i.variante)})</small>` : ""}</li>`).join("");
    return `
      <article class="pn-card rp-ped ${p.estado}${p.atrasado ? " atrasado" : ""}${porCobrar ? " por-cobrar" : ""}">
        <header>
          <b>#${esc(p.numero_pedido)}</b> ${badge(p.estado)}
          ${p.atrasado && p.estado !== "entregado" ? `<span class="pn-est mal">Atrasado · ${esc(p.fecha_entrega)}</span>` : ""}
          ${p.es_canje ? `<span class="pn-est info">Premio Club</span>` : ""}
          ${fuera ? `<span class="pn-est rp-canal">${esc(L.etiquetaCanal(p.canal))}</span>` : ""}
        </header>
        <p class="rp-nom">${esc(p.nombre || "Cliente")}</p>
        <p class="rp-dir">${esc(p.calle || "")} ${esc(p.numero || "")}${p.depto ? ", depto " + esc(p.depto) : ""}, ${esc(p.comuna || "")}</p>
        ${p.referencia ? `<p class="rp-ref">Referencia: ${esc(p.referencia)}</p>` : ""}
        ${p.notas ? `<p class="rp-ref">Nota: ${esc(p.notas)}</p>` : ""}
        <ul class="rp-items">${items}</ul>
        ${fuera ? `<p class="rp-cobro ${porCobrar ? "por" : "ok"}">${porCobrar ? "Cobrar" : "Pagado"} <b>${clp(p.total)}</b> · ${esc((L.METODOS_PAGO[p.metodo_pago] || "").toLowerCase())}</p>` : ""}
        <div class="rp-bot">
          ${maps ? `<a class="pn-btn sm ghost" href="${esc(maps)}" target="_blank" rel="noopener">${ICONOS.mapa}Mapa</a>` : ""}
          ${tel ? `<a class="pn-btn sm ghost" href="${esc(tel)}">${ICONOS.telefono}Llamar</a>` : ""}
          ${p.estado !== "en_preparacion" ? `<button type="button" class="pn-btn sm ghost" data-rp="avisar" data-id="${esc(p.id)}">${ICONOS.whatsapp}Reenviar aviso</button>` : ""}
          ${porCobrar && p.estado === "entregado" ? `<button type="button" class="pn-btn sm" data-rp="cobrar" data-id="${esc(p.id)}">Registrar cobro</button>` : ""}
          ${paso ? `<button type="button" class="pn-btn ${paso.estado === "entregado" ? "ok" : ""} rp-paso" data-rp="marcar"
               data-id="${esc(p.id)}" data-num="${esc(p.numero_pedido)}" data-estado="${paso.estado}">${esc(paso.txt)}</button>` : ""}
        </div>
      </article>`;
  }

  /* Abre la pestaña de WhatsApp YA (gesto del usuario) y la apunta al enlace cuando el servidor responde */
  function abrirPestana() {
    try { const w = window.open("", "_blank"); if (w) w.opener = null; return w; } catch (e) { return null; }
  }
  function irAWhatsApp(w, r) {
    const url = L.linkWhatsApp(r.telefono, r.mensaje);
    if (!url) { if (w) w.close(); UI.toast("El cliente no tiene un celular válido para WhatsApp. Llámalo o avísale por otro medio.", "mal"); return; }
    if (w) w.location.href = url; else window.location.href = url;   // si el navegador bloqueó la pestaña, se abre aquí
  }

  /* Pedido por cobrar: antes de "Entregado" se pregunta si se cobró → { seguir, metodo|null } */
  function preguntarCobro(p) {
    return new Promise((ok) => {
      const ops = L.METODOS_MANUALES.map((m) => `<label class="rp-op"><input type="radio" name="metodo" value="${m}"${m === p.metodo_pago ? " checked" : ""}> ${esc(L.METODOS_PAGO[m])}</label>`).join("");
      UI.abrirModal(`<h2>Pedido #${esc(p.numero_pedido)}: ¿cobraste ${clp(p.total)}?</h2>
        <p class="pn-nota">Estaba por cobrar en ${esc((L.METODOS_PAGO[p.metodo_pago] || "").toLowerCase())}. Si pagó con otro medio, cámbialo.</p>
        <div class="rp-ops" role="radiogroup" aria-label="Medio de pago">${ops}</div>
        <div class="pn-form-acc rp-cobro-acc">
          <button class="pn-btn ghost" type="button" data-r="volver">Volver</button>
          <button class="pn-btn ghost" type="button" data-r="sin">Entregar sin cobrar</button>
          <button class="pn-btn ok" type="button" data-r="si">Sí, cobré y entregué</button>
        </div>`);
      const box = document.getElementById("pnModalIn");
      box.addEventListener("click", function h(e) {
        const b = e.target.closest("[data-r]"); if (!b) return;
        box.removeEventListener("click", h);
        const m = (box.querySelector('input[name="metodo"]:checked') || {}).value || p.metodo_pago;
        UI.cerrarModal();
        ok(b.dataset.r === "volver" ? { seguir: false } : { seguir: true, metodo: b.dataset.r === "si" ? m : null });
      });
    });
  }

  async function marcar(b) {
    const { id, num, estado } = b.dataset;
    const p = lista.find((x) => x.id === id) || {};
    let metodo = null;
    if (estado === "entregado") {
      if (L.esFueraPagina(p) && p.cobro_estado === "por_cobrar") {
        const r = await preguntarCobro(p);
        if (!r.seguir) return;
        metodo = r.metodo;
      } else {
        const ok = await UI.confirmar(`¿Pedido #${num} entregado?`, "Se cierra el pedido y se abre WhatsApp con el aviso de entrega para el cliente.", "Sí, entregado");
        if (!ok) return;
      }
    }
    const w = abrirPestana();
    const r = await UI.conCarga(b, async () => {
      if (metodo) {   // primero el cobro: así el aviso de entrega dice "Total pagado"
        const c = await A().cobrarPedido(id, metodo);
        if (!c.ok) return c;
      }
      return A().marcarReparto(id, estado);
    });
    if (!r.ok) { if (w) w.close(); UI.toast(r.error, "mal"); return cargar(true); }
    irAWhatsApp(w, r);
    UI.toast(estado === "en_ruta" ? `Pedido #${num} en camino.` : `Pedido #${num} entregado${metodo ? " y cobrado" : ""}.`);
    cargar(true);
  }

  async function cobrar(b) {
    const p = lista.find((x) => x.id === b.dataset.id); if (!p) return;
    const r = await preguntarCobro({ ...p });
    if (!r.seguir || !r.metodo) return;
    const c = await UI.conCarga(b, () => A().cobrarPedido(p.id, r.metodo));
    if (!c.ok) return UI.toast(c.error, "mal");
    UI.toast(`Cobro del pedido #${p.numero_pedido} registrado.`);
    cargar(true);
  }

  async function reenviar(b) {
    const w = abrirPestana();
    const r = await UI.conCarga(b, () => A().avisoReparto(b.dataset.id));
    if (!r.ok) { if (w) w.close(); UI.toast(r.error, "mal"); return; }
    irAWhatsApp(w, r);
  }

  /* ================= Formulario "Pedido fuera de la página" (migración 21) ================= */
  async function abrirFormulario(btn) {
    if (!opciones) {
      try { opciones = await UI.conCarga(btn, () => A().opcionesPedidoManual()); }
      catch (e) { return UI.toast(A().msg(e), "mal"); }
    }
    const hoy = hoyIso(), manana = L.diaLocal(new Date(Date.now() + 864e5));
    const fechaIni = fechaDe(dia) >= hoy ? fechaDe(dia) : hoy;
    const radios = (name, ops, sel) => ops.map(([v, t]) =>
      `<label class="rp-op"><input type="radio" name="${name}" value="${v}"${v === sel ? " checked" : ""}> ${esc(t)}</label>`).join("");
    const prods = (opciones.productos || []).map((p) => `
      <li data-v="${esc(p.variante_id)}">
        <span class="n">${esc(p.producto)}${p.variante ? ` <small>${esc(p.variante)}</small>` : ""}<small>${clp(p.precio)} c/u</small></span>
        <span class="pm-cant">
          <button type="button" class="pn-btn sm ghost" data-paso="-1" aria-label="Quitar uno">−</button>
          <input class="pn-inp" type="number" min="0" max="200" step="1" inputmode="numeric" value="0" aria-label="Cantidad de ${esc(p.producto)}">
          <button type="button" class="pn-btn sm ghost" data-paso="1" aria-label="Agregar uno">+</button>
        </span>
      </li>`).join("");
    UI.abrirModal(`<h2>Pedido fuera de la página</h2>
      <form class="pn-form pm-form" id="pmForm" novalidate>
        <fieldset class="full"><legend>¿Cómo llegó?</legend>
          <div class="rp-ops">${radios("canal", L.CANALES_MANUALES.map((c) => [c, L.CANALES[c]]), "whatsapp")}</div>
          <span class="err" data-err="canal"></span></fieldset>
        <label>Nombre del cliente<input class="pn-inp" name="nombre" maxlength="80" autocomplete="off"><span class="err" data-err="nombre"></span></label>
        <label>Celular<input class="pn-inp" name="telefono" inputmode="tel" placeholder="9 1234 5678" autocomplete="off"><span class="err" data-err="telefono"></span></label>
        <label class="full">Correo <small>opcional: para enviarle la boleta</small><input class="pn-inp" name="email" type="email" inputmode="email" autocomplete="off"><span class="err" data-err="email"></span></label>
        <label>Comuna<select class="pn-inp" name="comuna"><option value="">Elige…</option>${(opciones.comunas || []).map((c) => `<option>${esc(c.comuna)}</option>`).join("")}</select><span class="err" data-err="comuna"></span></label>
        <label>Calle<input class="pn-inp" name="calle" maxlength="120" autocomplete="off"><span class="err" data-err="calle"></span></label>
        <label>Número<input class="pn-inp" name="numero" maxlength="20" autocomplete="off"></label>
        <label>Depto / casa<input class="pn-inp" name="depto" maxlength="40" autocomplete="off"></label>
        <label class="full">Referencia<input class="pn-inp" name="referencia" maxlength="200" autocomplete="off" placeholder="Ej.: portón verde"></label>
        <label>Fecha de entrega<input class="pn-inp" name="fecha" type="date" min="${hoy}" value="${esc(fechaIni)}"><span class="err" data-err="fecha"></span></label>
        <div class="pm-atajos"><button type="button" class="pn-btn sm ghost" data-fecha="${hoy}">Hoy</button><button type="button" class="pn-btn sm ghost" data-fecha="${manana}">Mañana</button></div>
        <fieldset class="full"><legend>Productos</legend><ul class="pm-prods">${prods || "<li>No hay productos activos.</li>"}</ul><span class="err" data-err="lineas"></span></fieldset>
        <fieldset class="full"><legend>Pago</legend>
          <div class="rp-ops">${radios("metodo", L.METODOS_MANUALES.map((m) => [m, L.METODOS_PAGO[m]]), "efectivo")}</div>
          <div class="rp-ops">${radios("cobro", [["por_cobrar", "Se cobra al entregar"], ["pagado", "Ya pagó"]], "por_cobrar")}</div>
          <span class="err" data-err="metodo"></span><span class="err" data-err="cobro"></span></fieldset>
        <label>Descuento <small>opcional, en pesos</small><input class="pn-inp" name="descuento" type="number" min="0" step="1" inputmode="numeric" value="0"><span class="err" data-err="descuento"></span></label>
        <label>Motivo del descuento<input class="pn-inp" name="motivo" maxlength="200" autocomplete="off" placeholder="Ej.: cliente antiguo"><span class="err" data-err="motivo"></span></label>
        <fieldset class="full"><legend>Documento</legend>
          <div class="rp-ops">${radios("documento", [["boleta", "Boleta"], ["factura", "Factura"]], "boleta")}</div></fieldset>
        <div class="full pm-factura" hidden>
          <label>RUT<input class="pn-inp" name="rut" placeholder="76.123.456-7" autocomplete="off"><span class="err" data-err="rut"></span></label>
          <label>Razón social<input class="pn-inp" name="razon_social" maxlength="120" autocomplete="off"><span class="err" data-err="razon_social"></span></label>
          <label>Giro<input class="pn-inp" name="giro" maxlength="120" autocomplete="off"><span class="err" data-err="giro"></span></label>
        </div>
        <label class="full">Nota para el reparto <small>opcional</small><input class="pn-inp" name="notas" maxlength="500" autocomplete="off"></label>
        <dl class="pn-tot full" id="pmTot"></dl>
        <div class="pn-form-acc"><button type="button" class="pn-btn ghost" data-cancelar>Cancelar</button><button type="submit" class="pn-btn ok">Registrar pedido</button></div>
      </form>`);

    const f = document.getElementById("pmForm");
    const val = (n) => { const x = f.querySelector(`[name="${n}"]:checked`) || f.elements[n]; return x ? String(x.value || "").trim() : ""; };
    const lineas = () => [...f.querySelectorAll(".pm-prods [data-v]")].map((li) => ({ variante_id: li.dataset.v, cantidad: Number(li.querySelector("input").value) || 0 }));
    const datos = () => ({
      canal: val("canal"), nombre: val("nombre"), telefono: val("telefono"), email: val("email"),
      comuna: val("comuna"), calle: val("calle"), numero: val("numero"), depto: val("depto"), referencia: val("referencia"),
      fecha: val("fecha"), lineas: lineas(), metodo: val("metodo"), cobro: val("cobro"),
      descuento: val("descuento") === "" ? 0 : Number(val("descuento")), motivo: val("motivo"),
      documento: val("documento"), rut: val("rut"), razon_social: val("razon_social"), giro: val("giro"), notas: val("notas"),
    });
    const totales = () => {
      const d = datos(), t = L.calcularPedidoManual(d.lineas, opciones, d.comuna, d.descuento);
      f.querySelector("#pmTot").innerHTML = `
        <div><dt>Subtotal (${t.unidades} u.)</dt><dd>${clp(t.subtotal)}</dd></div>
        <div><dt>Despacho</dt><dd>${!t.conComuna ? "Elige la comuna" : t.despacho ? clp(t.despacho) : "Gratis"}</dd></div>
        ${t.descuento ? `<div><dt>Descuento</dt><dd>−${clp(t.descuento)}</dd></div>` : ""}
        <div class="t"><dt>Total ${d.cobro === "pagado" ? "pagado" : "a cobrar"}</dt><dd>${clp(t.total)}</dd></div>`;
    };
    totales();

    f.querySelector("[data-cancelar]").addEventListener("click", UI.cerrarModal);
    f.addEventListener("click", (e) => {
      const paso = e.target.closest("[data-paso]");
      if (paso) {
        const inp = paso.closest("li").querySelector("input");
        inp.value = Math.min(200, Math.max(0, (Number(inp.value) || 0) + Number(paso.dataset.paso)));
        limpiarError("lineas");
        return totales();
      }
      const fe = e.target.closest("[data-fecha]");
      if (fe) { f.elements.fecha.value = fe.dataset.fecha; }
    });
    // Al corregir un campo se borra su aviso de error
    const limpiarError = (n) => {
      const e = f.querySelector(`[data-err="${n}"]`); if (e) e.textContent = "";
      const i = f.querySelector(`.pn-inp[name="${n}"]`); if (i) i.classList.remove("mal");
    };
    f.addEventListener("input", (e) => { limpiarError(e.target.closest(".pm-prods") ? "lineas" : e.target.name); totales(); });
    f.addEventListener("change", (e) => {
      limpiarError(e.target.name);
      if (e.target.name === "documento") f.querySelector(".pm-factura").hidden = e.target.value !== "factura";
      totales();
    });
    f.addEventListener("submit", async (e) => {
      e.preventDefault();
      const d = datos();
      const errs = L.validarPedidoManual(d, opciones);
      f.querySelectorAll("[data-err]").forEach((s) => { s.textContent = errs[s.dataset.err] || ""; });
      f.querySelectorAll(".pn-inp[name]").forEach((i) => i.classList.toggle("mal", !!errs[i.name]));
      if (Object.keys(errs).length) {
        const primero = f.querySelector(".err:not(:empty)");
        if (primero) primero.scrollIntoView({ block: "center", behavior: "smooth" });
        return UI.toast("Revisa los datos marcados.", "mal");
      }
      const r = await UI.conCarga(f.querySelector('[type="submit"]'), () => A().registrarPedidoManual(d));
      if (!r.ok) return UI.toast(r.error, "mal");
      UI.cerrarModal();
      UI.toast(`Pedido #${r.numero} registrado para el ${fmtDia(r.fecha_entrega)} · ${clp(r.total)}${r.sobreventa ? " · revisa el stock" : ""}.`);
      // Se muestra el día del pedido recién registrado
      const f2 = String(r.fecha_entrega || "");
      if (f2 === hoyIso()) dia = "hoy";
      else if (f2 === L.diaLocal(new Date(Date.now() + 864e5))) dia = "manana";
      else { dia = "otro"; diaOtro = f2; el.querySelector("#rpOtro").value = f2; }
      el.querySelector("#rpOtro").hidden = dia !== "otro";
      el.querySelectorAll("#rpDias [data-dia]").forEach((x) => x.setAttribute("aria-selected", String(x.dataset.dia === dia)));
      opciones = null;   // precios y comunas frescos la próxima vez
      cargar(true);
    });
  }

  window.AdminApp.SECCIONES.reparto = { montar, mostrar };
})();
