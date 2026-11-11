/* Pruebas del correo de confirmación de compra (web/supabase/functions/enviar-correo/plantilla.ts) — 4 pruebas
   Casos CP-U30 del Plan de Pruebas (HU-10 / RF-09): contenido exigido por la ley, escape de datos del
   cliente y coherencia de la identificación del proveedor con la tienda.
   La plantilla es TypeScript sin dependencias: Node la carga directamente (type stripping). */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const T = require(path.join(__dirname, "..", "..", "web", "supabase", "functions", "enviar-correo", "plantilla.ts"));
const SITIO = "https://aguabefine.cl";
const pedido = (o = {}) => ({
  numero: 28, contacto_nombre: "Iván Rodríguez", contacto_email: "cliente@correo.cl", fecha_entrega: "2026-11-13",
  direccion: { calle: "Los Tailandeses", numero: "1156", depto: null, comuna: "Quilicura", referencia: "Portón negro" },
  lineas: [{ cantidad: 8, producto: "Recarga Bidón 20 Litros", variante: "Con bidón Befine", precio_unitario: 2500, subtotal: 20000 }],
  subtotal: 20000, costo_despacho: 0, descuento_cupon: 0, total: 20000, tipo_documento: "boleta",
  es_canje: false, puntos_ganados: 22, terminos_version: "2026-11-07", ...o,
});

test("CP-U30a la confirmación trae lo que exige la ley: proveedor, detalle, total, entrega, retracto y Términos", () => {
  const c = T.armarCorreo(pedido(), SITIO);
  assert.equal(c.asunto, "Befine: confirmación de tu pedido #28");
  for (const t of [c.html, c.texto]) {
    assert.match(t, /Comercializadora de Agua Purificada e Insumos Iván Rodríguez Pinares E\.I\.R\.L\./);
    assert.match(t, /77\.861\.415-4/);
    assert.match(t, /8 x Recarga Bidón 20 Litros \(Con bidón Befine\)/);
    assert.match(t, /\$20\.000/);
    assert.match(t, /viernes, 13 de noviembre/);
    assert.match(t, /9:00 a 17:00/);
    assert.match(t, /retracto dentro de 10 días/);
    assert.match(t, /aguabefine\.cl\/terminos\.html/);
    assert.match(t, /2026-11-07/);
    assert.match(t, /22 puntos/);
  }
});

test("CP-U30b los datos del cliente se escapan en el HTML (no se puede inyectar código en el correo)", () => {
  const c = T.armarCorreo(pedido({ contacto_nombre: '<img src=x onerror=alert(1)>',
    direccion: { calle: "<b>Calle</b>", numero: "1", comuna: "Quilicura", referencia: '"><script>x</script>' } }), SITIO);
  assert.ok(!c.html.includes("<img src=x"));
  assert.ok(!c.html.includes("<script>"));
  assert.match(c.html, /&lt;b&gt;Calle&lt;\/b&gt;/);
});

test("CP-U30c canje de $0, descuento y despacho pagado se informan bien; montos en pesos chilenos", () => {
  const canje = T.armarCorreo(pedido({ es_canje: true, descuento_cupon: 5490, total: 0, puntos_ganados: 0 }), SITIO);
  assert.match(canje.texto, /Canjeaste un premio del Club Befine/);
  assert.match(canje.texto, /Descuento: -\$5\.490/);
  assert.ok(!/puntos del Club/.test(canje.texto));
  const despacho = T.armarCorreo(pedido({ costo_despacho: 2500, total: 22500 }), SITIO);
  assert.match(despacho.texto, /Despacho: \$2\.500/);
  assert.equal(T.clp(1234567), "$1.234.567");
  assert.equal(T.fechaLarga(null), "por confirmar");
});

test("CP-U30d la identificación del proveedor del correo es la misma de la tienda (data.js)", () => {
  const { Befine } = cargar(["data.js"]);
  for (const k of ["nombre_fantasia", "razon_social", "rut", "domicilio", "correo"]) {
    assert.equal(T.PROVEEDOR[k], Befine.proveedor[k], k);
  }
  assert.equal(T.PROVEEDOR.whatsapp, Befine.contacto.whatsapp);
  assert.equal(T.HORARIO_REPARTO, Befine.horarioReparto);
});
