/* =====================================================================
   producto.js — Ficha de producto (producto.html?id=prod-XX)
   Lee el id de la URL, muestra el producto, permite elegir variante y
   cantidad, y agrega al carrito.
   ===================================================================== */
(function () {
  document.addEventListener("DOMContentLoaded", async () => {
    const id = new URLSearchParams(location.search).get("id");
    const cont = document.getElementById("ficha");
    const p = id ? await Befine.getProducto(id) : null;

    if (!p) { cont.innerHTML = `<p class="empty-state">Producto no encontrado. <a href="catalogo.html">Volver al catálogo</a>.</p>`; return; }

    const grad = window.catGrad(p.categoria_slug);
    // Sin stock no se deja de vender: se informa antes de comprar y se aplaza la entrega (HU v2.4)
    // Club Befine: solo las recargas con envase Befine suman puntos
    const R = Befine.club.reglas;
    const clubHTML = `<b>★ Suma puntos Club Befine</b> · 1 punto por cada ${Befine.clp(R.clpPorPunto)} · ${R.bonoMin} o más recargas: +${R.bonoPuntos} de bono. <a href="terminos.html#puntos">Ver premios</a>`;
    const stockHTML = (v) => v.a_pedido
      ? `<b>Disponible a pedido</b> · ${Befine.plazoAPedido()}`
      : "Despacho en tu zona · entrega en 24 a 48 h hábiles";
    let variante = p.variantes[0]; // seleccionada
    const foto = Befine.foto(p.imagen_url, "lg"), fotoSm = Befine.foto(p.imagen_url, "sm");

    document.title = p.nombre + " · Befine Store";

    cont.innerHTML = `
      <div class="media${foto ? " con-foto" : ""}" style="--v-grad:${grad}">${foto ? `
        <img class="foto-prod" src="${foto}" srcset="${fotoSm} 400w, ${foto} 1000w" sizes="(max-width: 860px) 100vw, 560px"
             alt="${p.nombre.replace(/"/g, "&quot;")}" width="1000" height="1000" fetchpriority="high" decoding="async">` : ""}</div>
      <div class="buybox">
        <div class="breadcrumb"><a href="index.html">Inicio</a> / <a href="catalogo.html?cat=${p.categoria_slug}">${p.categoria}</a></div>
        <h1>${p.nombre}</h1>
        <p class="desc">${p.descripcion || ""}</p>
        <p class="price" id="fPrecio">${variante.precio_comparacion ? `<span class="oferta">Oferta</span> ` : ""}${Befine.clp(variante.precio)}${variante.precio_comparacion ? ` <s>${Befine.clp(variante.precio_comparacion)}</s>` : ""}</p>

        ${p.variantes.length > 1 ? `
        <div class="variantes">
          <div class="lbl">Elige una opción</div>
          <div class="opts" id="fOpts">
            ${p.variantes.map((v, idx) => `<button class="opt ${idx === 0 ? "active" : ""}" data-v="${v.id}">${v.nombre} · ${Befine.clp(v.precio)}</button>`).join("")}
          </div>
        </div>` : ""}

        <div class="add-row">
          <div class="stepper">
            <button id="fMenos">−</button>
            <input id="fCant" value="1" readonly>
            <button id="fMas">+</button>
          </div>
          <button class="btn btn-ghost" id="fAdd">Agregar al carrito</button>
          <button class="btn btn-primary" id="fBuy">Comprar ahora</button>
        </div>
        <p class="stock${variante.a_pedido ? " a-pedido" : ""}" id="fStock" aria-live="polite">${stockHTML(variante)}</p>
        <p class="club-ficha" id="fClub"${variante.suma_puntos ? "" : " hidden"}>${clubHTML}</p>
        ${(() => { const r = Befine.retractoDe(p.categoria_slug); return `
        <aside class="retracto" aria-label="Derecho a retracto">
          <p class="tit">${r.titulo}</p>
          <p>${r.texto} <a href="cambios.html#retracto">Ver condiciones</a></p>
        </aside>`; })()}
      </div>`;

    // Selección de variante
    const precioEl = document.getElementById("fPrecio");
    const opts = document.getElementById("fOpts");
    if (opts) opts.addEventListener("click", (e) => {
      const b = e.target.closest(".opt"); if (!b) return;
      opts.querySelectorAll(".opt").forEach((x) => x.classList.remove("active"));
      b.classList.add("active");
      variante = p.variantes.find((v) => v.id === b.dataset.v);
      const st = document.getElementById("fStock");
      st.innerHTML = stockHTML(variante);
      st.classList.toggle("a-pedido", !!variante.a_pedido);
      document.getElementById("fClub").hidden = !variante.suma_puntos;
      precioEl.innerHTML = (variante.precio_comparacion ? `<span class="oferta">Oferta</span> ` : "") + Befine.clp(variante.precio) + (variante.precio_comparacion ? ` <s>${Befine.clp(variante.precio_comparacion)}</s>` : "");
    });

    // Cantidad
    const cant = document.getElementById("fCant");
    document.getElementById("fMas").onclick = () => cant.value = (+cant.value + 1);
    document.getElementById("fMenos").onclick = () => cant.value = Math.max(1, +cant.value - 1);

    // Agregar al carrito / Comprar ahora
    const itemDe = () => ({
      variante_id: variante.id, producto_id: p.id, nombre: p.nombre,
      variante: variante.nombre, precio: variante.precio, grad, foto: fotoSm, a_pedido: !!variante.a_pedido, suma_puntos: !!variante.suma_puntos,
    });
    document.getElementById("fAdd").onclick = () => {
      Store.add(itemDe(), +cant.value);
      window.toast("Agregado al carrito: " + p.nombre);
    };
    document.getElementById("fBuy").onclick = () => {
      Store.add(itemDe(), +cant.value);
      window.openCheckout(); // pago directo, sin pasar por el catálogo
    };
  });
})();
