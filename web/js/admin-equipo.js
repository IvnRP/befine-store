/* =====================================================================
   admin-equipo.js — Sección "Equipo y roles" del panel (HU-31, solo admin)
   ---------------------------------------------------------------------
   - Lista del equipo (personas con un rol distinto de cliente).
   - Agregar a alguien por su correo (debe haber creado su cuenta en la
     tienda) y asignarle chofer, administrador o cliente.
   - Tabla de permisos de cada rol (solo lectura).
   Todo pasa por funciones del servidor (migración 02): equipo(),
   buscar_usuario() y asignar_rol(), que exigen ser administrador, impiden
   cambiar el propio rol, nunca dejan la tienda sin administrador y
   registran cada cambio en cambios_rol. La interfaz avisa lo mismo antes.
   ===================================================================== */
(function () {
  const L = window.AdminLogic;
  const { esc, ICONOS, UI } = window.AdminApp;
  const A = () => Befine.admin;

  let el, app, equipo = [], catalogo = null, encontrada = null, cargado = false;
  const NOMBRE_ROL = { admin: "Administrador", chofer: "Chofer", cliente: "Cliente" };
  const nombreRol = (r) => (catalogo && (catalogo.roles.find((x) => x.id === r) || {}).nombre) || NOMBRE_ROL[r] || r;
  const yo = () => app && app.ctx && app.ctx.perfil && app.ctx.perfil.id;
  const adminsActivos = () => equipo.filter((p) => p.rol === "admin" && p.activo).length;
  const opciones = (actual) => L.ROLES_ASIGNABLES.map((r) =>
    `<option value="${r}"${r === actual ? " selected" : ""}>${esc(nombreRol(r))}</option>`).join("");

  function montar(seccion, appCtx) {
    el = seccion; app = appCtx;
    el.innerHTML = `
      <div class="pn-head">
        <div><h1>Equipo y roles</h1><p>Quién entra al panel y qué puede hacer. Solo el administrador asigna roles.</p></div>
        <div class="acciones"><button class="pn-btn ghost" type="button" id="eqRecargar">${ICONOS.recargar}<span>Actualizar</span></button></div>
      </div>
      <div class="pn-card eq-bloque">
        <h2>Agregar a alguien</h2>
        <p class="eq-ayuda">La persona primero crea su cuenta en la tienda (Mi cuenta → Crear cuenta o con Google). Luego búscala por su correo.</p>
        <form class="eq-buscar" id="eqForm" novalidate>
          <input class="pn-inp" id="eqEmail" type="email" placeholder="correo@ejemplo.cl" aria-label="Correo de la persona" autocomplete="off">
          <button class="pn-btn" type="submit" id="eqBuscarBtn">${ICONOS.buscar}<span>Buscar</span></button>
        </form>
        <div id="eqResultado" aria-live="polite"></div>
      </div>
      <div class="pn-card eq-bloque"><h2>Equipo</h2><div id="eqLista"><div class="pn-vacio"><span class="pn-spin"></span></div></div></div>
      <div class="pn-card eq-bloque"><h2>Permisos de cada rol</h2><div id="eqMatriz"></div></div>`;

    el.querySelector("#eqRecargar").addEventListener("click", (e) => UI.conCarga(e.currentTarget, cargar));
    el.querySelector("#eqForm").addEventListener("submit", (e) => { e.preventDefault(); buscar(); });
    el.addEventListener("click", (e) => {
      const b = e.target.closest("[data-asignar]"); if (!b) return;
      const sel = el.querySelector(`select[data-para="${b.dataset.asignar}"]`);
      asignar(b, b.dataset.asignar, sel && sel.value);
    });
  }

  async function mostrar() { if (!cargado) await cargar(); }

  async function cargar() {
    try {
      [equipo, catalogo] = await Promise.all([A().equipo(), catalogo || A().listRoles()]);
      cargado = true; pintarEquipo(); pintarMatriz();
    } catch (e) {
      el.querySelector("#eqLista").innerHTML = `<div class="pn-vacio">No pudimos cargar el equipo. ${esc(A().msg(e))}</div>`;
      UI.toast(A().msg(e), "mal");
    }
  }

  function filaPersona(p, conEmail) {
    const soyYo = p.id === yo();
    return `<div class="eq-persona">
      <div><b>${esc(p.nombre || "Sin nombre")}${soyYo ? " <small>(tú)</small>" : ""}</b><small>${conEmail ? esc(p.email || "") : ""}</small></div>
      <span class="pn-est ${p.rol === "admin" ? "info" : p.rol === "chofer" ? "ruta" : "fin"}">${esc(nombreRol(p.rol))}</span>
      ${soyYo ? `<small class="eq-nota">No puedes cambiar tu propio rol</small>` : `
        <select class="pn-inp" data-para="${esc(p.id)}" aria-label="Nuevo rol para ${esc(p.nombre || p.email)}">${opciones(p.rol)}</select>
        <button type="button" class="pn-btn sm" data-asignar="${esc(p.id)}">Guardar</button>`}
    </div>`;
  }

  function pintarEquipo() {
    el.querySelector("#eqLista").innerHTML = equipo.length
      ? equipo.map((p) => filaPersona(p, true)).join("")
      : `<div class="pn-vacio">Aún no hay nadie en el equipo.</div>`;
  }

  function pintarMatriz() {
    const roles = catalogo.roles.filter((r) => r.id !== "cliente");
    const filas = L.matrizPermisos(roles, catalogo.rolPermisos, catalogo.permisos);
    el.querySelector("#eqMatriz").innerHTML = `
      <div class="eq-tabla-wrap"><table class="pn-tabla eq-matriz">
        <thead><tr><th>Permiso</th>${roles.map((r) => `<th>${esc(r.nombre)}</th>`).join("")}</tr></thead>
        <tbody>${filas.map((f) => `<tr><td><b>${esc(f.modulo)}</b><small>${esc(f.descripcion)}</small></td>
          ${roles.map((r) => `<td class="c">${f.roles[r.id] ? '<span class="eq-si" aria-label="Sí">✓</span>' : '<span class="eq-no" aria-label="No">—</span>'}</td>`).join("")}</tr>`).join("")}
        </tbody></table></div>
      <p class="eq-ayuda">El administrador tiene todos los permisos. Crear roles nuevos queda para después del Go-Live (SC-06).</p>`;
  }

  async function buscar() {
    const email = el.querySelector("#eqEmail").value.trim().toLowerCase();
    const out = el.querySelector("#eqResultado");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { out.innerHTML = `<p class="eq-msg mal">Escribe un correo válido.</p>`; return; }
    const r = await UI.conCarga(el.querySelector("#eqBuscarBtn"), () => A().buscarUsuario(email));
    if (!r.ok) { out.innerHTML = `<p class="eq-msg mal">${esc(r.error)}</p>`; return; }
    encontrada = r.persona;
    out.innerHTML = encontrada
      ? `<div class="eq-encontrada">${filaPersona(encontrada, true)}</div>`
      : `<p class="eq-msg mal">No hay una cuenta con ese correo. Pídele que la cree en la tienda y vuelve a buscar.</p>`;
  }

  async function asignar(btn, id, rol) {
    const persona = equipo.find((p) => p.id === id) || (encontrada && encontrada.id === id ? encontrada : null);
    const err = L.validarAsignacion({ yo: yo(), persona, rolNuevo: rol, adminsActivos: adminsActivos() });
    if (err) return UI.toast(err, "mal");
    const ok = await UI.confirmar(`¿Asignar el rol ${nombreRol(rol)}?`,
      `${persona.nombre || persona.email} pasará de ${nombreRol(persona.rol)} a ${nombreRol(rol)}. El cambio rige desde su próximo ingreso al panel y queda registrado.`,
      "Asignar rol", rol === "admin");
    if (!ok) return;
    const r = await UI.conCarga(btn, () => A().asignarRol(id, rol));
    if (!r.ok) return UI.toast(r.error, "mal");
    UI.toast(`Listo: ${persona.nombre || persona.email} ahora es ${nombreRol(rol)}.`);
    encontrada = null; el.querySelector("#eqResultado").innerHTML = ""; el.querySelector("#eqEmail").value = "";
    cargar();
  }

  window.AdminApp.SECCIONES.equipo = { montar, mostrar };
})();
