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

    /* ================= CATÁLOGO Y PRECIOS (RF-17) ================= */
    async listCategorias() {
      const { data, error } = await sb.from("categorias").select("id,nombre,slug").order("id");
      if (error) throw error;
      return data || [];
    },

    /* Todos los productos, también los ocultos (RLS: los inactivos solo los ve quien tiene
       catalogo.gestionar). Cada variante trae su precio de venta (nivel retail). */
    async listCatalogo() {
      const nivel = await _nivelRetail();
      const { data, error } = await sb.from("productos")
        .select("id,categoria_id,nombre,descripcion,imagen_url,activo,created_at,categorias(nombre)," +
                "variantes_producto(id,producto_id,sku,nombre,stock,controla_stock,activo,precios_variante(nivel_precio_id,precio))")
        .order("created_at", { ascending: true });
      if (error) throw error;
      return (data || []).map((p) => ({
        id: p.id, categoria_id: p.categoria_id, categoria: (p.categorias && p.categorias.nombre) || "Sin categoría",
        nombre: p.nombre, descripcion: p.descripcion, imagen_url: p.imagen_url, activo: p.activo,
        variantes: (p.variantes_producto || [])
          .sort((a, b) => (a.sku || "").localeCompare(b.sku || ""))
          .map((v) => {
            const pr = (v.precios_variante || []).find((x) => x.nivel_precio_id === nivel);
            return { id: v.id, producto_id: v.producto_id, sku: v.sku, nombre: v.nombre, stock: v.stock,
              controla_stock: v.controla_stock, activo: v.activo, precio: pr ? pr.precio : null };
          }),
      }));
    },

    /* Crea o edita un producto. Solo se envían columnas propias de la tabla. */
    async guardarProducto(p) {
      const fila = {
        nombre: String(p.nombre || "").trim(),
        descripcion: String(p.descripcion || "").trim() || null,
        categoria_id: Number(p.categoria_id) || null,
        imagen_url: String(p.imagen_url || "").trim() || null,
        activo: !!p.activo,
      };
      const q = p.id
        ? sb.from("productos").update(fila).eq("id", p.id).select("id")
        : sb.from("productos").insert(fila).select("id");
      const { data, error } = await q;
      if (error) return { ok: false, error: msgAdmin(error) };
      if (!data || !data.length) return { ok: false, error: "No se guardó: revisa que tengas permiso para editar el catálogo." };
      return { ok: true, id: data[0].id };
    },

    /* Crea o edita una variante. El stock inicial solo se fija al crearla
       (después se ajusta desde Inventario). */
    async guardarVariante(v) {
      const fila = {
        sku: L.normalizarSku(v.sku),
        nombre: String(v.nombre || "").trim(),
        activo: !!v.activo,
        controla_stock: !!v.controla_stock,
      };
      let q;
      if (v.id) q = sb.from("variantes_producto").update(fila).eq("id", v.id).select("id");
      else q = sb.from("variantes_producto").insert({ ...fila, producto_id: v.producto_id, stock: Math.max(0, parseInt(v.stock, 10) || 0) }).select("id");
      const { data, error } = await q;
      if (error) return { ok: false, error: msgAdmin(error) };
      if (!data || !data.length) return { ok: false, error: "No se guardó: revisa que tengas permiso para editar el catálogo." };
      return { ok: true, id: data[0].id };
    },

    /* Precio de venta (nivel retail) de una variante: crea o reemplaza (RLS: precios.gestionar).
       crear_pedido() toma el precio desde aquí, así que el cambio rige desde el próximo pedido. */
    async guardarPrecio(varianteId, precio) {
      const n = L.parsePrecio(precio);
      if (n === null) return { ok: false, error: "Escribe un precio válido en pesos, sin decimales." };
      const nivel = await _nivelRetail();
      const { data, error } = await sb.from("precios_variante")
        .upsert({ variante_id: varianteId, nivel_precio_id: nivel, precio: n }, { onConflict: "variante_id,nivel_precio_id" })
        .select("precio");
      if (error) return { ok: false, error: msgAdmin(error) };
      if (!data || !data.length) return { ok: false, error: "No se guardó: revisa que tengas permiso para editar precios." };
      return { ok: true, precio: n };
    },

    /* Producto nuevo con su primera variante y precio. Se crea OCULTO y se publica al final,
       para que la tienda nunca muestre un producto a medio crear (sin variante o sin precio). */
    async crearProductoCompleto(p, v) {
      const r1 = await this.guardarProducto({ ...p, activo: false });
      if (!r1.ok) return r1;
      const r2 = await this.guardarVariante({ ...v, producto_id: r1.id, activo: true });
      if (!r2.ok) return { ...r2, error: r2.error + " El producto quedó oculto: complétalo desde Editar.", id: r1.id };
      const r3 = await this.guardarPrecio(r2.id, v.precio);
      if (!r3.ok) return { ...r3, error: r3.error + " El producto quedó oculto: revisa el precio.", id: r1.id };
      if (p.activo) {
        const r4 = await this.guardarProducto({ ...p, id: r1.id, activo: true });
        if (!r4.ok) return r4;
      }
      return { ok: true, id: r1.id };
    },
  };
})();
