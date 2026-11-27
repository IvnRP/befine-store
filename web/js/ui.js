/* =====================================================================
   ui.js — Cascarón interactivo compartido (se carga en TODAS las páginas)
   ---------------------------------------------------------------------
   Responsabilidades:
     - toast()        : aviso flotante reutilizable  -> window.toast('...')
     - catGrad()      : degradado placeholder por categoría -> window.catGrad(slug)
     - Reveals        : animación de aparición al hacer scroll
     - Carrito        : inyecta y controla el cajón (drawer) + contador
     - Ir a pagar     : lleva a checkout.html (compra como invitado o con cuenta)
     - Menú móvil     : abre/cierra la navegación en pantallas chicas
   Se ejecuta al cargar el DOM. Las páginas solo deben tener el botón
   .cart-btn en la barra; el resto lo monta este archivo.
   ===================================================================== */
(function () {
  /* ---------- Degradados placeholder por categoría ---------- */
  const GRADS = {
    packs: "linear-gradient(160deg,#2A86E0,#0B2F70)",
    dispensadores: "linear-gradient(160deg,#3D9BEA,#0D2A5E)",
    bidones: "linear-gradient(160deg,#1E6FD0,#0A2A66)",
    recargas: "linear-gradient(160deg,#1259B8,#0A2352)",
  };
  window.catGrad = (slug) => GRADS[slug] || "linear-gradient(160deg,#1E6FD0,#0A2A66)";
  /* Fondo de la miniatura de un ítem del carrito: su foto (si es una URL https segura) o el degradado.
     El carrito vive en localStorage: no se confía en su contenido para armar el estilo. */
  window.fondoItem = (i) => {
    const u = String((i && i.foto) || "");
    return /^https:\/\/[^"'()\s<>\\]+$/.test(u)
      ? `background:#fff url('${u}') center/contain no-repeat`
      : `background:${(i && i.grad) || window.catGrad()}`;
  };

  /* ---------- Repetir un pedido (recompra en 1 toque) ----------
     Agrega los productos de un pedido anterior al carrito con el precio de HOY y lleva al checkout.
     La usan el inicio (último pedido), Mi cuenta y el enlace "Repetir este pedido" del correo.
     items = [{ variante_id, cantidad, nombre }]. Devuelve { ok:false, error } si no se pudo. */
  window.repetirPedido = async function (items) {
    const r = await Befine.volverAPedir(items);
    if (!r.ok) return r;
    if (!r.agregar.length) return { ok: false, error: "Los productos de ese pedido ya no están disponibles." };
    const antes = Store.count();   // suma al carrito actual (no borra lo que el cliente ya eligió)
    r.agregar.forEach((a) => Store.add({ ...a.item, grad: window.catGrad(a.categoria_slug) }, a.cantidad));
    try { sessionStorage.setItem("befine_aviso_checkout", Befine.avisoRepeticion(antes, r.noDisponibles)); } catch (e) {}
    location.href = "checkout.html";
    return { ok: true };
  };

  /* ---------- Toast ---------- */
  let toastT;
  window.toast = function (msg) {
    let t = document.getElementById("toast");
    if (!t) { t = document.createElement("div"); t.id = "toast"; t.className = "toast"; t.setAttribute("role", "status"); document.body.appendChild(t); }
    t.textContent = msg; t.classList.add("show");
    clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove("show"), 3000);
  };

  /* ---------- Reveals (aparecer al hacer scroll) ---------- */
  function initReveals() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    document.documentElement.classList.add("js-anim");
    const io = new IntersectionObserver((ents) => {
      ents.forEach((en) => {
        if (en.isIntersecting) {
          en.target.style.transitionDelay = ((+en.target.dataset.d || 0) * 0.07) + "s";
          en.target.classList.add("in"); io.unobserve(en.target);
        }
      });
    }, { threshold: .12, rootMargin: "0px 0px -8% 0px" });
    document.querySelectorAll(".reveal").forEach((el) => io.observe(el));
  }

  /* ---------- Carrito: inyecta el drawer ---------- */
  function buildCartUI() {
    const html = `
      <div class="drawer-backdrop" id="cartBackdrop"></div>
      <aside class="drawer" id="cartDrawer" aria-label="Carrito de compra">
        <header><h3>Tu carrito</h3><button class="close" id="cartClose" aria-label="Cerrar">&times;</button></header>
        <div class="items" id="cartItems"></div>
        <footer>
          <div class="carro-envio" id="cartEnvio">
            <p class="franja-envio">Envío gratis en compras desde <b data-envio-min>$7.000</b></p>
            <div class="barra" hidden><span id="cartEnvioBar"></span></div>
            <p class="txt" id="cartEnvioTxt" hidden></p>
          </div>
          <div class="total-row"><span>Total</span><span class="big" id="cartTotal">$0</span></div>
          <button class="btn btn-primary btn-block" id="cartCheckout">Ir a pagar</button>
        </footer>
      </aside>
`;
    document.body.insertAdjacentHTML("beforeend", html);

    const backdrop = document.getElementById("cartBackdrop");
    const drawer = document.getElementById("cartDrawer");
    const openBtns = document.querySelectorAll(".cart-btn");
    const open = () => { backdrop.classList.add("open"); drawer.classList.add("open"); };
    const close = () => { backdrop.classList.remove("open"); drawer.classList.remove("open"); };
    openBtns.forEach((b) => b.addEventListener("click", open));
    document.getElementById("cartClose").addEventListener("click", close);
    backdrop.addEventListener("click", close);

    // Ir a pagar: el checkout es una página propia (checkout.html), compra como invitado o con cuenta
    function openCheckout() {
      if (Store.count() === 0) { window.toast("Tu carrito está vacío."); return; }
      location.href = "checkout.html";
    }
    window.openCheckout = openCheckout;   // lo usan el carrito y el botón "Comprar ahora"
    document.getElementById("cartCheckout").addEventListener("click", openCheckout);

    // Monto del envío gratis: parametros.envio_gratis_minimo (el mismo que usa crear_pedido);
    // si la base no responde queda $7.000.
    if (window.Befine && Befine.getCobertura) {
      Befine.getCobertura().then((c) => {
        if (c && c.envioGratisDesde) { envioGratisDesde = c.envioGratisDesde; renderCart(Store.items ? Store.items() : []); }
      }).catch(() => {});
    }

    // Redibujar el contenido del carrito cada vez que cambia
    Store.subscribe(renderCart);
  }

  let envioGratisDesde = 7000;
  // Franja del carrito: monto mínimo y cuánto falta para el envío gratis (según el subtotal)
  function pintarEnvioCarrito() {
    document.querySelectorAll("[data-envio-min]").forEach((el) => { el.textContent = Befine.clp(envioGratisDesde); });
    const bar = document.getElementById("cartEnvioBar"), txt = document.getElementById("cartEnvioTxt");
    if (!bar || !txt) return;
    const sub = Store.count() ? Store.total() : 0, falta = Math.max(0, envioGratisDesde - sub);
    bar.parentElement.hidden = txt.hidden = !sub;
    bar.style.width = Math.min(100, (sub / envioGratisDesde) * 100) + "%";
    txt.textContent = falta > 0 ? `Te faltan ${Befine.clp(falta)} para el envío gratis` : "¡Tu compra tiene envío gratis!";
  }

  function renderCart(items) {
    // Contador en la barra
    document.querySelectorAll(".cart-count").forEach((el) => {
      const c = Store.count(); el.textContent = c; el.style.display = c ? "grid" : "none";
    });
    const box = document.getElementById("cartItems");
    const totalEl = document.getElementById("cartTotal");
    if (!box) return;
    pintarEnvioCarrito();
    if (!items.length) { box.innerHTML = `<p class="empty">Aún no agregas productos.</p>`; if (totalEl) totalEl.textContent = "$0"; return; }
    box.innerHTML = items.map((i) => `
      <div class="cart-item">
        <div class="thumb${i.foto ? " con-foto" : ""}" style="${window.fondoItem(i)}"></div>
        <div class="info">
          <h4>${Befine.esc(i.nombre)}</h4>
          ${i.variante && i.variante !== "Estándar" ? `<div class="var">${Befine.esc(i.variante)}</div>` : ""}
          ${i.a_pedido ? `<div class="var"><b>Disponible a pedido</b></div>` : ""}
          <div class="price">${Befine.clp(i.precio)} · x${i.cantidad}</div>
          <div class="stepper" style="margin-top:6px">
            <button data-dec="${Befine.esc(i.variante_id)}" aria-label="Menos">−</button>
            <input value="${Befine.esc(i.cantidad)}" readonly aria-label="Cantidad de ${Befine.esc(i.nombre)}">
            <button data-inc="${Befine.esc(i.variante_id)}" aria-label="Más">+</button>
          </div>
        </div>
        <button class="remove" data-del="${Befine.esc(i.variante_id)}">Quitar</button>
      </div>`).join("");
    if (totalEl) totalEl.textContent = Befine.clp(Store.total());

    box.querySelectorAll("[data-inc]").forEach((b) => b.onclick = () => Store.setQty(b.dataset.inc, itemQty(b.dataset.inc) + 1));
    box.querySelectorAll("[data-dec]").forEach((b) => b.onclick = () => Store.setQty(b.dataset.dec, itemQty(b.dataset.dec) - 1));
    box.querySelectorAll("[data-del]").forEach((b) => b.onclick = () => Store.remove(b.dataset.del));
  }
  function itemQty(id) { const it = Store.items().find((i) => i.variante_id === id); return it ? it.cantidad : 0; }

  /* ---------- Menú móvil ---------- */
  function initMenu() {
    const btn = document.querySelector(".menu-btn");
    const nav = document.querySelector(".nav");
    if (btn && nav) btn.addEventListener("click", () => {
      const open = nav.style.display === "flex";
      nav.style.display = open ? "" : "flex";
      nav.style.position = "absolute"; nav.style.top = "58px"; nav.style.right = "16px";
      nav.style.flexDirection = "column"; nav.style.background = "var(--glass-2)";
      nav.style.padding = "14px 18px"; nav.style.borderRadius = "14px"; nav.style.border = "1px solid var(--line)";
    });
  }

  /* ---------- Buscador móvil: la lupa despliega el campo sobre la barra ---------- */
  function initSearch() {
    const form = document.querySelector(".search");
    if (!form) return;
    const input = form.querySelector("input");
    const icon = form.querySelector("svg");
    if (!input || !icon) return;
    const isMobile = () => window.matchMedia("(max-width: 720px)").matches;
    icon.style.cursor = "pointer";
    icon.addEventListener("click", (e) => {
      if (!isMobile()) return;                         // en desktop el campo ya está visible
      if (!form.classList.contains("expanded")) {
        e.preventDefault(); e.stopPropagation();
        form.classList.add("expanded");
        setTimeout(() => input.focus(), 60);
      } else if (input.value.trim()) {
        form.submit();                                 // ya expandido y con texto: buscar
      } else {
        e.preventDefault();
      }
    });
    input.addEventListener("blur", () => { if (!input.value.trim()) form.classList.remove("expanded"); });
    input.addEventListener("keydown", (e) => { if (e.key === "Escape") { form.classList.remove("expanded"); input.blur(); } });
  }

  /* ---------- Arranque ---------- */
  document.addEventListener("DOMContentLoaded", () => {
    buildCartUI();
    initReveals();
    initMenu();
    initSearch();
  });
})();
