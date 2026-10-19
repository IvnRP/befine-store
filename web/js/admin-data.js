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
  };
})();
