/* =====================================================================
   admin-data.js — Datos del panel de administración (Supabase)
   ---------------------------------------------------------------------
   Extiende el "puente" de data.js con Befine.admin. La interfaz del panel
   (admin.js) solo habla con estos métodos, igual que la tienda con Befine.
   Requiere: supabase-js → data.js → admin-logic.js → este archivo.

   Seguridad: usa la misma clave pública que la tienda. Lo que un usuario
   puede leer o modificar lo decide el RLS de Supabase según su rol y
   permisos (tiene_permiso(), migración 01). Si alguien abre admin.html sin
   permisos, la interfaz no muestra nada y la base rechaza cualquier cambio.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;

  /* Errores de Supabase/PostgREST → mensaje claro para el dueño */
  function msgAdmin(e) {
    const m = String((e && (e.message || e.details)) || e || "");
    const low = m.toLowerCase();
    if (e && e.code === "42501" || low.includes("row-level security") || low.includes("permission denied"))
      return "No tienes permiso para hacer este cambio.";
    if (e && e.code === "23505" || low.includes("duplicate key")) return "Ya existe un registro con ese valor (revisa el SKU o el nombre).";
    if (e && e.code === "23514" || low.includes("check constraint")) return "Algún valor no es válido (revisa números negativos o vacíos).";
    if (low.includes("failed to fetch") || low.includes("network")) return "Sin conexión. Revisa tu internet e inténtalo de nuevo.";
    if (low.includes("jwt") && low.includes("expired")) return "Tu sesión expiró. Vuelve a ingresar.";
    return "No pudimos guardar el cambio. Inténtalo de nuevo.";
  }

  Befine.admin = {
    msg: msgAdmin,

    /* Quién está usando el panel → { usuario, perfil:{id,nombre,rol,activo}, permisos[] }
       usuario = null si no hay sesión (o es un invitado anónimo). */
    async contexto() {
      const { data } = await sb.auth.getSession();
      const u = data && data.session && data.session.user;
      if (!u || u.is_anonymous) return { usuario: null, perfil: null, permisos: [] };
      const { data: pf } = await sb.from("perfiles").select("id,nombre,apellido,rol,activo").eq("id", u.id).maybeSingle();
      if (!pf || !pf.activo) return { usuario: u, perfil: pf || null, permisos: [] };
      let filas = [];
      if (pf.rol !== "admin" && pf.rol !== "cliente") {
        const { data: rp } = await sb.from("rol_permisos").select("rol_id,permiso").eq("rol_id", pf.rol);
        filas = rp || [];
      }
      return { usuario: u, perfil: pf, permisos: L.permisosDe(pf.rol, filas) };
    },

    /* Nombre visible del rol (tabla roles) */
    async nombreRol(rol) {
      const { data } = await sb.from("roles").select("nombre").eq("id", rol).maybeSingle();
      return (data && data.nombre) || rol;
    },

    /* ================= PEDIDOS (RF-16) ================= */
    /* Pedidos de los últimos `dias` (RLS: requiere pedidos.ver). La dirección llega por la
       política direcciones_reparto. Se limita a 500 para que el panel cargue rápido. */
    async listPedidos({ dias = 90 } = {}) {
      const desde = new Date(Date.now() - dias * 864e5).toISOString();
      const { data, error } = await sb.from("pedidos")
        .select("id,numero,estado,total,subtotal,costo_despacho,descuento_cupon,created_at,fecha_entrega," +
                "contacto_nombre,contacto_telefono,contacto_email,tipo_documento," +
                "direccion:direcciones(calle,numero,depto,comuna,referencia),detalle_pedido(cantidad)")
        .gte("created_at", desde)
        .order("created_at", { ascending: false })
        .limit(500);
      if (error) throw error;
      return (data || []).map((p) => ({
        ...p,
        unidades: (p.detalle_pedido || []).reduce((n, d) => n + (d.cantidad || 0), 0),
      }));
    },

    /* Detalle completo de un pedido: productos, historial de estados y cupón */
    async getPedido(id) {
      const { data, error } = await sb.from("pedidos")
        .select("*,direccion:direcciones(calle,numero,depto,comuna,referencia)," +
                "zona:zonas_despacho(nombre),cupon:cupones(codigo)," +
                "detalle_pedido(cantidad,precio_unitario,subtotal,variante:variantes_producto(sku,nombre,producto:productos(nombre)))," +
                "historial_pedido(estado_anterior,estado_nuevo,nota,created_at)")
        .eq("id", id)
        .maybeSingle();
      if (error) throw error;
      if (data && data.historial_pedido) data.historial_pedido.sort((a, b) => a.created_at.localeCompare(b.created_at));
      return data;
    },

    /* Cambia el estado si el flujo lo permite. Se exige que el pedido siga en el estado
       que vio el usuario (.eq estado actual): si otra persona lo cambió antes, no se pisa.
       El trigger de la base registra el cambio en historial_pedido con quién y cuándo. */
    async cambiarEstado(id, actual, nuevo) {
      if (!L.puedeCambiar(actual, nuevo)) return { ok: false, error: "Ese cambio de estado no está permitido." };
      const { data, error } = await sb.from("pedidos")
        .update({ estado: nuevo }).eq("id", id).eq("estado", actual).select("id,estado");
      if (error) return { ok: false, error: msgAdmin(error) };
      if (!data || !data.length) return { ok: false, error: "No se aplicó: el pedido cambió mientras lo revisabas o no tienes permiso. Se recargó con su estado actual.", recargar: true };
      return { ok: true, estado: data[0].estado };
    },
  };
})();
