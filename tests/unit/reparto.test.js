/* Pruebas del reparto del chofer y de la asignación de roles (web/js/admin-logic.js) — 6 pruebas
   Casos CP-U29 del Plan de Pruebas (HU-16, HU-17, HU-31 · migración 02). */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
const arr = (x) => Array.from(x);
const ped = (o) => ({ id: "p" + o.numero_pedido, comuna: "Quilicura", calle: "A", estado: "en_preparacion", atrasado: false, ...o });

test("CP-U29a el chofer ve solo Reparto; Equipo y roles es solo del administrador", () => {
  const ids = (p, rol) => arr(L.seccionesVisibles(p, rol)).map((s) => s.id);
  assert.deepEqual(ids(["pedidos.repartir"], "chofer"), ["reparto"]);
  assert.deepEqual(ids(L.permisosDe("admin", []), "admin"), ["pedidos", "reparto", "clientes", "catalogo", "inventario", "cupones", "equipo"]);
  assert.ok(!ids(L.PERMISOS.slice(), "operador").includes("equipo"));   // tener todos los permisos no basta: es solo del rol admin
  assert.deepEqual(ids([], "cliente"), []);
});

test("CP-U29b el chofer solo avanza En preparación → En camino → Entregado", () => {
  assert.deepEqual({ ...L.accionReparto("en_preparacion") }, { estado: "en_ruta", txt: "En camino" });
  assert.deepEqual({ ...L.accionReparto("en_ruta") }, { estado: "entregado", txt: "Entregado" });
  for (const e of ["entregado", "pendiente_pago", "pagado", "cancelado", undefined]) assert.equal(L.accionReparto(e), null, e);
});

test("CP-U29c orden de ruta: en camino, por salir (atrasados primero) y entregados; agrupado por comuna", () => {
  const lista = [
    ped({ numero_pedido: 1, estado: "entregado", comuna: "Quilicura" }),
    ped({ numero_pedido: 2, comuna: "Recoleta", calle: "B" }),
    ped({ numero_pedido: 3, estado: "en_ruta", comuna: "Recoleta" }),
    ped({ numero_pedido: 4, comuna: "Huechuraba", atrasado: true }),
    ped({ numero_pedido: 5, comuna: "Huechuraba" }),
  ];
  assert.deepEqual(arr(L.ordenarReparto(lista)).map((p) => p.numero_pedido), [3, 4, 5, 2, 1]);
  assert.deepEqual(arr(L.agruparPorComuna(lista)).map((g) => g.comuna), ["Recoleta", "Huechuraba", "Quilicura"]);
  assert.deepEqual({ ...L.resumenReparto(lista) }, { porSalir: 3, enRuta: 1, entregados: 1, atrasados: 1, total: 5 });
});

test("CP-U29d enlaces del chofer: WhatsApp y llamar solo con celular válido; Maps con la dirección", () => {
  assert.equal(L.linkWhatsApp("56955556666", "Hola #12"), "https://wa.me/56955556666?text=Hola%20%2312");
  assert.equal(L.linkWhatsApp("12345", "x"), null);
  assert.equal(L.telLink("+56 9 5555 6666"), "tel:+56955556666");
  assert.equal(L.telLink(""), null);
  assert.equal(L.linkMaps({ calle: "Los Tailandeses", numero: "1156", comuna: "Quilicura" }),
    "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent("Los Tailandeses 1156, Quilicura, Chile"));
  assert.equal(L.linkMaps({ calle: " " }), null);
});

test("CP-U29e asignar roles: nadie cambia el suyo y nunca queda la tienda sin administrador", () => {
  const v = (persona, rolNuevo, adminsActivos = 2) => L.validarAsignacion({ yo: "yo", persona, rolNuevo, adminsActivos });
  assert.equal(v({ id: "x", rol: "cliente" }, "chofer"), null);
  assert.match(v({ id: "yo", rol: "admin" }, "cliente"), /propio rol/);
  assert.match(v({ id: "x", rol: "admin" }, "chofer", 1), /al menos un administrador/);
  assert.equal(v({ id: "x", rol: "admin" }, "chofer", 2), null);
  assert.match(v({ id: "x", rol: "chofer" }, "chofer"), /ya tiene ese rol/);
  assert.match(v({ id: "x", rol: "cliente" }, "superusuario"), /rol válido/);
  assert.match(v(null, "chofer"), /Busca primero/);
});

test("CP-U29f matriz de permisos: el admin tiene todos, el chofer solo los suyos", () => {
  const roles = [{ id: "admin" }, { id: "chofer" }];
  const permisos = [{ codigo: "pedidos.ver" }, { codigo: "pedidos.repartir" }];
  const m = arr(L.matrizPermisos(roles, [{ rol_id: "chofer", permiso: "pedidos.repartir" }], permisos));
  assert.deepEqual(m.map((f) => [f.codigo, f.roles.admin, f.roles.chofer]), [["pedidos.ver", true, false], ["pedidos.repartir", true, true]]);
});
