/* =====================================================================
   admin-reparto.js — Sección "Reparto" del panel (HU-16 + HU-17)
   ---------------------------------------------------------------------
   Pensada para el celular del chofer:
   - Pedidos PAGADOS de hoy (con los atrasados) o de mañana, agrupados por
     comuna y ordenados para salir a ruta. Los trae reparto_del_dia()
     (migración 02): el chofer no lee la tabla de pedidos.
   - "En camino" y "Entregado" cambian el estado en el servidor
     (marcar_reparto) y abren WhatsApp con el aviso al cliente, que arma
     el servidor. "Reenviar aviso" lo vuelve a abrir sin cambiar el estado.
   - La pestaña de WhatsApp se abre en el mismo clic (antes de esperar al
     servidor) para que el navegador del celular no la bloquee.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const { esc, ICONOS, UI } = window.AdminApp;
  const A = () => Befine.admin;

  let el, lista = [], dia = "hoy", cargado = false, timer = null;

  const badge = (e) => `<span class="ad-est ${(L.ESTADOS[e] || {}).tono || ""}">${esc(L.etiquetaEstado(e))}</span>`;
  const fechaDe = (d) => { const x = new Date(); if (d === "manana") x.setDate(x.getDate() + 1); return L.diaLocal(x); };
  const fmtDia = (iso) => new Date(iso + "T12:00:00").toLocaleDateString("es-CL", { weekday: "long", day: "numeric", month: "long" });

  function montar(seccion) {
    el = seccion;
    el.innerHTML = `
      <div class="ad-head">
        <div><h1>Reparto</h1><p id="rpSub">Pedidos pagados para entregar</p></div>
        <div class="acciones">
          <div class="ad-chips sm" role="tablist" aria-label="Día de reparto" id="rpDias">
            <button type="button" role="tab" data-dia="hoy" aria-selected="true">Hoy</button>
            <button type="button" role="tab" data-dia="manana" aria-selected="false">Mañana</button>
          </div>
          <button class="ad-btn ghost" type="button" id="rpRecargar" title="Actualizar">${ICONOS.recargar}<span>Actualizar</span></button>
        </div>
      </div>
      <div class="ad-kpis rp-kpis" id="rpKpis"></div>
      <div id="rpLista"><div class="ad-vacio"><span class="ad-spin"></span></div></div>`;

    el.querySelector("#rpDias").addEventListener("click", (e) => {
      const b = e.target.closest("[data-dia]"); if (!b || b.dataset.dia === dia) return;
      dia = b.dataset.dia;
      el.querySelectorAll("#rpDias [data-dia]").forEach((x) => x.setAttribute("aria-selected", String(x === b)));
      cargar();
    });
    el.querySelector("#rpRecargar").addEventListener("click", (e) => UI.conCarga(e.currentTarget, cargar));
    el.querySelector("#rpLista").addEventListener("click", (e) => {
      const b = e.target.closest("[data-rp]"); if (!b) return;
      if (b.dataset.rp === "avisar") reenviar(b); else marcar(b);
    });
  }

  async function mostrar() {
    if (!cargado) await cargar();
    clearInterval(timer);
    timer = setInterval(() => { if (!document.hidden && !el.hidden) cargar(true); }, 120000);
  }

  async function cargar(silencioso) {
    const f = fechaDe(dia);
    el.querySelector("#rpSub").textContent = `Pedidos pagados para el ${fmtDia(f)}${dia === "hoy" ? " (incluye atrasados)" : ""}`;
    try {
      lista = await A().reparto(f);
      cargado = true;
      pintar();
    } catch (e) {
      if (!silencioso) {
        el.querySelector("#rpLista").innerHTML = `<div class="ad-vacio ad-card">No pudimos cargar el reparto. ${esc(A().msg(e))}</div>`;
        UI.toast(A().msg(e), "mal");
      }
    }
  }

  function pintar() {
    const r = L.resumenReparto(lista);
    const kpi = (txt, val, tono) => `<div class="ad-kpi ${tono || ""}"><span>${txt}</span><b>${val}</b></div>`;
    el.querySelector("#rpKpis").innerHTML =
      kpi("Por salir", r.porSalir, r.porSalir ? "alerta" : "") + kpi("En camino", r.enRuta) +
      kpi("Entregados", r.entregados) + (r.atrasados ? kpi("Atrasados", r.atrasados, "alerta") : "");
    const cnt = document.getElementById("cnt-reparto");
    if (cnt) { cnt.textContent = r.porSalir + r.enRuta; cnt.hidden = !(r.porSalir + r.enRuta); }

    const box = el.querySelector("#rpLista");
    if (!lista.length) { box.innerHTML = `<div class="ad-vacio ad-card">No hay pedidos pagados para entregar ${dia === "hoy" ? "hoy" : "mañana"}.</div>`; return; }
    box.innerHTML = L.agruparPorComuna(lista).map((g) => `
      <section class="rp-grupo">
        <h2>${esc(g.comuna)} <span>${g.pedidos.length}</span></h2>
        ${g.pedidos.map(tarjeta).join("")}
      </section>`).join("");
  }

  function tarjeta(p) {
    const paso = L.accionReparto(p.estado);
    const maps = L.linkMaps(p), tel = L.telLink(p.telefono);
    const items = (p.items || []).map((i) => `<li><b>${esc(i.cantidad)} ×</b> ${esc(i.producto)}${i.variante ? ` <small>(${esc(i.variante)})</small>` : ""}</li>`).join("");
    return `
      <article class="ad-card rp-ped ${p.estado}${p.atrasado ? " atrasado" : ""}">
        <header>
          <b>#${esc(p.numero_pedido)}</b> ${badge(p.estado)}
          ${p.atrasado ? `<span class="ad-est mal">Atrasado · ${esc(p.fecha_entrega)}</span>` : ""}
          ${p.es_canje ? `<span class="ad-est info">Premio Club</span>` : ""}
        </header>
        <p class="rp-nom">${esc(p.nombre || "Cliente")}</p>
        <p class="rp-dir">${esc(p.calle || "")} ${esc(p.numero || "")}${p.depto ? ", depto " + esc(p.depto) : ""}, ${esc(p.comuna || "")}</p>
        ${p.referencia ? `<p class="rp-ref">Referencia: ${esc(p.referencia)}</p>` : ""}
        ${p.notas ? `<p class="rp-ref">Nota: ${esc(p.notas)}</p>` : ""}
        <ul class="rp-items">${items}</ul>
        <div class="rp-bot">
          ${maps ? `<a class="ad-btn sm ghost" href="${esc(maps)}" target="_blank" rel="noopener">${ICONOS.mapa}Mapa</a>` : ""}
          ${tel ? `<a class="ad-btn sm ghost" href="${esc(tel)}">${ICONOS.telefono}Llamar</a>` : ""}
          ${p.estado !== "en_preparacion" ? `<button type="button" class="ad-btn sm ghost" data-rp="avisar" data-id="${esc(p.id)}">${ICONOS.whatsapp}Reenviar aviso</button>` : ""}
          ${paso ? `<button type="button" class="ad-btn ${paso.estado === "entregado" ? "ok" : ""} rp-paso" data-rp="marcar"
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

  async function marcar(b) {
    const { id, num, estado } = b.dataset;
    if (estado === "entregado") {
      const ok = await UI.confirmar(`¿Pedido #${num} entregado?`, "Se cierra el pedido y se abre WhatsApp con el aviso de entrega para el cliente.", "Sí, entregado");
      if (!ok) return;
    }
    const w = abrirPestana();
    const r = await UI.conCarga(b, () => A().marcarReparto(id, estado));
    if (!r.ok) { if (w) w.close(); UI.toast(r.error, "mal"); return cargar(true); }
    irAWhatsApp(w, r);
    UI.toast(estado === "en_ruta" ? `Pedido #${num} en camino.` : `Pedido #${num} entregado.`);
    cargar(true);
  }

  async function reenviar(b) {
    const w = abrirPestana();
    const r = await UI.conCarga(b, () => A().avisoReparto(b.dataset.id));
    if (!r.ok) { if (w) w.close(); UI.toast(r.error, "mal"); return; }
    irAWhatsApp(w, r);
  }

  window.AdminApp.SECCIONES.reparto = { montar, mostrar };
})();
