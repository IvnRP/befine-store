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

  root.AdminLogic = {
    PERMISOS, permisosDe, puede, SECCIONES, seccionesVisibles,
    ESTADOS, ORDEN_ESTADOS, etiquetaEstado, norm,
    TRANSICIONES, siguientesEstados, puedeCambiar, ACCION_ESTADO,
    filtrarPedidos, contarPorEstado, resumenPedidos, diaLocal, linkWhatsApp, telefonoVisible,
  };
})(typeof window !== "undefined" ? window : globalThis);
