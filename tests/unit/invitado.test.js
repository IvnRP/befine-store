/* Compra como invitado y vuelta desde OTRO navegador (web/js/data.js + migración 17) — 7 pruebas
   Caso CP-U37 (incidente 19-nov-2026): la clienta pagó como invitada desde el navegador de WhatsApp
   y Mercado Pago la devolvió a otro navegador, sin su sesión. Ahora la vuelta muestra el pedido
   (pedido_vuelta, sin datos personales) y, al entrar con su cuenta de correo confirmado, sus compras
   como invitada pasan a la cuenta (reclamar_pedidos_invitado). Supabase se simula. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const PEDIDO = "8f1c2d3e-4b5a-4c6d-8e7f-901234567890";
const CUENTA = { id: "11111111-2222-4333-8444-555555555555", is_anonymous: false, email: "ana@correo.cl", email_confirmed_at: "2026-11-20T10:00:00Z" };

/* Supabase simulado: usuario de la sesión, respuestas de rpc() y registro de llamadas en orden */
function simulado({ usuario = null, rpc = {} } = {}) {
  const llamadas = [];
  const cliente = {
    auth: {
      getSession: async () => ({ data: { session: usuario ? { user: usuario } : null } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signInWithPassword: async () => ({ error: null }),
    },
    rpc: async (fn, args) => { llamadas.push("rpc:" + fn); llamadas.args = args; return rpc[fn] || { data: null, error: null }; },
    from: (tabla) => {
      const q = { select: () => q, eq: () => q, maybeSingle: async () => { llamadas.push("from:" + tabla); return { data: { id: PEDIDO, numero: 9, estado: "pagado" }, error: null }; } };
      return q;
    },
  };
  const w = cargar(["data.js"], { cliente });
  const datos = {};
  w.sessionStorage = { getItem: (k) => (k in datos ? datos[k] : null), setItem: (k, v) => { datos[k] = String(v); } };
  return { Befine: w.Befine, llamadas };
}

test("CP-U37a el correo escrito debe calzar con el correo enmascarado de la compra", () => {
  const { Befine } = simulado();
  assert.equal(Befine.coincideCorreo("Ana.Perez@Gmail.com ", "an•••@gmail.com"), true);
  assert.equal(Befine.coincideCorreo("ana@hotmail.com", "an•••@gmail.com"), false);   // otro dominio
  assert.equal(Befine.coincideCorreo("pedro@gmail.com", "an•••@gmail.com"), false);   // otro comienzo
  assert.equal(Befine.coincideCorreo("j@x.cl", "j•••@x.cl"), true);
  assert.equal(Befine.coincideCorreo("", "an•••@gmail.com"), false);
  assert.equal(Befine.coincideCorreo("ana@gmail.com", null), false);
});

test("CP-U37b pedidoVuelta: consulta pedido_vuelta solo con el id del pedido y no inventa datos", async () => {
  const vta = { id: PEDIDO, numero: 64, estado: "en_preparacion", total: 7000, correo: "an•••@gmail.com", invitado: true };
  const { Befine, llamadas } = simulado({ rpc: { pedido_vuelta: { data: vta, error: null } } });
  const r = await Befine.pedidoVuelta(PEDIDO);
  assert.equal(r.numero, 64);
  assert.equal(r.correo, "an•••@gmail.com");
  assert.equal(llamadas.join(","), "rpc:pedido_vuelta");
  assert.equal(JSON.stringify(llamadas.args), JSON.stringify({ p_pedido: PEDIDO }));
  assert.equal(await Befine.pedidoVuelta("no-es-uuid"), null);   // sin llamar a la base
  assert.equal(llamadas.length, 1);
});

test("CP-U37c pedidoVuelta: si el servidor no lo encuentra o falla, devuelve null (caso de error)", async () => {
  const a = simulado({ rpc: { pedido_vuelta: { data: null, error: null } } });
  assert.equal(await a.Befine.pedidoVuelta(PEDIDO), null);
  const b = simulado({ rpc: { pedido_vuelta: { data: null, error: { message: "permission denied" } } } });
  assert.equal(await b.Befine.pedidoVuelta(PEDIDO), null);
});

test("CP-U37d sin cuenta, como invitado o con el correo sin confirmar no se intenta el traspaso", async () => {
  for (const usuario of [null, { ...CUENTA, is_anonymous: true }, { ...CUENTA, email_confirmed_at: null }]) {
    const { Befine, llamadas } = simulado({ usuario });
    assert.equal(await Befine.reclamarInvitado(true), 0);
    assert.equal(llamadas.length, 0);
  }
});

test("CP-U37e con correo confirmado se traspasa 1 vez por pestaña y antes de leer el pedido", async () => {
  const { Befine, llamadas } = simulado({ usuario: CUENTA,
    rpc: { reclamar_pedidos_invitado: { data: { ok: true, pedidos: 1, numeros: [64], puntos: 7 }, error: null } } });
  assert.equal(await Befine.reclamarInvitado(), 1);        // la que se lanza al abrir la página
  assert.equal(await Befine.reclamarInvitado(true), 0);    // ya se hizo en esta pestaña
  const p = await Befine.estadoPedido(PEDIDO);
  assert.equal(p.numero, 9);
  assert.equal(llamadas.join(","), "rpc:reclamar_pedidos_invitado,from:pedidos");
});

test("CP-U37f la vuelta de Mercado Pago usa pedido_vuelta en otro navegador y la migración 17 protege el traspaso", () => {
  const web = path.join(__dirname, "..", "..", "web");
  const co = fs.readFileSync(path.join(web, "js", "checkout.js"), "utf8");
  assert.match(co, /esperarConfirmacion\(v\.pedido, Befine\.pedidoVuelta\)/);
  assert.match(co, /id="coCorreoCuenta"/);
  assert.match(co, /Befine\.coincideCorreo\(correo, mascara\)/);
  const sql = fs.readFileSync(path.join(web, "supabase", "migrations", "20261120_17_pedidos_invitado.sql"), "utf8");
  assert.match(sql, /function public\.pedido_vuelta\(p_pedido uuid\)[\s\S]*?security definer/);
  assert.match(sql, /interval '7 days'/);
  assert.match(sql, /v_confirmado is null then/);                                // solo correo confirmado
  assert.match(sql, /revoke execute on function public\.reclamar_pedidos_invitado\(\) from public, anon;/);
  assert.doesNotMatch(sql.match(/function public\.pedido_vuelta[\s\S]*?\$\$;/)[0], /contacto_(nombre|telefono)|direccion/);
  for (const f of ["20261120_17_pedidos_invitado_reversa.sql", "20261120_17_prueba_en_seco.sql"])
    assert.ok(fs.existsSync(path.join(web, "supabase", "migrations", f)), f);
});

test("CP-U37g si Mercado Pago (su app) devuelve al checkout sin la página de vuelta, se revisa el pago y se muestra", () => {
  const web = path.join(__dirname, "..", "..", "web");
  const co = fs.readFileSync(path.join(web, "js", "checkout.js"), "utf8");
  assert.match(co, /else revisarPagoSinVuelta\(\);/);                                    // al abrir el checkout
  assert.match(co, /visibilitychange[\s\S]{0,80}revisarPagoSinVuelta\(\)/);              // al volver de la app
  assert.match(co, /if \(Befine\.pedidoPagado\(srv\.estado\)\) \{ mostrarVuelta\(\{ estado: "ok", pedido: g\.id \}\)/);
  assert.match(co, /fueAMercadoPago = true;\s+\/\/[^\n]*\n\s+window\.location\.assign\(p\.url\);/);
  // Día agendado visible en tema claro (antes quedaba texto blanco sobre fondo blanco)
  const css = fs.readFileSync(path.join(web, "css", "forms.css"), "utf8");
  assert.match(css, /body\.tema-claro \.dia\[aria-pressed="true"\] \{[^}]*background: var\(--accent\)/);
});
