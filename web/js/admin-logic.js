/* =====================================================================
   admin-logic.js — Reglas del panel de administración (SIN acceso a red)
   ---------------------------------------------------------------------
   Funciones puras: reciben datos y devuelven resultados. No tocan el DOM
   ni Supabase, por eso se prueban con node:test (tests/unit/admin.test.js).
   La seguridad real la da el RLS de Supabase (migración 01); estas reglas
   solo deciden qué MUESTRA la interfaz a cada rol (segunda capa).
   ===================================================================== */
(function (root) {
  /* ---------- Permisos (mismo catálogo que public.permisos, migración 01) ---------- */
  const PERMISOS = [
    "pedidos.ver", "pedidos.gestionar", "catalogo.gestionar", "precios.gestionar",
    "promociones.gestionar", "despacho.gestionar", "clientes.ver", "clientes.gestionar",
    "pagos.gestionar", "documentos.gestionar", "puntos.gestionar", "config.gestionar",
  ];

  /* Permisos efectivos de un rol. El admin tiene todos (igual que tiene_permiso() en la BD);
     el cliente ninguno; los demás roles, los que el admin les asignó en rol_permisos. */
  function permisosDe(rol, filasRolPermisos) {
    if (!rol || rol === "cliente") return [];
    if (rol === "admin") return PERMISOS.slice();
    return (filasRolPermisos || [])
      .filter((f) => f && f.rol_id === rol && typeof f.permiso === "string")
      .map((f) => f.permiso)
      .filter((p, i, a) => a.indexOf(p) === i);
  }

  const puede = (permisos, p) => Array.isArray(permisos) && permisos.includes(p);

  /* Secciones del panel y el permiso que habilita cada una (basta con uno de la lista) */
  const SECCIONES = [
    { id: "pedidos", txt: "Pedidos", requiere: ["pedidos.ver", "pedidos.gestionar"] },
    { id: "catalogo", txt: "Catálogo y precios", requiere: ["catalogo.gestionar", "precios.gestionar"] },
    { id: "inventario", txt: "Inventario", requiere: ["catalogo.gestionar"] },
  ];
  const seccionesVisibles = (permisos) =>
    SECCIONES.filter((s) => s.requiere.some((p) => puede(permisos, p)));

  /* ---------- Estados del pedido (enum public.estado_pedido) ---------- */
  const ESTADOS = {
    pendiente_pago: { txt: "Pendiente de pago", tono: "espera" },
    pagado:         { txt: "Pagado",            tono: "ok" },
    en_preparacion: { txt: "En preparación",    tono: "info" },
    en_ruta:        { txt: "En camino",         tono: "ruta" },
    entregado:      { txt: "Entregado",         tono: "fin" },
    cancelado:      { txt: "Cancelado",         tono: "mal" },
  };
  const ORDEN_ESTADOS = Object.keys(ESTADOS);
  const etiquetaEstado = (e) => (ESTADOS[e] ? ESTADOS[e].txt : String(e || "—"));

  /* Texto sin acentos ni mayúsculas (mismo criterio que el buscador de la tienda) */
  const norm = (s) => String(s == null ? "" : s).toLowerCase()
    .normalize("NFD").replace(/[̀-ͯ]/g, "").trim();

  /* ---------- Flujo de estados que puede aplicar el panel (pedidos.gestionar) ----------
     - "pagado" lo marca SOLO el servidor al confirmar Mercado Pago (migración 03):
       un pedido sin pagar nunca sale a reparto. Desde el panel solo se cancela.
     - "En camino" y "Entregado" también los marca el chofer (migración 02).
     - Entregado y cancelado cierran el ciclo. */
  const TRANSICIONES = {
    pendiente_pago: ["cancelado"],
    pagado:         ["en_preparacion", "cancelado"],
    en_preparacion: ["en_ruta", "cancelado"],
    en_ruta:        ["entregado"],
    entregado:      [],
    cancelado:      [],
  };
  const siguientesEstados = (estado) => (TRANSICIONES[estado] || []).slice();
  const puedeCambiar = (de, a) => siguientesEstados(de).includes(a);

  /* Texto del botón para cada cambio */
  const ACCION_ESTADO = {
    en_preparacion: "Pasar a preparación",
    en_ruta: "Marcar en camino",
    entregado: "Marcar entregado",
    cancelado: "Cancelar pedido",
  };

  /* Filtro de la lista: estado ("todos" | "activos" | un estado) y búsqueda por
     número (#123 o 123), nombre, teléfono o comuna. */
  const ACTIVOS = ["pagado", "en_preparacion", "en_ruta"];
  function filtrarPedidos(lista, { estado = "todos", q = "" } = {}) {
    const t = norm(q).replace(/^#/, "");
    const tel = t.replace(/\D/g, "");
    return (lista || []).filter((p) => {
      if (estado === "activos" && !ACTIVOS.includes(p.estado)) return false;
      if (estado !== "todos" && estado !== "activos" && p.estado !== estado) return false;
      if (!t) return true;
      if (/^\d+$/.test(t) && String(p.numero) === t) return true;
      const dir = p.direccion || {};
      const texto = norm([p.contacto_nombre, p.contacto_email, dir.comuna, dir.calle].join(" "));
      return texto.includes(t) || (tel.length >= 4 && String(p.contacto_telefono || "").includes(tel));
    });
  }

  /* Cantidad de pedidos por estado (para los filtros) */
  function contarPorEstado(lista) {
    const c = { todos: 0, activos: 0 };
    ORDEN_ESTADOS.forEach((e) => { c[e] = 0; });
    (lista || []).forEach((p) => {
      c.todos++; if (c[p.estado] != null) c[p.estado]++;
      if (ACTIVOS.includes(p.estado)) c.activos++;
    });
    return c;
  }

  /* Fecha local AAAA-MM-DD (para comparar "hoy" sin problemas de zona horaria) */
  const diaLocal = (d) => {
    const x = d instanceof Date ? d : new Date(d);
    return x.getFullYear() + "-" + String(x.getMonth() + 1).padStart(2, "0") + "-" + String(x.getDate()).padStart(2, "0");
  };

  /* Indicadores del inicio de Pedidos. Ventas = pedidos pagados (en cualquier etapa
     posterior al pago) creados en el mes en curso. */
  const VENDIDOS = ["pagado", "en_preparacion", "en_ruta", "entregado"];
  function resumenPedidos(lista, hoy = new Date()) {
    const dHoy = diaLocal(hoy), mes = dHoy.slice(0, 7);
    const r = { hoy: 0, porPreparar: 0, enRuta: 0, pendientesPago: 0, ventasMes: 0, pedidosMes: 0, entregaHoy: 0 };
    (lista || []).forEach((p) => {
      const dia = p.created_at ? diaLocal(p.created_at) : "";
      if (dia === dHoy && p.estado !== "cancelado") r.hoy++;
      if (p.estado === "pagado" || p.estado === "en_preparacion") r.porPreparar++;
      if (p.estado === "en_ruta") r.enRuta++;
      if (p.estado === "pendiente_pago") r.pendientesPago++;
      if (p.fecha_entrega === dHoy && ACTIVOS.includes(p.estado)) r.entregaHoy++;
      if (VENDIDOS.includes(p.estado) && dia.slice(0, 7) === mes) { r.ventasMes += Number(p.total) || 0; r.pedidosMes++; }
    });
    return r;
  }

  /* Enlace de WhatsApp al cliente (teléfono guardado como 569XXXXXXXX por crear_pedido) */
  function linkWhatsApp(telefono, texto) {
    const d = String(telefono || "").replace(/\D/g, "");
    if (!/^569\d{8}$/.test(d)) return null;
    return "https://wa.me/" + d + (texto ? "?text=" + encodeURIComponent(texto) : "");
  }
  const telefonoVisible = (t) => {
    const d = String(t || "").replace(/\D/g, "");
    return /^569\d{8}$/.test(d) ? "+56 9 " + d.slice(3, 7) + " " + d.slice(7) : (t || "—");
  };

  /* ---------- Catálogo y precios (RF-17) ---------- */
  /* Precio en CLP desde lo que escribe el dueño: "3000", "3.000", "$3.000" → 3000.
     Devuelve null si no es un entero válido entre 0 y 9.999.999. */
  function parsePrecio(v) {
    if (typeof v === "number") return Number.isInteger(v) && v >= 0 && v <= 9999999 ? v : null;
    const t = String(v == null ? "" : v).trim().replace(/^\$\s*/, "").replace(/\./g, "");
    if (!/^\d{1,7}$/.test(t)) return null;
    return Number(t);
  }

  /* SKU: mayúsculas, sin espacios ni acentos (BEF-REC-20) */
  const normalizarSku = (v) => norm(v).toUpperCase().replace(/\s+/g, "-").replace(/[^A-Z0-9-]/g, "");

  /* Validaciones → objeto { campo: "mensaje" } (vacío = válido) */
  function validarProducto(p) {
    const e = {};
    const nombre = String((p && p.nombre) || "").trim();
    if (nombre.length < 3) e.nombre = "Escribe el nombre del producto (mínimo 3 caracteres).";
    else if (nombre.length > 120) e.nombre = "El nombre es muy largo (máximo 120 caracteres).";
    if (!p || !p.categoria_id) e.categoria_id = "Elige una categoría.";
    if (p && p.descripcion && String(p.descripcion).length > 1000) e.descripcion = "La descripción es muy larga (máximo 1.000 caracteres).";
    if (p && p.imagen_url && !/^https:\/\/\S+$/i.test(String(p.imagen_url).trim())) e.imagen_url = "La imagen debe ser un enlace https://";
    return e;
  }

  function validarVariante(v, skusExistentes, idActual) {
    const e = {};
    const sku = normalizarSku(v && v.sku);
    if (!/^[A-Z0-9][A-Z0-9-]{2,39}$/.test(sku)) e.sku = "El SKU debe tener entre 3 y 40 caracteres (letras, números y guiones).";
    else if ((skusExistentes || []).some((x) => x && x.sku === sku && x.id !== idActual)) e.sku = "Ese SKU ya existe en otro producto.";
    const nombre = String((v && v.nombre) || "").trim();
    if (!nombre) e.nombre = "Escribe el nombre de la variante (ej: Estándar, Con bidón Befine).";
    else if (nombre.length > 60) e.nombre = "Máximo 60 caracteres.";
    if (v && "precio" in v && parsePrecio(v.precio) === null) e.precio = "Escribe un precio válido en pesos, sin decimales.";
    return e;
  }

  /* Filtro del catálogo: categoría (id), visibilidad y texto (nombre, SKU o variante) */
  function filtrarCatalogo(productos, { categoria = "", q = "", estado = "todos" } = {}) {
    const t = norm(q);
    return (productos || []).filter((p) => {
      if (categoria && String(p.categoria_id) !== String(categoria)) return false;
      if (estado === "visibles" && !p.activo) return false;
      if (estado === "ocultos" && p.activo) return false;
      if (!t) return true;
      const vs = (p.variantes || []).map((v) => v.sku + " " + v.nombre).join(" ");
      return norm(p.nombre + " " + vs).includes(t);
    });
  }

  /* ---------- Inventario (RF-18) ---------- */
  /* Umbral de "stock bajo": parámetro stock_alerta (editable); 10 si no existe o es inválido */
  const UMBRAL_DEFECTO = 10;
  function umbralStock(valor) {
    const n = parseInt(String(valor == null ? "" : valor).trim(), 10);
    return Number.isInteger(n) && n >= 0 && n <= 100000 ? n : UMBRAL_DEFECTO;
  }

  /* Nivel de una variante: sin_control (no lleva stock) | agotado | bajo | ok */
  function nivelStock(v, umbral = UMBRAL_DEFECTO) {
    if (!v || v.controla_stock === false) return "sin_control";
    const s = Number(v.stock) || 0;
    if (s <= 0) return "agotado";
    if (s <= umbral) return "bajo";
    return "ok";
  }
  const NIVELES_STOCK = {
    agotado:     { txt: "Agotado",     tono: "mal" },
    bajo:        { txt: "Stock bajo",  tono: "espera" },
    ok:          { txt: "Disponible",  tono: "ok" },
    sin_control: { txt: "No controla", tono: "fin" },
  };

  /* Cantidad válida de stock: entero entre 0 y 100.000 (null si no es válida) */
  function parseStock(v) {
    const t = String(v == null ? "" : v).trim().replace(/\./g, "");
    if (!/^\d{1,6}$/.test(t)) return null;
    const n = Number(t);
    return n <= 100000 ? n : null;
  }
  /* Suma o resta unidades sin bajar de 0 */
  const sumarStock = (actual, delta) => Math.max(0, (Number(actual) || 0) + (Number(delta) || 0));

  function resumenStock(variantes, umbral) {
    const r = { agotado: 0, bajo: 0, ok: 0, sin_control: 0, total: 0 };
    (variantes || []).forEach((v) => { r[nivelStock(v, umbral)]++; r.total++; });
    return r;
  }

  /* Filtro: nivel ("todos" | "alerta" = agotado + bajo | un nivel) y texto (producto, variante o SKU).
     Orden: lo más urgente primero (agotado, bajo, ok, sin control) y luego por nombre. */
  const PRIORIDAD = { agotado: 0, bajo: 1, ok: 2, sin_control: 3 };
  function filtrarInventario(variantes, { nivel = "todos", q = "" } = {}, umbral) {
    const t = norm(q);
    return (variantes || [])
      .map((v) => ({ v, n: nivelStock(v, umbral) }))
      .filter(({ v, n }) => {
        if (nivel === "alerta" && n !== "agotado" && n !== "bajo") return false;
        if (nivel !== "todos" && nivel !== "alerta" && n !== nivel) return false;
        return !t || norm([v.producto, v.nombre, v.sku].join(" ")).includes(t);
      })
      .sort((a, b) => PRIORIDAD[a.n] - PRIORIDAD[b.n] || String(a.v.producto).localeCompare(String(b.v.producto)) || String(a.v.sku).localeCompare(String(b.v.sku)))
      .map(({ v }) => v);
  }

  root.AdminLogic = {
    PERMISOS, permisosDe, puede, SECCIONES, seccionesVisibles,
    ESTADOS, ORDEN_ESTADOS, etiquetaEstado, norm,
    TRANSICIONES, siguientesEstados, puedeCambiar, ACCION_ESTADO,
    filtrarPedidos, contarPorEstado, resumenPedidos, diaLocal, linkWhatsApp, telefonoVisible,
    parsePrecio, normalizarSku, validarProducto, validarVariante, filtrarCatalogo,
    UMBRAL_DEFECTO, umbralStock, nivelStock, NIVELES_STOCK, parseStock, sumarStock, resumenStock, filtrarInventario,
  };
})(typeof window !== "undefined" ? window : globalThis);
