/* Pruebas de la sección Clientes del panel (web/js/admin-logic.js) — 6 pruebas
   Casos CP-U31 del Plan de Pruebas (HU-23 · RF-19 ajustado por CM-03 · migración 14). */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
const arr = (x) => Array.from(x);
const errores = (d) => Object.keys(L.validarCliente(d)).join(",");   // "" = sin errores
const HOY = new Date(2026, 10, 12, 10, 0);                    // 12-nov-2026
const haceDias = (n) => new Date(2026, 10, 12 - n, 9, 0).toISOString();
const cli = (o) => ({ id: "c" + Math.random(), nombre: "Cliente", email: "", telefono: null, comuna: "Quilicura",
  invitado: false, empresa: false, rol: "cliente", activo: true, puntos: 0, pedidos: 0, gastado: 0,
  ultimo_pedido: null, primer_pedido: null, ...o });

test("CP-U31a la sección Clientes se ve con clientes.ver o clientes.gestionar; el chofer no la ve", () => {
  const ids = (p, rol) => arr(L.seccionesVisibles(p, rol)).map((s) => s.id);
  assert.ok(ids(["clientes.ver"], "operador").includes("clientes"));
  assert.ok(ids(["clientes.gestionar"], "operador").includes("clientes"));
  assert.ok(!ids(["pedidos.repartir"], "chofer").includes("clientes"));
});

test("CP-U31b segmentos: invitado/registrado, empresa, frecuente (3+), por recuperar (+45 días) y bloqueado", () => {
  const seg = (o) => arr(L.segmentosDe(cli(o), HOY));
  assert.deepEqual(seg({ invitado: true }), ["todos", "invitados"]);
  assert.ok(seg({ empresa: true }).includes("empresas"));
  assert.ok(seg({ pedidos: 3, ultimo_pedido: haceDias(2) }).includes("frecuentes"));
  assert.ok(!seg({ pedidos: 2, ultimo_pedido: haceDias(2) }).includes("frecuentes"));
  assert.ok(seg({ pedidos: 1, ultimo_pedido: haceDias(46) }).includes("recuperar"));
  assert.ok(!seg({ pedidos: 1, ultimo_pedido: haceDias(45) }).includes("recuperar"));   // 45 días justos todavía no
  assert.ok(!seg({ pedidos: 0 }).includes("recuperar"));                              // sin compras no se "recupera"
  assert.ok(seg({ activo: false }).includes("bloqueados"));
});

test("CP-U31c búsqueda por nombre sin acentos, correo, comuna o celular en cualquier formato", () => {
  const l = [cli({ id: "a", nombre: "José Pérez", email: "jose@correo.cl", telefono: "56912345678" }),
             cli({ id: "b", nombre: "Ana", comuna: "Huechuraba", empresa: true })];
  const ids = (f) => arr(L.filtrarClientes(l, f, HOY)).map((c) => c.id);
  assert.deepEqual(ids({ q: "jose perez" }), ["a"]);
  assert.deepEqual(ids({ q: "JOSE@CORREO" }), ["a"]);
  assert.deepEqual(ids({ q: "huechu" }), ["b"]);
  assert.deepEqual(ids({ q: "+56 9 1234 5678" }), ["a"]);
  assert.deepEqual(ids({ q: "1234-5678" }), ["a"]);
  assert.deepEqual(ids({ segmento: "empresas" }), ["b"]);
  assert.deepEqual(ids({ segmento: "empresas", q: "jose" }), []);
});

test("CP-U31d indicadores: nuevos del mes, recurrencia, ticket promedio y por recuperar", () => {
  const l = [
    cli({ pedidos: 2, gastado: 10000, primer_pedido: haceDias(3), ultimo_pedido: haceDias(1) }),     // nuevo y recurrente
    cli({ pedidos: 1, gastado: 5000, primer_pedido: "2026-08-01T12:00:00Z", ultimo_pedido: "2026-08-01T12:00:00Z" }),   // por recuperar
    cli({ invitado: true }),                                                                         // sin compras pagadas
  ];
  const r = L.resumenClientes(l, HOY);
  assert.equal(r.total, 3);
  assert.equal(r.compradores, 2);
  assert.equal(r.nuevosMes, 1);
  assert.equal(r.recurrentes, 1);
  assert.equal(r.recurrencia, 50);
  assert.equal(r.ticket, 5000);            // 15.000 / 3 pedidos
  assert.equal(r.porRecuperar, 1);
  assert.deepEqual(L.resumenClientes([], HOY).ticket, 0);
  const n = L.contarSegmentos(l, HOY);
  assert.equal(n.todos, 3); assert.equal(n.invitados, 1); assert.equal(n.registrados, 2);
});

test("CP-U31e RUT con módulo 11 y celular chileno con las mismas reglas que el servidor", () => {
  assert.equal(L.rutValido("22.222.222-2"), true);
  assert.equal(L.rutValido("77.861.415-4"), true);
  assert.equal(L.rutValido("12.345.678-0"), false);
  assert.equal(L.rutValido("abc"), false);
  assert.equal(L.formatoRut("222222222"), "22.222.222-2");
  assert.equal(L.normalizarTelefono("+56 9 1234 5678"), "56912345678");
  assert.equal(L.normalizarTelefono("912345678"), "56912345678");
  assert.equal(L.normalizarTelefono("123"), null);
});

test("CP-U31f editar cliente: nombre obligatorio, celular y RUT válidos, empresa con RUT, razón social y giro", () => {
  assert.equal(errores({ nombre: "Ana" }), "");
  assert.ok(L.validarCliente({ nombre: "A" }).nombre);
  assert.ok(L.validarCliente({ nombre: "Ana", telefono: "123" }).telefono);
  assert.equal(errores({ nombre: "Ana", telefono: "" }), "");           // vacío = sin celular
  assert.ok(L.validarCliente({ nombre: "Ana", rut: "12.345.678-0" }).rut);
  const e = L.validarCliente({ nombre: "Ana", es_empresa: true });
  assert.ok(e.rut && e.razon_social && e.giro);
  assert.equal(errores({ nombre: "Ana", es_empresa: true, rut: "22.222.222-2", razon_social: "Ana SpA", giro: "Comercio" }), "");
});
