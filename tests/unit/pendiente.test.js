/* Pruebas de la reutilización del pedido pendiente de pago (web/js/data.js) — 4 pruebas
   Casos CP-U23 del Plan de Pruebas (mejora M-02). El checkout vuelve a pagar el MISMO pedido
   si el cliente no cambió nada, en vez de crear otro "Pendiente de pago". */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { Befine } = cargar(["data.js"]);
const HORA = 3600 * 1000;
const AHORA = new Date("2026-10-28T15:00:00Z").getTime();

const payload = () => ({
  contacto: { nombre: "Cliente Prueba", email: "cliente@example.com", telefono: "+56911223344" },
  direccion: { calle: "Los Olmos", numero: "123", depto: null, comuna: "Quilicura" },
  entrega: { tipo: "estandar", fecha: "2026-10-29" },
  documento: { tipo: "boleta" },
  items: [{ variante_id: "v1", cantidad: 4, precio_unitario: 2500 }],
  cupon: null,
});

test("CP-U23a la firma es estable para el mismo pedido y no contiene datos personales", () => {
  const f = Befine.firmaPedido(payload());
  assert.equal(f, Befine.firmaPedido(payload()));
  assert.match(f, /^[0-9a-z]+$/);
  assert.equal(f.includes("cliente"), false);
});

test("CP-U23b la firma cambia si cambian productos, cantidades, dirección, fecha o cupón", () => {
  const base = Befine.firmaPedido(payload());
  const cambios = [
    (p) => { p.items[0].cantidad = 5; },
    (p) => { p.items.push({ variante_id: "v2", cantidad: 1, precio_unitario: 3500 }); },
    (p) => { p.direccion.comuna = "Conchalí"; },
    (p) => { p.entrega.fecha = "2026-10-30"; },
    (p) => { p.cupon = "BIENVENIDA"; },
  ];
  for (const cambiar of cambios) {
    const p = payload(); cambiar(p);
    assert.notEqual(Befine.firmaPedido(p), base);
  }
});

test("CP-U23c se reutiliza solo un pedido pendiente de pago y reciente (menos de 24 h)", () => {
  const pendiente = (horas) => ({ estado: "pendiente_pago", created_at: new Date(AHORA - horas * HORA).toISOString() });
  assert.equal(Befine.pedidoReutilizable(pendiente(0.1), AHORA), true);
  assert.equal(Befine.pedidoReutilizable(pendiente(23.9), AHORA), true);
  assert.equal(Befine.pedidoReutilizable(pendiente(24), AHORA), false);
  assert.equal(Befine.pedidoReutilizable(pendiente(-1), AHORA), false);   // fecha futura: no confiable
});

test("CP-U23d un pedido pagado, cancelado o inexistente nunca se reutiliza (caso de error)", () => {
  const reciente = new Date(AHORA - HORA).toISOString();
  for (const estado of ["pagado", "en_preparacion", "cancelado"]) {
    assert.equal(Befine.pedidoReutilizable({ estado, created_at: reciente }, AHORA), false, estado);
  }
  assert.equal(Befine.pedidoReutilizable(null, AHORA), false);
  assert.equal(Befine.pedidoReutilizable({ estado: "pendiente_pago" }, AHORA), false);   // sin fecha
});
