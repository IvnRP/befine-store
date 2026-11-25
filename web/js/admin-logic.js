/* =====================================================================
   admin-logic.js — Reglas del panel de administración (SIN acceso a red)
   ---------------------------------------------------------------------
   Funciones puras: reciben datos y devuelven resultados. No tocan el DOM
   ni Supabase, por eso se prueban con node:test (tests/unit/admin.test.js).
   La seguridad real la da el RLS de Supabase (migración 01); estas reglas
   solo deciden qué MUESTRA la interfaz a cada rol (segunda capa).
   ===================================================================== */
(function (root) {
  /* ---------- Permisos (mismo catálogo que public.permisos, migraciones 01 y 02) ---------- */
  const PERMISOS = [
    "pedidos.ver", "pedidos.gestionar", "pedidos.repartir", "catalogo.gestionar", "precios.gestionar",
    "promociones.gestionar", "despacho.gestionar", "clientes.ver", "clientes.gestionar",
    "pagos.gestionar", "documentos.gestionar", "puntos.gestionar", "config.gestionar",
    "pedidos.registrar",   // pedidos fuera de la página (migración 21)
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

  /* Secciones del panel y el permiso que habilita cada una (basta con uno de la lista).
     soloAdmin: la gestiona solo el rol admin (igual que es_admin() en la base, migración 02). */
  const SECCIONES = [
    { id: "pedidos", txt: "Pedidos", requiere: ["pedidos.ver", "pedidos.gestionar"] },
    { id: "reparto", txt: "Reparto", requiere: ["pedidos.repartir"] },
    { id: "clientes", txt: "Clientes", requiere: ["clientes.ver", "clientes.gestionar"] },
    { id: "catalogo", txt: "Catálogo y precios", requiere: ["catalogo.gestionar", "precios.gestionar"] },
    { id: "inventario", txt: "Inventario", requiere: ["catalogo.gestionar"] },
    { id: "cupones", txt: "Cupones", requiere: ["promociones.gestionar"] },
    { id: "equipo", txt: "Equipo y roles", soloAdmin: true },
  ];
  const seccionesVisibles = (permisos, rol) =>
    SECCIONES.filter((s) => s.soloAdmin ? rol === "admin" : s.requiere.some((p) => puede(permisos, p)));

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

  /* Filtro de la lista: estado ("todos" | "activos" | "sin_documento" | un estado) y búsqueda por
     número (#123 o 123), nombre, teléfono o comuna. */
  const ACTIVOS = ["pagado", "en_preparacion", "en_ruta"];
  function filtrarPedidos(lista, { estado = "todos", q = "", entrega = null } = {}) {
    const t = norm(q).replace(/^#/, "");
    const tel = t.replace(/\D/g, "");
    return (lista || []).filter((p) => {
      if (!enRangoEntrega(p, entrega)) return false;
      if (estado === "activos" && !ACTIVOS.includes(p.estado)) return false;
      if (estado === "sin_documento" && !pendienteDocumento(p)) return false;
      if (estado === "fuera_pagina" && !esFueraPagina(p)) return false;
      if (!["todos", "activos", "sin_documento", "fuera_pagina"].includes(estado) && p.estado !== estado) return false;
      if (!t) return true;
      if (/^\d+$/.test(t) && String(p.numero) === t) return true;
      const dir = p.direccion || {};
      const texto = norm([p.contacto_nombre, p.contacto_email, dir.comuna, dir.calle].join(" "));
      return texto.includes(t) || (tel.length >= 4 && String(p.contacto_telefono || "").includes(tel));
    });
  }

  /* Cantidad de pedidos por estado (para los filtros) */
  function contarPorEstado(lista) {
    const c = { todos: 0, activos: 0, sin_documento: 0, fuera_pagina: 0 };
    ORDEN_ESTADOS.forEach((e) => { c[e] = 0; });
    (lista || []).forEach((p) => {
      c.todos++; if (c[p.estado] != null) c[p.estado]++;
      if (ACTIVOS.includes(p.estado)) c.activos++;
      if (pendienteDocumento(p)) c.sin_documento++;
      if (esFueraPagina(p)) c.fuera_pagina++;
    });
    return c;
  }

  /* Fecha local AAAA-MM-DD (para comparar "hoy" sin problemas de zona horaria) */
  const diaLocal = (d) => {
    const x = d instanceof Date ? d : new Date(d);
    return x.getFullYear() + "-" + String(x.getMonth() + 1).padStart(2, "0") + "-" + String(x.getDate()).padStart(2, "0");
  };

  /* ---------- Filtro por fecha de entrega (HU-07) ----------
     Las fechas se manejan como texto AAAA-MM-DD (igual que la columna
     pedidos.fecha_entrega, tipo date), así se comparan sin desfases de zona horaria. */
  const ES_DIA = /^\d{4}-\d{2}-\d{2}$/;
  const aFecha = (iso) => { const [y, m, d] = iso.split("-").map(Number); return new Date(y, m - 1, d); };
  const sumarDias = (iso, n) => { const x = aFecha(iso); x.setDate(x.getDate() + n); return diaLocal(x); };
  const diaSemana = (iso) => aFecha(iso).getDay() || 7;            // 1 = lunes … 7 = domingo
  function siguienteHabil(iso) {
    let x = sumarDias(iso, 1);
    while (diaSemana(x) > 5) x = sumarDias(x, 1);
    return x;
  }

  /* Opciones del filtro de entrega. "Siguiente día hábil" porque el despacho
     es de lunes a viernes: un viernes, la siguiente entrega es el lunes. */
  const OPCIONES_ENTREGA = { todas: "Cualquier fecha", hoy: "Hoy", siguiente: "Siguiente día hábil", semana: "Esta semana", rango: "Elegir fechas" };

  /* Convierte la opción elegida en un rango { desde, hasta } (inclusive) o null
     si no hay que filtrar. "Esta semana" va de lunes a domingo de la semana en curso,
     así también aparecen los pedidos atrasados de días anteriores. */
  function rangoEntrega(opcion, hoy = new Date(), desde = "", hasta = "") {
    const d = diaLocal(hoy);
    switch (opcion) {
      case "hoy": return { desde: d, hasta: d };
      case "siguiente": { const s = siguienteHabil(d); return { desde: s, hasta: s }; }
      case "semana": { const lun = sumarDias(d, 1 - diaSemana(d)); return { desde: lun, hasta: sumarDias(lun, 6) }; }
      case "rango": {
        let a = ES_DIA.test(desde || "") ? desde : "", b = ES_DIA.test(hasta || "") ? hasta : "";
        if (!a && !b) return null;
        if (a && b && a > b) [a, b] = [b, a];
        return { desde: a, hasta: b };
      }
      default: return null;
    }
  }

  function enRangoEntrega(p, r) {
    if (!r) return true;
    const f = p && p.fecha_entrega;
    if (!f || !ES_DIA.test(f)) return false;
    return (!r.desde || f >= r.desde) && (!r.hasta || f <= r.hasta);
  }

  /* Texto corto del rango para mostrar junto al filtro: "jueves 22 oct", "26 – 30 oct" */
  function textoRango(r) {
    if (!r) return "";
    const f = (iso, conDia) => aFecha(iso).toLocaleDateString("es-CL", { ...(conDia ? { weekday: "long" } : {}), day: "numeric", month: "short" }).replace(/\.$/, "");
    if (r.desde && r.hasta) return r.desde === r.hasta ? f(r.desde, true) : f(r.desde) + " – " + f(r.hasta);
    return r.desde ? "desde el " + f(r.desde) : "hasta el " + f(r.hasta);
  }

  /* Indicadores del inicio de Pedidos. Ventas = pedidos pagados (en cualquier etapa
     posterior al pago) creados en el mes en curso. */
  const VENDIDOS = ["pagado", "en_preparacion", "en_ruta", "entregado"];
  function resumenPedidos(lista, hoy = new Date()) {
    const dHoy = diaLocal(hoy), mes = dHoy.slice(0, 7);
    const r = { hoy: 0, porPreparar: 0, enRuta: 0, pendientesPago: 0, ventasMes: 0, pedidosMes: 0, entregaHoy: 0, fueraPaginaMes: 0 };
    (lista || []).forEach((p) => {
      const dia = p.created_at ? diaLocal(p.created_at) : "";
      if (dia === dHoy && p.estado !== "cancelado") r.hoy++;
      if (p.estado === "pagado" || p.estado === "en_preparacion") r.porPreparar++;
      if (p.estado === "en_ruta") r.enRuta++;
      if (p.estado === "pendiente_pago") r.pendientesPago++;
      if (p.fecha_entrega === dHoy && ACTIVOS.includes(p.estado)) r.entregaHoy++;
      if (VENDIDOS.includes(p.estado) && dia.slice(0, 7) === mes) {
        r.ventasMes += Number(p.total) || 0; r.pedidosMes++;
        if (esFueraPagina(p)) r.fueraPaginaMes++;   // migración 21: cuentan en las ventas del mes
      }
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

  /* Dirección amigable del producto (migración 16): "Bidón + Recarga 12 Litros" → "bidon-recarga-12-litros".
     Misma regla que public.slug_de() en la base. */
  const slugDe = (v) => norm(v).replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80).replace(/-+$/, "");
  const SLUG_OK = /^[a-z0-9]+(-[a-z0-9]+)*$/;

  /* Avisos de pedidos: de la lista de pedidos pagados recientes, los que el panel todavía no había visto
     (por id: un pedido antiguo que se paga tarde también avisa). Ordenados del más antiguo al más nuevo. */
  function pedidosNuevos(vistos, lista) {
    return (lista || []).filter((p) => p && p.id && !vistos.has(p.id)).sort((a, b) => (a.numero || 0) - (b.numero || 0));
  }

  /* Validaciones → objeto { campo: "mensaje" } (vacío = válido) */
  function validarProducto(p) {
    const e = {};
    const nombre = String((p && p.nombre) || "").trim();
    if (nombre.length < 3) e.nombre = "Escribe el nombre del producto (mínimo 3 caracteres).";
    else if (nombre.length > 120) e.nombre = "El nombre es muy largo (máximo 120 caracteres).";
    if (!p || !p.categoria_id) e.categoria_id = "Elige una categoría.";
    if (p && p.descripcion && String(p.descripcion).length > 1000) e.descripcion = "La descripción es muy larga (máximo 1.000 caracteres).";
    // Dirección: opcional (vacía = la base la genera desde el nombre); si viene, solo minúsculas, números y guiones
    const slug = String((p && p.slug) || "").trim();
    if (slug && (!SLUG_OK.test(slug) || slug.length > 80))
      e.slug = "Usa solo minúsculas sin tildes, números y guiones (ej. recarga-agua-purificada-bidon-20-litros).";
    // Imagen: enlace https:// o nombre de archivo del bucket "productos" (migración 07), ej. bidon-12l-1000.webp
    const img = p && p.imagen_url ? String(p.imagen_url).trim() : "";
    if (img && !/^https:\/\/\S+$/i.test(img) && !/^[a-z0-9][a-z0-9_-]*(\/[a-z0-9][a-z0-9_-]*)*\.(webp|jpe?g|png)$/i.test(img))
      e.imagen_url = "Usa un enlace https:// o el nombre del archivo subido a Storage (ej. bidon-12l-1000.webp)";
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

  /* ---------- Cupones (RF-20) ---------- */
  /* Código: mayúsculas, sin espacios ni acentos (CYBER10, BIENVENIDA) */
  const normalizarCodigo = (v) => norm(v).toUpperCase().replace(/\s+/g, "").replace(/[^A-Z0-9-]/g, "");

  /* Entero positivo opcional: "" → null (sin límite); inválido → NaN */
  function enteroOpcional(v) {
    const t = String(v == null ? "" : v).trim().replace(/\./g, "");
    if (t === "") return null;
    return /^\d{1,7}$/.test(t) ? Number(t) : NaN;
  }

  /* Estado visible de un cupón en una fecha (AAAA-MM-DD) */
  function estadoCupon(c, hoy) {
    const d = hoy || diaLocal(new Date());
    if (!c.activo) return "pausado";
    if (c.vigente_hasta && c.vigente_hasta < d) return "vencido";
    if (c.vigente_desde && c.vigente_desde > d) return "programado";
    if (c.usos_maximos != null && c.usos_actuales >= c.usos_maximos) return "agotado";
    return "activo";
  }
  const ESTADOS_CUPON = {
    activo:     { txt: "Activo",     tono: "ok" },
    programado: { txt: "Programado", tono: "info" },
    pausado:    { txt: "Pausado",    tono: "fin" },
    vencido:    { txt: "Vencido",    tono: "mal" },
    agotado:    { txt: "Agotado",    tono: "espera" },
  };

  /* "15%" o "$2.000" */
  const textoDescuento = (c) => c.tipo === "porcentaje"
    ? `${c.valor}%` : "$" + Number(c.valor || 0).toLocaleString("es-CL");

  /* Condiciones legibles para la lista del panel */
  function condicionesCupon(c) {
    const r = [];
    if (c.solo_primera_compra) r.push("solo 1ª compra");
    else if (c.requiere_cuenta) r.push("requiere cuenta");
    if (c.compra_minima > 0) r.push("mín. $" + Number(c.compra_minima).toLocaleString("es-CL"));
    if (c.usos_por_cliente && !c.solo_primera_compra) r.push(c.usos_por_cliente === 1 ? "1 vez por cliente" : `${c.usos_por_cliente} veces por cliente`);
    if (c.variantes && c.variantes.length) r.push(`${c.variantes.length} producto${c.variantes.length === 1 ? "" : "s"}`);
    if (c.perfil_id) r.push("personal");
    return r;
  }

  /* Validación del formulario → { campo: "mensaje" }. c.* llega como texto del formulario. */
  function validarCupon(c, existentes, idActual) {
    const e = {};
    const codigo = normalizarCodigo(c.codigo);
    if (!/^[A-Z0-9][A-Z0-9-]{2,29}$/.test(codigo)) e.codigo = "Usa entre 3 y 30 letras, números o guiones (ej: CYBER10).";
    else if ((existentes || []).some((x) => x && normalizarCodigo(x.codigo) === codigo && x.id !== idActual)) e.codigo = "Ya existe un cupón con ese código.";
    if (c.tipo !== "porcentaje" && c.tipo !== "monto_fijo") e.tipo = "Elige el tipo de descuento.";
    const valor = c.tipo === "porcentaje" ? enteroOpcional(c.valor) : parsePrecio(c.valor);
    if (valor == null || Number.isNaN(valor) || valor <= 0) e.valor = c.tipo === "porcentaje" ? "Escribe un porcentaje entre 1 y 100." : "Escribe un monto en pesos mayor a 0.";
    else if (c.tipo === "porcentaje" && valor > 100) e.valor = "El porcentaje no puede superar 100.";
    const min = String(c.compra_minima == null ? "" : c.compra_minima).trim() === "" ? 0 : parsePrecio(c.compra_minima);
    if (min === null) e.compra_minima = "Escribe un monto en pesos (o déjalo vacío).";
    const um = enteroOpcional(c.usos_maximos), uc = enteroOpcional(c.usos_por_cliente);
    if (Number.isNaN(um) || um === 0) e.usos_maximos = "Escribe un número mayor a 0, o déjalo vacío (sin límite).";
    if (Number.isNaN(uc) || uc === 0) e.usos_por_cliente = "Escribe un número mayor a 0, o déjalo vacío (sin límite).";
    if (c.vigente_desde && c.vigente_hasta && c.vigente_desde > c.vigente_hasta) e.vigente_hasta = "La fecha de término es anterior a la de inicio.";
    if (c.descripcion && String(c.descripcion).length > 200) e.descripcion = "Máximo 200 caracteres.";
    return e;
  }

  /* Fila lista para guardar en public.cupones (a partir de un formulario válido).
     El cupón de bienvenida siempre exige cuenta y se usa una vez por cliente. */
  function filaCupon(c) {
    const primera = !!c.solo_primera_compra;
    const fila = {
      codigo: normalizarCodigo(c.codigo),
      tipo: c.tipo,
      valor: c.tipo === "porcentaje" ? enteroOpcional(c.valor) : parsePrecio(c.valor),
      compra_minima: String(c.compra_minima == null ? "" : c.compra_minima).trim() === "" ? 0 : parsePrecio(c.compra_minima),
      usos_maximos: enteroOpcional(c.usos_maximos),
      vigente_desde: c.vigente_desde || null,
      vigente_hasta: c.vigente_hasta || null,
      activo: !!c.activo,
      solo_primera_compra: primera,
      requiere_cuenta: primera || !!c.requiere_cuenta,
      usos_por_cliente: primera ? 1 : enteroOpcional(c.usos_por_cliente),
      descripcion: String(c.descripcion || "").trim() || null,
    };
    return fila;
  }

  function filtrarCupones(cupones, { estado = "todos", q = "" } = {}, hoy) {
    const t = norm(q);
    return (cupones || []).filter((c) => {
      if (estado !== "todos" && estadoCupon(c, hoy) !== estado) return false;
      return !t || norm(c.codigo + " " + (c.descripcion || "")).includes(t);
    });
  }

  /* ================= REPARTO (HU-16, HU-17) =================
     Los pedidos llegan de reparto_del_dia() (migración 02): solo pagados y solo datos de entrega. */
  const PASO_REPARTO = {
    en_preparacion: { estado: "en_ruta", txt: "En camino" },
    en_ruta:        { estado: "entregado", txt: "Entregado" },
  };
  const accionReparto = (estado) => PASO_REPARTO[estado] || null;

  /* Orden de trabajo: primero lo que va en camino, luego lo por salir (atrasados primero) y
     al final lo entregado; dentro de cada estado, por comuna y calle (ruta). Agrupa por comuna. */
  const PRIORIDAD_REPARTO = { en_ruta: 0, en_preparacion: 1, entregado: 2 };
  function ordenarReparto(lista) {
    return (lista || []).slice().sort((a, b) =>
      (PRIORIDAD_REPARTO[a.estado] ?? 9) - (PRIORIDAD_REPARTO[b.estado] ?? 9) ||
      (b.atrasado === true) - (a.atrasado === true) ||
      norm(a.comuna).localeCompare(norm(b.comuna)) ||
      norm(a.calle).localeCompare(norm(b.calle)) ||
      (Number(a.numero_pedido) || 0) - (Number(b.numero_pedido) || 0));
  }
  function resumenReparto(lista) {
    const r = { porSalir: 0, enRuta: 0, entregados: 0, atrasados: 0, total: 0 };
    for (const p of lista || []) {
      r.total++;
      if (p.estado === "en_preparacion") r.porSalir++;
      else if (p.estado === "en_ruta") r.enRuta++;
      else if (p.estado === "entregado") r.entregados++;
      if (p.atrasado && p.estado !== "entregado") r.atrasados++;
    }
    return r;
  }
  function agruparPorComuna(lista) {
    const grupos = [];
    for (const p of ordenarReparto(lista)) {
      const c = p.comuna || "Sin comuna";
      let g = grupos.find((x) => x.comuna === c);
      if (!g) grupos.push(g = { comuna: c, pedidos: [] });
      g.pedidos.push(p);
    }
    return grupos;
  }
  /* Enlace a Google Maps con la dirección (no se envía nada a Google hasta que el chofer lo abre) */
  function linkMaps(d) {
    if (!d || !String(d.calle || "").trim()) return null;
    const q = [String(d.calle).trim() + " " + String(d.numero || "").trim(), d.comuna, "Chile"].filter(Boolean).join(", ");
    return "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent(q);
  }
  const telLink = (t) => { const d = String(t || "").replace(/\D/g, ""); return /^569\d{8}$/.test(d) ? "tel:+" + d : null; };

  /* ================= EQUIPO Y ROLES (HU-31) =================
     Mismas reglas que asignar_rol() en el servidor (migración 02): la interfaz avisa antes. */
  const ROLES_ASIGNABLES = ["chofer", "admin", "cliente"];
  function validarAsignacion({ yo, persona, rolNuevo, adminsActivos }) {
    if (!persona || !persona.id) return "Busca primero a la persona por su correo.";
    if (persona.id === yo) return "No puedes cambiar tu propio rol.";
    if (!ROLES_ASIGNABLES.includes(rolNuevo)) return "Elige un rol válido.";
    if (persona.rol === rolNuevo) return "La persona ya tiene ese rol.";
    if (persona.rol === "admin" && rolNuevo !== "admin" && (Number(adminsActivos) || 0) <= 1)
      return "Debe quedar al menos un administrador.";
    return null;
  }
  /* Matriz de permisos: filas = permisos, columnas = roles; el admin tiene todos, el cliente ninguno */
  function matrizPermisos(roles, filasRolPermisos, permisos) {
    return (permisos || []).map((p) => ({
      codigo: p.codigo, modulo: p.modulo, descripcion: p.descripcion,
      roles: Object.fromEntries((roles || []).map((r) => [r.id,
        r.id === "admin" || (r.id !== "cliente" && (filasRolPermisos || []).some((f) => f.rol_id === r.id && f.permiso === p.codigo))])),
    }));
  }

  /* ---------- Clientes (HU-23 · RF-19, migración 14) ----------
     Los datos llegan de clientes_resumen(): { id, nombre, email, telefono, comuna, invitado, empresa,
     rol, activo, puntos, pedidos (pagados), gastado, ultimo_pedido, primer_pedido, creado }.
     Umbrales de los segmentos: anotados en pendiente-admin-editable (pasarán a parámetros). */
  const CLIENTES = { frecuenteMin: 3, recuperarDias: 45 };
  const SEGMENTOS_CLIENTE = {
    todos: "Todos", registrados: "Registrados", invitados: "Invitados", empresas: "Empresas",
    frecuentes: "Frecuentes", recuperar: "Por recuperar", bloqueados: "Bloqueados",
  };
  const diasDesde = (iso, hoy = new Date()) =>
    iso ? Math.floor((diaLocalMs(hoy) - diaLocalMs(new Date(iso))) / 864e5) : null;
  function diaLocalMs(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); }

  /* Segmentos a los que pertenece un cliente (un cliente puede estar en varios) */
  function segmentosDe(c, hoy = new Date()) {
    const s = ["todos", c.invitado ? "invitados" : "registrados"];
    if (c.empresa) s.push("empresas");
    if ((Number(c.pedidos) || 0) >= CLIENTES.frecuenteMin) s.push("frecuentes");
    const d = diasDesde(c.ultimo_pedido, hoy);
    if (d != null && d > CLIENTES.recuperarDias) s.push("recuperar");
    if (c.activo === false) s.push("bloqueados");
    return s;
  }
  function contarSegmentos(lista, hoy = new Date()) {
    const n = Object.fromEntries(Object.keys(SEGMENTOS_CLIENTE).map((k) => [k, 0]));
    (lista || []).forEach((c) => segmentosDe(c, hoy).forEach((k) => { n[k]++; }));
    return n;
  }
  /* Búsqueda por nombre, correo, comuna o celular (con o sin +56 9, espacios o guiones) */
  function filtrarClientes(lista, { segmento = "todos", q = "" } = {}, hoy = new Date()) {
    const t = norm(q), dig = String(q || "").replace(/\D/g, "");
    return (lista || []).filter((c) => {
      if (!segmentosDe(c, hoy).includes(segmento)) return false;
      if (!t) return true;
      if (norm([c.nombre, c.email, c.comuna].join(" ")).includes(t)) return true;
      return dig.length >= 4 && String(c.telefono || "").includes(dig);
    });
  }
  /* Indicadores: clientes, compradores, nuevos del mes (primer pedido pagado este mes),
     recurrencia (% de compradores con 2 o más pedidos) y ticket promedio */
  function resumenClientes(lista, hoy = new Date()) {
    const l = lista || [];
    const compradores = l.filter((c) => (Number(c.pedidos) || 0) > 0);
    const pedidos = compradores.reduce((a, c) => a + (Number(c.pedidos) || 0), 0);
    const gastado = compradores.reduce((a, c) => a + (Number(c.gastado) || 0), 0);
    const mes = (iso) => { const d = new Date(iso); return d.getFullYear() === hoy.getFullYear() && d.getMonth() === hoy.getMonth(); };
    return {
      total: l.length,
      compradores: compradores.length,
      nuevosMes: compradores.filter((c) => c.primer_pedido && mes(c.primer_pedido)).length,
      recurrentes: compradores.filter((c) => c.pedidos >= 2).length,
      recurrencia: compradores.length ? Math.round(compradores.filter((c) => c.pedidos >= 2).length * 100 / compradores.length) : 0,
      ticket: pedidos ? Math.round(gastado / pedidos) : 0,
      porRecuperar: l.filter((c) => segmentosDe(c, hoy).includes("recuperar")).length,
    };
  }

  /* Mismas reglas que normalizar_telefono_cl() y es_rut_valido() del servidor (migración 01) */
  function normalizarTelefono(v) {
    const d = String(v || "").replace(/\D/g, "");
    if (/^569\d{8}$/.test(d)) return d;
    if (/^9\d{8}$/.test(d)) return "56" + d;
    if (/^\d{8}$/.test(d)) return "569" + d;
    return null;
  }
  function rutValido(v) {
    const r = String(v || "").toUpperCase().replace(/[^0-9K]/g, "");
    if (r.length < 2) return false;
    const cuerpo = r.slice(0, -1);
    if (!/^\d+$/.test(cuerpo)) return false;
    let suma = 0, mult = 2;
    for (let i = cuerpo.length - 1; i >= 0; i--) { suma += Number(cuerpo[i]) * mult; mult = mult === 7 ? 2 : mult + 1; }
    const resto = 11 - (suma % 11);
    return r.slice(-1) === (resto === 11 ? "0" : resto === 10 ? "K" : String(resto));
  }
  const formatoRut = (v) => {
    const r = String(v || "").toUpperCase().replace(/[^0-9K]/g, "");
    return r.length < 2 ? r : r.slice(0, -1).replace(/\B(?=(\d{3})+(?!\d))/g, ".") + "-" + r.slice(-1);
  };
  /* Valida el formulario "Editar cliente" → { campo: mensaje } (vacío = todo bien) */
  function validarCliente(d) {
    const e = {};
    if (String(d.nombre || "").trim().length < 2) e.nombre = "Escribe al menos 2 letras.";
    if (String(d.telefono || "").trim() && !normalizarTelefono(d.telefono)) e.telefono = "Celular no válido (ej.: 9 1234 5678).";
    if (String(d.rut || "").trim() && !rutValido(d.rut)) e.rut = "RUT no válido.";
    if (d.es_empresa) {
      if (!String(d.rut || "").trim()) e.rut = "La empresa necesita RUT.";
      if (!String(d.razon_social || "").trim()) e.razon_social = "Falta la razón social.";
      if (!String(d.giro || "").trim()) e.giro = "Falta el giro.";
    }
    return e;
  }

  /* ---------- Boletas y facturas (opción A: se emiten en Haulmer, la tienda guarda el PDF) ----------
     Mismas reglas que los documentos de Haulmer: precio con IVA en la boleta, neto con 2 decimales
     en la factura, y neto = total / 1,19 redondeado (ej. $10.000 → neto $8.403 + IVA $1.597). */
  const PAGADOS_DTE = ["pagado", "en_preparacion", "en_ruta", "entregado"];
  const montosDTE = (total) => {
    const t = Math.round(Number(total) || 0), neto = Math.round(t / 1.19);
    return { neto, iva: t - neto, total: t };
  };
  const netoUnitario = (bruto) => Math.round((Number(bruto) || 0) / 1.19 * 100) / 100;   // 2500 → 2100.84
  const fmtCLP = (n, dec = 0) => "$" + Number(n || 0).toLocaleString("es-CL", { minimumFractionDigits: dec, maximumFractionDigits: dec });
  // Valor para pegar en Haulmer (sin "$" ni separador de miles; decimales con coma)
  const valorPegar = (n, dec = 0) => Number(n || 0).toFixed(dec).replace(".", ",");

  // Documento emitido del pedido (o null)
  const documentoDe = (p) => ((p && p.documentos_tributarios) || []).find((d) => d.estado === "emitido") || null;
  // ¿Falta emitir la boleta/factura? Solo pedidos pagados con monto (un canje de $0 no lleva documento)
  /* Envío por correo del documento (migración 20) → { estado: "enviado" | "error" | "pendiente", texto } */
  function estadoCorreoDoc(doc) {
    if (!doc) return { estado: "pendiente", texto: "" };
    if (doc.correo_enviado_at) {
      const f = new Date(doc.correo_enviado_at).toLocaleString("es-CL", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
      return { estado: "enviado", texto: `Enviada por correo${doc.correo_destino ? " a " + doc.correo_destino : ""} el ${f}` +
               (doc.correo_error ? ` · El último reenvío falló (${doc.correo_error}).` : "") };
    }
    if (doc.correo_error) return { estado: "error", texto: `No se pudo enviar por correo (${doc.correo_error}).` };
    return { estado: "pendiente", texto: "Aún no se envía por correo al cliente." };
  }

  const pendienteDocumento = (p) => !!p && PAGADOS_DTE.includes(p.estado) && (Number(p.total) || 0) > 0 && !documentoDe(p);

  /* Datos para copiar en el formulario de Haulmer, en su mismo orden. p = pedido como lo trae getPedido(). */
  function datosHaulmer(p) {
    const tipo = p.tipo_documento === "factura" ? "factura" : "boleta", factura = tipo === "factura";
    const lineas = (p.detalle_pedido || []).map((d) => {
      const v = d.variante || {}, pr = v.producto || {};
      const nombre = (pr.nombre || "Producto") + (v.nombre && v.nombre !== "Estándar" ? " (" + v.nombre + ")" : "");
      const precio = factura ? netoUnitario(d.precio_unitario) : Math.round(Number(d.precio_unitario) || 0);
      return { codigo: v.sku || "", nombre, cantidad: Number(d.cantidad) || 0, precio, dec: factura ? 2 : 0 };
    });
    if ((Number(p.costo_despacho) || 0) > 0) {
      const precio = factura ? netoUnitario(p.costo_despacho) : Number(p.costo_despacho);
      lineas.push({ codigo: "DESPACHO", nombre: "Despacho a domicilio", cantidad: 1, precio, dec: factura ? 2 : 0 });
    }
    const dir = p.direccion || {};
    return {
      tipo, codigoSII: factura ? 33 : 39, lineas,
      descuento: Number(p.descuento_cupon) || 0,
      formaPago: "Contado",
      receptor: factura ? {
        rut: formatoRut(p.doc_rut), razon_social: p.doc_razon_social || "", giro: p.doc_giro || "",
        direccion: [dir.calle, dir.numero].filter(Boolean).join(" ") + (dir.depto ? ", " + dir.depto : ""),
        comuna: dir.comuna || "", email: p.contacto_email || "",
      } : null,
      montos: montosDTE(p.total),
    };
  }

  /* Tipo y folio desde el nombre del PDF que descarga Haulmer:
     "DTE_39-_Empresa_77861415_-_Folio_N__11298.pdf" → { tipo: "boleta", folio: 11298 } */
  function leerNombreDTE(nombre) {
    // Haulmer usa dos formatos: "DTE_39-_Empresa_…_-_Folio_N__11298.pdf" y "DTE 39 - Empresa … - Folio N° 11300.pdf"
    // (a veces sin el código del tipo: entonces tipo = null y se usa el que pidió el cliente)
    const n = String(nombre || "");
    const f = n.match(/Folio[\s_]*N(?:°|º|o|_|\.|\s)*(\d+)/i);
    if (!f || !/DTE/i.test(n)) return null;
    const t = n.match(/DTE[\s_-]*(33|39)(?!\d)/i);
    return { tipo: t ? (t[1] === "33" ? "factura" : "boleta") : null, folio: Number(f[1]) };
  }
  /* Valida lo que se va a subir. archivo = { name, type, size }. Devuelve un mensaje de error o "". */
  function validarDocumento(archivo, tipoPedido, folio) {
    if (!archivo) return "Elige el PDF del documento.";
    if (archivo.type !== "application/pdf" && !/\.pdf$/i.test(archivo.name || "")) return "El archivo debe ser un PDF.";
    if ((archivo.size || 0) > 3 * 1024 * 1024) return "El PDF pesa más de 3 MB.";
    if (!Number.isInteger(folio) || folio <= 0) return "Escribe el número de folio.";
    const leido = leerNombreDTE(archivo.name);
    if (leido && leido.tipo && leido.tipo !== tipoPedido) return `Ese PDF es una ${leido.tipo} y el cliente pidió ${tipoPedido}.`;
    return "";
  }

  /* ================= PEDIDOS FUERA DE LA PÁGINA (migración 21) =================
     WhatsApp, llamada o presencial; se pagan en efectivo, tarjeta presencial o transferencia.
     Los registra el chofer o el admin y entran a la misma ruta de reparto que los de la web. */
  const CANALES = { web: "Página web", whatsapp: "WhatsApp", llamada: "Llamada", presencial: "Presencial", otro: "Otro" };
  const CANALES_MANUALES = ["whatsapp", "llamada", "presencial", "otro"];
  const METODOS_PAGO = { mercado_pago: "Mercado Pago", efectivo: "Efectivo", tarjeta: "Tarjeta", transferencia: "Transferencia" };
  const METODOS_MANUALES = ["efectivo", "tarjeta", "transferencia"];
  function esFueraPagina(p) { return !!p && !!p.canal && p.canal !== "web"; }
  const etiquetaCanal = (c) => CANALES[c] || CANALES.web;
  /* "Por cobrar · efectivo" / "Pagado · transferencia" ("" para la web) */
  function textoCobro(p) {
    if (!esFueraPagina(p)) return "";
    const m = METODOS_PAGO[p.metodo_pago];
    return (p.cobro_estado === "por_cobrar" ? "Por cobrar" : "Pagado") + (m ? " · " + m.toLowerCase() : "");
  }

  /* Totales del formulario, con las MISMAS reglas que registrar_pedido_manual() (el servidor recalcula todo):
     precio de venta del catálogo, despacho de la comuna, gratis desde el mínimo, descuento hasta el total. */
  function calcularPedidoManual(lineas, opciones, comuna, descuento) {
    const prods = (opciones && opciones.productos) || [];
    let subtotal = 0, unidades = 0;
    for (const l of lineas || []) {
      const p = prods.find((x) => x.variante_id === l.variante_id);
      const c = Math.trunc(Number(l.cantidad) || 0);
      if (p && c > 0) { subtotal += (Number(p.precio) || 0) * c; unidades += c; }
    }
    const com = ((opciones && opciones.comunas) || []).find((x) => norm(x.comuna) === norm(comuna));
    let despacho = com ? Number(com.costo_despacho) || 0 : 0;
    const gratis = opciones && opciones.envio_gratis_minimo;
    if (despacho > 0 && gratis != null && subtotal >= gratis) despacho = 0;
    const desc = Math.max(0, Math.trunc(Number(descuento) || 0));
    return { subtotal, despacho, descuento: desc, total: Math.max(subtotal + despacho - desc, 0), unidades, conComuna: !!com };
  }

  /* Valida el formulario "Pedido fuera de la página" → { campo: mensaje } (vacío = todo bien) */
  function validarPedidoManual(d, opciones, hoy = new Date()) {
    const e = {};
    if (!CANALES_MANUALES.includes(d.canal)) e.canal = "Elige cómo llegó el pedido.";
    if (String(d.nombre || "").trim().length < 2) e.nombre = "Escribe el nombre del cliente.";
    if (!normalizarTelefono(d.telefono)) e.telefono = "Celular no válido (ej.: 9 1234 5678).";
    if (String(d.email || "").trim() && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(d.email).trim())) e.email = "Correo no válido (puedes dejarlo vacío).";
    const t = calcularPedidoManual(d.lineas, opciones, d.comuna, d.descuento);
    if (!t.conComuna) e.comuna = "Elige una comuna con despacho.";
    if (!String(d.calle || "").trim()) e.calle = "Falta la calle.";
    if (!t.unidades) e.lineas = "Agrega al menos un producto.";
    else if ((d.lineas || []).some((l) => Number(l.cantidad) > 200)) e.lineas = "Máximo 200 unidades por producto.";
    const dHoy = diaLocal(hoy);
    if (!ES_DIA.test(d.fecha || "") || d.fecha < dHoy || d.fecha > sumarDias(dHoy, 45)) e.fecha = "La fecha debe ser desde hoy y hasta 45 días.";
    if (!METODOS_MANUALES.includes(d.metodo)) e.metodo = "Elige el medio de pago.";
    if (!["pagado", "por_cobrar"].includes(d.cobro)) e.cobro = "Indica si ya pagó o se cobra al entregar.";
    const desc = Number(d.descuento || 0);
    if (!Number.isInteger(desc) || desc < 0) e.descuento = "El descuento debe ser un número entero.";
    else if (desc > t.subtotal + t.despacho) e.descuento = "El descuento no puede ser mayor que el total.";
    else if (desc > 0 && String(d.motivo || "").trim().length < 3) e.motivo = "Indica el motivo del descuento.";
    if (d.documento === "factura") {
      if (!rutValido(d.rut)) e.rut = "RUT no válido.";
      if (!String(d.razon_social || "").trim()) e.razon_social = "Falta la razón social.";
      if (!String(d.giro || "").trim()) e.giro = "Falta el giro.";
    }
    return e;
  }

  /* Entregados del día para el resumen del chofer: cuánto se vendió, por medio de pago, el efectivo
     que debe rendir y lo que quedó por cobrar. Los de la web se pagaron con Mercado Pago. */
  function resumenEntregas(lista) {
    const r = { entregados: 0, monto: 0, fueraPagina: 0, efectivoARendir: 0,
                porMetodo: { mercado_pago: 0, efectivo: 0, tarjeta: 0, transferencia: 0 },
                porCobrar: { cantidad: 0, monto: 0 } };
    for (const p of lista || []) {
      if (!p || p.estado !== "entregado") continue;
      const t = Number(p.total) || 0;
      r.entregados++; r.monto += t;
      if (esFueraPagina(p)) r.fueraPagina++;
      if (esFueraPagina(p) && p.cobro_estado === "por_cobrar") { r.porCobrar.cantidad++; r.porCobrar.monto += t; continue; }
      const m = esFueraPagina(p) ? p.metodo_pago : "mercado_pago";
      if (r.porMetodo[m] != null) r.porMetodo[m] += t;
    }
    r.efectivoARendir = r.porMetodo.efectivo;
    return r;
  }

  root.AdminLogic = {
    PERMISOS, permisosDe, puede, SECCIONES, seccionesVisibles,
    ESTADOS, ORDEN_ESTADOS, etiquetaEstado, norm,
    TRANSICIONES, siguientesEstados, puedeCambiar, ACCION_ESTADO,
    filtrarPedidos, contarPorEstado, resumenPedidos, diaLocal, OPCIONES_ENTREGA, rangoEntrega, enRangoEntrega, siguienteHabil, textoRango, linkWhatsApp, telefonoVisible,
    parsePrecio, normalizarSku, slugDe, validarProducto, pedidosNuevos, validarVariante, filtrarCatalogo,
    UMBRAL_DEFECTO, umbralStock, nivelStock, NIVELES_STOCK, parseStock, sumarStock, resumenStock, filtrarInventario,
    normalizarCodigo, enteroOpcional, estadoCupon, ESTADOS_CUPON, textoDescuento, condicionesCupon, validarCupon, filaCupon, filtrarCupones,
    accionReparto, ordenarReparto, resumenReparto, agruparPorComuna, linkMaps, telLink,
    ROLES_ASIGNABLES, validarAsignacion, matrizPermisos,
    CLIENTES, SEGMENTOS_CLIENTE, diasDesde, segmentosDe, contarSegmentos, filtrarClientes, resumenClientes,
    normalizarTelefono, rutValido, formatoRut, validarCliente,
    CANALES, CANALES_MANUALES, METODOS_PAGO, METODOS_MANUALES, esFueraPagina, etiquetaCanal, textoCobro,
    calcularPedidoManual, validarPedidoManual, resumenEntregas,
    montosDTE, netoUnitario, fmtCLP, valorPegar, documentoDe, pendienteDocumento, estadoCorreoDoc, datosHaulmer, leerNombreDTE, validarDocumento,
  };
})(typeof window !== "undefined" ? window : globalThis);
