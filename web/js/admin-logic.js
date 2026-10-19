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

  root.AdminLogic = {
    PERMISOS, permisosDe, puede, SECCIONES, seccionesVisibles,
    ESTADOS, ORDEN_ESTADOS, etiquetaEstado, norm,
  };
})(typeof window !== "undefined" ? window : globalThis);
