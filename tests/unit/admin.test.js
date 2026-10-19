/* Pruebas de las reglas del panel de administración (web/js/admin-logic.js)
   Casos CP-U14 (acceso por rol) del Plan de Pruebas. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
const arr = (x) => Array.from(x);   // los arreglos vienen del contexto aislado

test("CP-U14a el admin tiene todos los permisos y el cliente ninguno", () => {
  assert.equal(L.permisosDe("admin", []).length, 12);
  assert.deepEqual(arr(L.permisosDe("cliente", [{ rol_id: "cliente", permiso: "pedidos.ver" }])), []);
  assert.deepEqual(arr(L.permisosDe(null, [])), []);
});

test("CP-U14b un rol del equipo solo tiene los permisos que el admin le asignó", () => {
  const filas = [
    { rol_id: "chofer", permiso: "pedidos.ver" },
    { rol_id: "chofer", permiso: "pedidos.ver" },          // duplicado: se cuenta una vez
    { rol_id: "bodega", permiso: "catalogo.gestionar" },   // otro rol: no aplica
  ];
  assert.deepEqual(arr(L.permisosDe("chofer", filas)), ["pedidos.ver"]);
});

test("CP-U14c el panel muestra solo las secciones permitidas", () => {
  const ids = (p) => arr(L.seccionesVisibles(p)).map((s) => s.id);
  assert.ok(ids(L.permisosDe("admin", [])).includes("pedidos"));
  assert.deepEqual(ids(["pedidos.ver"]), ["pedidos"]);
  assert.deepEqual(ids([]), []);                       // cliente: sin acceso al panel
});
