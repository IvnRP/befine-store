/* Pruebas de "Disponible a pedido" (web/js/data.js) — 4 pruebas
   Casos CP-U26 del Plan de Pruebas: un producto sin stock se sigue vendiendo (HU v2.4), pero se
   informa antes de comprar (Reglamento de Comercio Electrónico) y su entrega se aplaza 2 días hábiles. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

/* Supabase simulado: cada tabla responde con filas fijas; registra las consultas hechas. */
function clienteFalso(tablas, consultas = []) {
  return {
    from(tabla) {
      consultas.push(tabla);
      const r = tablas[tabla] || { data: [], error: null };
      const q = {
        select: () => q, eq: () => q, in: () => q, order: () => q,
        maybeSingle: () => Promise.resolve({ data: (r.data || [])[0] || null, error: r.error || null }),
        then: (ok, ko) => Promise.resolve({ data: r.data, error: r.error || null }).then(ok, ko),
      };
      return q;
    },
  };
}
const variante = (id, controla_stock, stock) => ({ id, producto_id: "p1", sku: "BEF-" + id, nombre: id, atributos: {},
  stock, controla_stock, activo: true, precios_variante: [{ nivel_precio_id: 1, precio: 5000 }] });
const producto = (vars) => ({ id: "p1", nombre: "Bidón", descripcion: "", imagen_url: null, activo: true,
  categorias: { nombre: "Bidones", slug: "bidones" }, variantes_producto: vars });

test("CP-U26a solo es \"a pedido\" la variante que controla stock y no tiene unidades; el producto, si lo son todas sus opciones", async () => {
  const tablas = (vars) => ({ niveles_precio: { data: [{ id: 1, codigo: "retail" }] }, productos: { data: [producto(vars)] } });
  const { Befine } = cargar(["data.js"], { cliente: clienteFalso(tablas([variante("A", true, 0), variante("B", true, 5), variante("C", false, 0)])) });
  const p = await Befine.getProducto("p1");
  assert.deepEqual(p.variantes.map((v) => [v.id, v.a_pedido]), [["A", true], ["B", false], ["C", false]]);
  assert.equal(p.a_pedido, false);   // tiene opciones con stock: la tarjeta no muestra la leyenda
  const { Befine: B2 } = cargar(["data.js"], { cliente: clienteFalso(tablas([variante("A", true, 0), variante("D", true, -2)])) });
  assert.equal((await B2.getProducto("p1")).a_pedido, true);
});

test("CP-U26b con productos a pedido la entrega estándar y la agendada se aplazan 2 días hábiles (sin fines de semana ni feriados)", () => {
  const { Befine } = cargar(["data.js"]);
  const f = Befine.isoFecha;
  const jue = Befine.diasEntrega(new Date(2026, 9, 15, 15), { aPedido: true });   // jueves 15-10
  assert.equal(f(jue.estandar), "2026-10-20");        // 3er día hábil: martes
  assert.equal(f(jue.estandarHasta), "2026-10-21");   // 4º día hábil: miércoles
  assert.equal(f(jue.agendables[0]), "2026-10-20");   // no se puede agendar antes del plazo
  assert.equal(jue.agendables.length, 20);
  const vie = Befine.diasEntrega(new Date(2026, 9, 9, 15), { aPedido: true });    // viernes 09-10, lunes 12-10 feriado
  assert.equal(f(vie.estandar), "2026-10-15");
  // sin productos a pedido no cambia nada
  assert.equal(f(Befine.diasEntrega(new Date(2026, 9, 15, 15), { aPedido: false }).estandar), "2026-10-16");
});

test("CP-U26c el plazo informado coincide con el cálculo y con los textos de Términos y Despacho", () => {
  const { Befine } = cargar(["data.js"]);
  assert.equal(Befine.plazoAPedido(), "entrega en 3 a 4 días hábiles");
  const web = path.join(__dirname, "..", "..", "web");
  for (const pagina of ["terminos.html", "despacho.html"]) {
    assert.match(fs.readFileSync(path.join(web, pagina), "utf8"), /3 a 4 días hábiles/, pagina);
  }
});

test("CP-U26d disponibilidad actual del carrito: Set de variantes a pedido; sin ids no consulta; con error devuelve null", async () => {
  const consultas = [];
  const filas = [{ id: "A", stock: 0, controla_stock: true }, { id: "B", stock: 3, controla_stock: true }, { id: "C", stock: 0, controla_stock: false }];
  const { Befine } = cargar(["data.js"], { cliente: clienteFalso({ variantes_producto: { data: filas } }, consultas) });
  assert.deepEqual([...(await Befine.disponibilidad(["A", "B", "C", "A"]))], ["A"]);
  consultas.length = 0;
  assert.equal((await Befine.disponibilidad([])).size, 0);
  assert.deepEqual(consultas, []);
  const { Befine: B2 } = cargar(["data.js"], { cliente: clienteFalso({ variantes_producto: { data: null, error: { message: "sin red" } } }) });
  assert.equal(await B2.disponibilidad(["A"]), null);
});
