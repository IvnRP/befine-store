/* Pruebas de la aceptación de Términos y Política de privacidad (web/js/data.js) — 3 pruebas
   Casos CP-U24 del Plan de Pruebas (HU-25, Ley 21.719). La casilla del checkout es obligatoria;
   el servidor (crear_pedido, migración 06) la vuelve a exigir y la registra con su fecha. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

/* Supabase simulado: sesión activa y rpc() que guarda los argumentos */
function conRpc(respuesta) {
  const llamadas = [];
  const cliente = {
    auth: { getSession: async () => ({ data: { session: { user: { id: "u1" } } } }) },
    rpc: async (fn, args) => { llamadas.push({ fn, args }); return respuesta; },
  };
  return { Befine: cargar(["data.js"], { cliente }).Befine, llamadas };
}
const payload = (extra = {}) => ({
  contacto: { nombre: "Cliente Prueba", email: "cliente@example.com", telefono: "+56911223344" },
  direccion: { calle: "Los Olmos", numero: "123", comuna: "Quilicura" },
  entrega: { tipo: "estandar", fecha: "2026-11-09" },
  documento: { tipo: "boleta" },
  items: [{ variante_id: "v1", cantidad: 2 }],
  ...extra,
});
const ok = { data: { id: "p1", numero: 30, estado: "pendiente_pago", total: 4000 }, error: null };

test("CP-U24a con la casilla marcada se envía la aceptación al servidor", async () => {
  const { Befine, llamadas } = conRpc(ok);
  const r = await Befine.crearPedido(payload({ acepta_terminos: true }));
  assert.equal(r.ok, true);
  assert.equal(llamadas[0].fn, "crear_pedido");
  assert.equal(llamadas[0].args.p_contacto.acepta_terminos, true);
});

test("CP-U24b sin la casilla (o con un valor que no es true) la aceptación viaja como false", async () => {
  for (const valor of [undefined, false, "true", 1]) {
    const { Befine, llamadas } = conRpc(ok);
    await Befine.crearPedido(payload({ acepta_terminos: valor }));
    assert.equal(llamadas[0].args.p_contacto.acepta_terminos, false, String(valor));
  }
});

test("CP-U24c si el servidor rechaza por no aceptar, el cliente ve el motivo en español (caso de error)", async () => {
  const { Befine } = conRpc({ data: null, error: { message: "Debes aceptar los Términos y la Política de privacidad para comprar." } });
  const r = await Befine.crearPedido(payload());
  assert.equal(r.ok, false);
  assert.equal(r.error, "Debes aceptar los Términos y la Política de privacidad para comprar.");
});
