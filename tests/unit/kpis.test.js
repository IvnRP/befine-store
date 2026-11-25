/* Tarjetas (indicadores) clicables del panel — 4 pruebas
   Caso CP-U44: al tocar una tarjeta, la lista muestra exactamente lo que cuenta la tarjeta
   (Pedidos, Reparto y Clientes); otro toque vuelve a la vista normal. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
const WEB = path.join(__dirname, "..", "..", "web");
const hoy = new Date();
const ayer = new Date(Date.now() - 2 * 864e5).toISOString();
const p = (numero, estado, total, created_at = hoy.toISOString()) => ({ numero, estado, total, created_at });
const nums = (xs) => xs.map((x) => x.numero).join(",");

test("CP-U44a Pedidos: cada tarjeta filtra lo mismo que cuenta", () => {
  const lista = [p(1, "pagado", 5000), p(2, "en_preparacion", 7000, ayer), p(3, "en_ruta", 8000),
                 p(4, "pendiente_pago", 2500), p(5, "cancelado", 9000), p(6, "entregado", 3000, ayer)];
  const r = L.resumenPedidos(lista, hoy);
  const f = (estado) => L.filtrarPedidos(lista, { estado, hoy });
  assert.equal(f("creados_hoy").length, r.hoy);                  // hoy y no cancelados
  assert.equal(nums(f("creados_hoy")), "1,3,4");
  assert.equal(f("por_preparar").length, r.porPreparar);
  assert.equal(nums(f("por_preparar")), "1,2");
  assert.equal(f("en_ruta").length, r.enRuta);
  assert.equal(f("pendiente_pago").length, r.pendientesPago);
  const vendidos = f("vendidos_mes");
  assert.equal(vendidos.length, r.pedidosMes);
  assert.equal(vendidos.reduce((a, x) => a + x.total, 0), r.ventasMes);
  const c = L.contarPorEstado(lista, hoy);
  assert.equal(c.creados_hoy, 3); assert.equal(c.por_preparar, 2); assert.equal(c.vendidos_mes, r.pedidosMes);
});

test("CP-U44b Clientes: Nuevos este mes, Vuelven a comprar y Ticket promedio abren sus clientes", () => {
  const mes = hoy.toISOString(), viejo = new Date(Date.now() - 90 * 864e5).toISOString();
  const lista = [
    { id: "a", pedidos: 1, gastado: 10000, primer_pedido: mes, ultimo_pedido: mes },
    { id: "b", pedidos: 3, gastado: 30000, primer_pedido: viejo, ultimo_pedido: mes },
    { id: "c", pedidos: 2, gastado: 15000, primer_pedido: viejo, ultimo_pedido: viejo },
    { id: "d", pedidos: 0, gastado: 0, primer_pedido: null, ultimo_pedido: null },
  ];
  const r = L.resumenClientes(lista, hoy);
  const ids = (segmento) => L.filtrarClientes(lista, { segmento }, hoy).map((x) => x.id).join(",");
  assert.equal(ids("nuevos_mes"), "a"); assert.equal(r.nuevosMes, 1);
  assert.equal(ids("recurrentes"), "b,c"); assert.equal(r.recurrentes, 2);
  assert.equal(ids("compradores"), "a,b,c"); assert.equal(r.compradores, 3);
  assert.equal(ids("recuperar"), "c"); assert.equal(r.porRecuperar, 1);
  assert.equal(ids("todos"), "a,b,c,d");
});

test("CP-U44c las tarjetas son botones accesibles en Pedidos, Reparto y Clientes", () => {
  const ped = fs.readFileSync(path.join(WEB, "js", "admin-pedidos.js"), "utf8");
  for (const f of ["creados_hoy", "por_preparar", "en_ruta", "vendidos_mes", "pendiente_pago", "sin_documento"]) {
    assert.match(ped, new RegExp(`kpi\\("${f}"`), f);
  }
  assert.match(ped, /<button type="button" class="pn-kpi[^`]*data-kpi-f=[^`]*aria-pressed=/);
  assert.match(ped, /filtro\.estado = "activos"/);                     // segundo toque: vuelve a "Para gestionar"
  const rep = fs.readFileSync(path.join(WEB, "js", "admin-reparto.js"), "utf8");
  for (const v of ["por_salir", "en_ruta", "entregados", "atrasados"]) assert.match(rep, new RegExp(`kpi\\("${v}"`), v);
  const cli = fs.readFileSync(path.join(WEB, "js", "admin-clientes.js"), "utf8");
  for (const s of ["todos", "nuevos_mes", "recurrentes", "compradores", "recuperar"]) assert.match(cli, new RegExp(`kpi\\("${s}"`), s);
});

test("CP-U44d al abrir una tarjeta se quitan la búsqueda y el filtro de entrega (la lista calza con el número)", () => {
  const ped = fs.readFileSync(path.join(WEB, "js", "admin-pedidos.js"), "utf8");
  assert.match(ped, /filtro\.estado = f; filtro\.q = ""; filtro\.entrega = "todas"/);
  assert.equal(Object.keys(L.FILTROS_KPI_PEDIDOS).join(","), "creados_hoy,por_preparar,vendidos_mes");
});
