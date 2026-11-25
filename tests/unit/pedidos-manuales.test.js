/* Pedidos fuera de la página (migración 21) — 7 pruebas
   Caso CP-U43: el chofer registra pedidos de WhatsApp, llamada o presencial con productos del
   catálogo, cobro en efectivo, tarjeta o transferencia (ya pagado o por cobrar), entran a la ruta
   del día y el resumen muestra lo entregado por medio de pago y el efectivo a rendir. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
// Los objetos vienen de otro contexto (vm): se comparan por contenido
const igual = (a, b) => assert.equal(JSON.stringify(a), JSON.stringify(b));
const sinErrores = (e) => assert.equal(Object.keys(e).join(","), "");
const WEB = path.join(__dirname, "..", "..", "web");
const OP = {
  productos: [{ variante_id: "rec", producto: "Recarga Bidón 20 L", precio: 2500 }, { variante_id: "bid", producto: "Bidón + Recarga", precio: 7990 }],
  comunas: [{ comuna: "Quilicura", costo_despacho: 2500 }, { comuna: "Huechuraba", costo_despacho: 2500 }],
  envio_gratis_minimo: 7000,
};
const hoy = L.diaLocal(new Date());
const base = (o = {}) => ({ canal: "whatsapp", nombre: "Juan Pérez", telefono: "9 2101 2101", email: "", comuna: "Quilicura",
  calle: "Los Tailandeses", lineas: [{ variante_id: "rec", cantidad: 2 }], fecha: hoy, metodo: "efectivo", cobro: "por_cobrar",
  descuento: 0, motivo: "", documento: "boleta", ...o });

test("CP-U43a totales como el servidor: precio del catálogo, despacho por comuna y gratis desde $7.000", () => {
  igual(L.calcularPedidoManual([{ variante_id: "rec", cantidad: 2 }], OP, "quilicura", 0),
    { subtotal: 5000, despacho: 2500, descuento: 0, total: 7500, unidades: 2, conComuna: true });
  const gratis = L.calcularPedidoManual([{ variante_id: "rec", cantidad: 3 }], OP, "Quilicura", 500);
  assert.equal(gratis.despacho, 0); assert.equal(gratis.total, 7000);
  assert.equal(L.calcularPedidoManual([{ variante_id: "otro", cantidad: 9 }], OP, "Las Condes", 0).conComuna, false);
});

test("CP-U43b validación del formulario: datos mínimos y reglas de cobro", () => {
  sinErrores(L.validarPedidoManual(base(), OP));
  const e = L.validarPedidoManual(base({ canal: "web", telefono: "123", comuna: "Las Condes", calle: "", lineas: [], metodo: "cheque", cobro: "" }), OP);
  for (const k of ["canal", "telefono", "comuna", "calle", "lineas", "metodo", "cobro"]) assert.ok(e[k], k);
  assert.ok(L.validarPedidoManual(base({ email: "sin-arroba" }), OP).email);
  sinErrores(L.validarPedidoManual(base({ email: "cliente@correo.cl" }), OP));
});

test("CP-U43c fecha desde hoy hasta 45 días; descuento con motivo y nunca mayor que el total", () => {
  const ayer = L.diaLocal(new Date(Date.now() - 864e5));
  assert.ok(L.validarPedidoManual(base({ fecha: ayer }), OP).fecha);
  assert.ok(L.validarPedidoManual(base({ fecha: "" }), OP).fecha);
  assert.ok(L.validarPedidoManual(base({ descuento: 500 }), OP).motivo);
  sinErrores(L.validarPedidoManual(base({ descuento: 500, motivo: "Cliente antiguo" }), OP));
  assert.ok(L.validarPedidoManual(base({ descuento: 99999, motivo: "x regalo" }), OP).descuento);
  const f = L.validarPedidoManual(base({ documento: "factura", rut: "11.111.111-2" }), OP);
  assert.ok(f.rut && f.razon_social && f.giro);
  sinErrores(L.validarPedidoManual(base({ documento: "factura", rut: "76.086.428-5", razon_social: "Empresa SpA", giro: "Servicios" }), OP));
});

test("CP-U43d canal y cobro: etiquetas, filtro \"Fuera de la página\" y ventas del mes", () => {
  const w = { numero: 1, estado: "entregado", total: 10000, canal: "web", created_at: new Date().toISOString() };
  const m = { numero: 2, estado: "en_preparacion", total: 7500, canal: "whatsapp", metodo_pago: "efectivo", cobro_estado: "por_cobrar", created_at: new Date().toISOString() };
  assert.equal(L.esFueraPagina(w), false); assert.equal(L.esFueraPagina(m), true);
  assert.equal(L.esFueraPagina({ estado: "pagado" }), false);              // pedidos sin canal (antiguos) = web
  assert.equal(L.textoCobro(m), "Por cobrar · efectivo");
  assert.equal(L.textoCobro({ ...m, cobro_estado: "pagado", metodo_pago: "transferencia" }), "Pagado · transferencia");
  assert.equal(L.textoCobro(w), "");
  igual(L.filtrarPedidos([w, m], { estado: "fuera_pagina" }).map((p) => p.numero), [2]);
  assert.equal(L.contarPorEstado([w, m]).fuera_pagina, 1);
  const r = L.resumenPedidos([w, m]);
  assert.equal(r.ventasMes, 17500); assert.equal(r.fueraPaginaMes, 1);
  assert.ok(L.PERMISOS.includes("pedidos.registrar"));
});

test("CP-U43e resumen del día: por medio de pago, efectivo a rendir y lo que quedó por cobrar", () => {
  const r = L.resumenEntregas([
    { estado: "entregado", total: 10000, canal: "web" },
    { estado: "entregado", total: 7500, canal: "whatsapp", metodo_pago: "efectivo", cobro_estado: "pagado" },
    { estado: "entregado", total: 5000, canal: "llamada", metodo_pago: "efectivo", cobro_estado: "pagado" },
    { estado: "entregado", total: 2500, canal: "presencial", metodo_pago: "tarjeta", cobro_estado: "pagado" },
    { estado: "entregado", total: 3000, canal: "whatsapp", metodo_pago: "transferencia", cobro_estado: "por_cobrar" },
    { estado: "en_ruta", total: 9000, canal: "whatsapp", metodo_pago: "efectivo", cobro_estado: "por_cobrar" },   // aún no entregado
  ]);
  assert.equal(r.entregados, 5); assert.equal(r.monto, 28000); assert.equal(r.fueraPagina, 4);
  igual(r.porMetodo, { mercado_pago: 10000, efectivo: 12500, tarjeta: 2500, transferencia: 0 });
  assert.equal(r.efectivoARendir, 12500);
  igual(r.porCobrar, { cantidad: 1, monto: 3000 });
});

test("CP-U43f el panel: botón solo con pedidos.registrar, cobro antes de \"Entregado\" y sin correo no envía", () => {
  const rep = fs.readFileSync(path.join(WEB, "js", "admin-reparto.js"), "utf8");
  assert.match(rep, /app\.puede\("pedidos\.registrar"\)/);
  assert.match(rep, /cobrarPedido\(id, metodo\)[\s\S]*marcarReparto\(id, estado\)/);   // primero el cobro, luego entregado
  const ped = fs.readFileSync(path.join(WEB, "js", "admin-pedidos.js"), "utf8");
  assert.match(ped, /x\.ok && conCorreo/);
  assert.match(ped, /app\.puede\("pedidos\.gestionar"\) && !L\.documentoDe\(p\)/);    // solo admin corrige, y sin boleta
  const data = fs.readFileSync(path.join(WEB, "js", "admin-data.js"), "utf8");
  for (const fn of ["opciones_pedido_manual", "registrar_pedido_manual", "cobrar_pedido", "ajustar_pedido_manual"]) assert.match(data, new RegExp(`"${fn}"`));
});

test("CP-U43g la migración 21 protege los datos: permisos, cuenta web obligatoria y sin puntos del Club", () => {
  const m = fs.readFileSync(path.join(WEB, "supabase", "migrations", "20261125_21_pedidos_fuera_pagina.sql"), "utf8");
  assert.match(m, /check \(perfil_id is not null or canal <> 'web'\)/);
  assert.match(m, /tiene_permiso\('pedidos\.registrar'\)/);
  assert.match(m, /Solo el administrador puede corregir montos/);
  assert.match(m, /pv\.nivel_precio_id = 1/);                                    // precio desde la base, no del navegador
  assert.match(m, /'en_preparacion'/);                                           // no pasa por "pagado" → no dispara el Club
  const prueba = fs.readFileSync(path.join(WEB, "supabase", "migrations", "20261125_21_prueba_en_seco.sql"), "utf8");
  assert.match(prueba, /T15/);
});
