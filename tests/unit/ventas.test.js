/* Ventas del chofer y caja (migración 23) — 6 pruebas
   Caso CP-U46: el chofer anota una venta en pocos toques (precio del catálogo, celular +56 9, dirección),
   la planilla del día suma lo vendido y el efectivo a rendir, y el admin ve la caja por periodo. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
const WEB = path.join(__dirname, "..", "..", "web");
const PRODS = [
  { variante_id: "disp", producto: "Dispensador con Carga USB", variante: null, precio: 8990 },
  { variante_id: "b20", producto: "Bidón + Recarga 20 Litros", variante: null, precio: 5490 },
  { variante_id: "r20", producto: "Recarga Bidón 20 Litros", variante: "Con bidón Befine", precio: 2500 },
  { variante_id: "pack", producto: "Pack Inicial — 3 Bidones", variante: null, precio: 21990 },
];

test("CP-U46a los productos salen ordenados: recargas, bidones, el resto y packs al final", () => {
  assert.equal(L.ordenarProductosVenta(PRODS).map((p) => p.variante_id).join(","), "r20,b20,disp,pack");
});

test("CP-U46b el celular se escribe como sea y quedan los 8 números después de +56 9", () => {
  for (const v of ["+56 9 2101 2101", "56921012101", "921012101", "2101 2101", "2101-2101"]) assert.equal(L.celular8(v), "21012101", v);
  assert.equal(L.celular8("123"), "123");
  assert.equal(L.celular8(null), "");
});

test("CP-U46c total con precios del catálogo y descuento acotado", () => {
  const t = L.calcularVenta({ r20: 2, b20: 1, disp: 0 }, PRODS, 490);
  assert.equal(t.subtotal, 2 * 2500 + 5490);
  assert.equal(t.descuento, 490);
  assert.equal(t.total, 2 * 2500 + 5490 - 490);
  assert.equal(t.unidades, 3);
  assert.equal(t.lineas.map((l) => l.variante_id + ":" + l.cantidad).join(","), "b20:1,r20:2");
  assert.equal(L.calcularVenta({ r20: 1 }, PRODS, 99999).total, 0);   // el descuento nunca supera la venta
});

test("CP-U46d validación: productos, pago, dirección y celular de 8 números", () => {
  const ok = { lineas: [{ variante_id: "r20", cantidad: 1 }], pago: "efectivo", direccion: "Los Tailandeses 1156", telefono: "21012101", descuento: 0, subtotal: 2500 };
  assert.equal(Object.keys(L.validarVenta(ok)).length, 0);
  assert.equal(Object.keys(L.validarVenta({ ...ok, telefono: "" })).length, 0);   // el celular es opcional
  const e = L.validarVenta({ lineas: [], pago: "cheque", direccion: " ", telefono: "1234", descuento: 9000, subtotal: 2500 });
  assert.equal(Object.keys(e).sort().join(","), "descuento,direccion,lineas,pago,telefono");
});

test("CP-U46e planilla y periodos: anuladas no suman; semana de lunes a hoy; mes desde el 1", () => {
  const r = L.resumenVentas([
    { total: 5000, metodo_pago: "efectivo", items: [{ cantidad: 2 }] },
    { total: 2500, metodo_pago: "transferencia", items: [{ cantidad: 1 }] },
    { total: 9000, metodo_pago: "efectivo", anulada: true, items: [{ cantidad: 3 }] },
  ]);
  assert.equal(JSON.stringify(r), JSON.stringify({ ventas: 2, total: 7500, unidades: 3, anuladas: 1, efectivo: 5000, transferencia: 2500, tarjeta: 0 }));
  const jue = new Date(2026, 10, 26, 15);   // jueves 26-nov-2026
  assert.equal(JSON.stringify(L.rangoPeriodo("semana", jue)), JSON.stringify({ desde: "2026-11-23", hasta: "2026-11-26", txt: "Esta semana" }));
  assert.equal(L.rangoPeriodo("mes", jue).desde, "2026-11-01");
  assert.equal(L.rangoPeriodo("hoy", jue).desde, "2026-11-26");
  assert.equal(L.rangoPeriodo("rango", jue, "2026-11-20", "2026-11-10").desde, "2026-11-10");   // si vienen al revés, se ordenan
});

test("CP-U46f WhatsApp de usted y CSV para cuadrar la caja", () => {
  const tarde = new Date(2026, 10, 26, 15), manana = new Date(2026, 10, 26, 9);
  assert.equal(L.saludo("juan pérez", "don", tarde), "Buenas tardes, Don Juan");
  assert.equal(L.saludo("MARÍA", "srta", manana), "Buenos días, Srta. María");
  assert.equal(L.saludo("", "don", tarde), "Buenas tardes");   // sin nombre no se usa el trato
  const csv = L.csvCaja([{ numero: 7, fecha: "2026-11-26", hora: "15:02", chofer: "Pedro", metodo_pago: "efectivo", descuento: 0, total: 5000,
    direccion: "Los Tailandeses 1156; Quilicura", telefono: "56921012101", items: [{ cantidad: 2, producto: "Recarga Bidón 20 Litros", variante: "Con bidón Befine" }] }]);
  const lineas = csv.replace(/^﻿/, "").split("\r\n");
  assert.equal(lineas.length, 2);
  assert.match(lineas[1], /^7;2026-11-26;15:02;Pedro;2 x Recarga Bidón 20 Litros \(Con bidón Befine\);2;Efectivo;0;5000;"Los Tailandeses 1156; Quilicura";\+56921012101;Válida$/);
  // Al anotar una venta no se envía nada al cliente: el chofer guarda y sigue
  const vj = fs.readFileSync(path.join(WEB, "js", "admin-ventas.js"), "utf8");
  assert.doesNotMatch(vj, /r\.mensaje|vt-wa|agradecimiento/);
  assert.match(vj, /const wa = esCaja && v\.telefono/);
  // Los textos de WhatsApp del panel ya no tutean
  for (const f of ["admin-clientes.js", "admin-pedidos.js"]) assert.doesNotMatch(fs.readFileSync(path.join(WEB, "js", f), "utf8"), /te escribimos de Befine/, f);
});
