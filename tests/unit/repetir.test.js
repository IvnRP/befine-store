/* Repetir mi último pedido — recompra en 1 toque (web/js/data.js, ui.js, home.js, cuenta.js, correo) — 7 pruebas
   Caso CP-U40: el cliente vuelve a pedir lo mismo desde el inicio, Mi cuenta o el correo, con el precio de
   HOY. Solo pedidos pagados; sin sesión no se consulta nada; el enlace del correo solo acepta un uuid. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const WEB = path.join(__dirname, "..", "..", "web");
const leer = (f) => fs.readFileSync(path.join(WEB, f), "utf8");
const UID = "11111111-2222-4333-8444-555555555555";
const PED = "8f1c2d3e-4b5a-4c6d-8e7f-901234567890";
const V1 = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

/* Supabase simulado que registra la consulta de pedidos (filtros, orden y límite) */
function simulado({ usuario = null, fila = null } = {}) {
  const consulta = { llamadas: 0 };
  const q = {
    select: (s) => { consulta.select = s; return q; },
    eq: (c, v) => { consulta.eq = [c, v]; return q; },
    in: (c, v) => { consulta.in = [c, [...v]]; return q; },
    order: (c, o) => { consulta.order = [c, o.ascending]; return q; },
    limit: (n) => { consulta.limit = n; return q; },
    maybeSingle: async () => { consulta.llamadas++; return { data: fila, error: null }; },
  };
  const cliente = {
    auth: { getSession: async () => ({ data: { session: usuario ? { user: usuario } : null } }), onAuthStateChange: () => ({}) },
    rpc: async () => ({ data: null, error: null }),
    from: (t) => { consulta.tabla = t; return q; },
  };
  const { Befine } = cargar(["data.js"], { cliente });
  return { Befine, consulta };
}

test("CP-U40a resumen corto del pedido para el botón", () => {
  const { Befine } = simulado();
  assert.equal(Befine.resumenItems([{ cantidad: 3, nombre: "Recarga Bidón 20 L" }]), "3 × Recarga Bidón 20 L");
  assert.equal(Befine.resumenItems([{ cantidad: 3, nombre: "Recarga" }, { cantidad: 1, nombre: "Dispensador" }]), "3 × Recarga y 1 producto más");
  assert.equal(Befine.resumenItems([{ cantidad: 2, nombre: "A" }, { cantidad: 1, nombre: "B" }, { cantidad: 1, nombre: "C" }]), "2 × A y 2 productos más");
  assert.equal(Befine.resumenItems([{ cantidad: 0, nombre: "A" }]), "");
  assert.equal(Befine.resumenItems(null), "");
});

test("CP-U40b el aviso del checkout explica precios de hoy, carrito previo y productos no disponibles", () => {
  const { Befine } = simulado();
  assert.equal(Befine.avisoRepeticion(0, []), "Cargamos tu pedido con los precios de hoy. Revisa y paga.");
  assert.match(Befine.avisoRepeticion(1, []), /ya tenías en el carrito \(1 producto\)/);
  assert.match(Befine.avisoRepeticion(2, ["Pack"]), /\(2 productos\)\. No disponibles: Pack\./);
});

test("CP-U40c sin sesión no se consulta ningún pedido", async () => {
  const { Befine, consulta } = simulado({ usuario: null });
  assert.equal(await Befine.ultimoPedido(), null);
  assert.equal(consulta.llamadas, 0);
});

test("CP-U40d último pedido: solo los propios y pagados, el más reciente, con sus productos", async () => {
  const fila = { id: PED, numero: 64, created_at: "2026-11-20T12:00:00Z",
    detalle_pedido: [{ variante_id: V1, cantidad: 3, variante: { nombre: "Con bidón Befine", producto: { nombre: "Recarga Bidón 20 L" } } }] };
  const { Befine, consulta } = simulado({ usuario: { id: UID }, fila });
  const u = await Befine.ultimoPedido();
  assert.equal(consulta.tabla, "pedidos");
  assert.equal(consulta.eq.join(), `perfil_id,${UID}`);
  assert.equal(consulta.in[0], "estado");
  assert.equal(consulta.in[1].join(), "pagado,en_preparacion,en_ruta,entregado");   // ni pendientes ni cancelados
  assert.equal(consulta.order.join(), "created_at,false");
  assert.equal(consulta.limit, 1);
  assert.equal(u.numero, 64);
  assert.equal(JSON.stringify(u.items), JSON.stringify([{ variante_id: V1, cantidad: 3, nombre: "Recarga Bidón 20 L", variante: "Con bidón Befine" }]));
});

test("CP-U40e un pedido sin productos o una consulta fallida no ofrece repetir (caso de error)", async () => {
  const a = simulado({ usuario: { id: UID }, fila: { id: PED, numero: 1, created_at: "x", detalle_pedido: [] } });
  assert.equal(await a.Befine.ultimoPedido(), null);
  const b = simulado({ usuario: { id: UID }, fila: null });
  assert.equal(await b.Befine.ultimoPedido(), null);
});

test("CP-U40f el inicio, Mi cuenta y el checkout usan la recompra compartida", () => {
  const ui = leer("js/ui.js"), home = leer("js/home.js"), cuenta = leer("js/cuenta.js"), co = leer("js/checkout.js");
  assert.match(ui, /window\.repetirPedido = async function \(items\)/);
  assert.match(ui, /const r = await Befine\.volverAPedir\(items\);/);          // precio de HOY desde el catálogo
  assert.match(ui, /location\.href = "checkout\.html";/);
  assert.match(home, /Befine\.ultimoPedido\(\)\.then/);
  assert.match(home, /box\.querySelector\("small"\)\.textContent = Befine\.resumenItems\(u\.items\);/);   // sin innerHTML con datos
  assert.match(cuenta, /data-repetir-ult=/);
  assert.match(cuenta, /const repetirId = RE_UUID\.test\(url\.get\("repetir"\) \|\| ""\) \? url\.get\("repetir"\) : null;/);
  assert.match(co, /sessionStorage\.getItem\("befine_aviso_checkout"\)/);
});

test("CP-U40g el correo trae 'Repetir este pedido' solo con un id válido y nunca en un canje", () => {
  const T = require(path.join(WEB, "supabase", "functions", "enviar-correo", "plantilla.ts"));
  const base = { numero: 64, contacto_email: "c@correo.cl", lineas: [], subtotal: 7500, costo_despacho: 0, descuento_cupon: 0, total: 7500 };
  const c = T.armarCorreo({ ...base, id: PED }, "https://aguabefine.cl/");
  assert.ok(c.html.includes(`href="https://aguabefine.cl/cuenta.html?repetir=${PED}"`));
  assert.match(c.texto, new RegExp(`Repetir este pedido en 1 toque: https://aguabefine.cl/cuenta.html\\?repetir=${PED}`));
  assert.doesNotMatch(T.armarCorreo({ ...base, id: '"><script>' }, "https://aguabefine.cl").html, /repetir=/);
  assert.doesNotMatch(T.armarCorreo({ ...base, id: PED, es_canje: true, total: 0 }, "https://aguabefine.cl").html, /Repetir este pedido/);
  assert.match(fs.readFileSync(path.join(WEB, "supabase", "functions", "enviar-correo", "index.ts"), "utf8"), /id: pedidoId,/);
});
