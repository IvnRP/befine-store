/* Pruebas del Club Befine (web/js/data.js) — 5 pruebas
   Casos CP-U28 del Plan de Pruebas (HU-19, migración 08): puntos solo por recargas con envase Befine,
   bono por pedido grande, puntos sobre lo pagado, invitación (Trae un amigo) y coherencia con la base. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const MIG = path.join(__dirname, "..", "..", "web", "supabase", "migrations");
const sql08 = () => fs.readFileSync(path.join(MIG, fs.readdirSync(MIG).find((f) => /_08_club_befine\.sql$/.test(f))), "utf8");
const rec = (cantidad, suma_puntos = true, precio = 2500) => ({ precio, cantidad, suma_puntos });

test("CP-U28a 1 punto por $1.000 en recargas Befine y +2 de bono desde 6 recargas", () => {
  const { Befine } = cargar(["data.js"]);
  const P = (l, d) => Befine.club.puntosPedido(l, d);
  assert.equal(P([rec(6)]).puntos, 17);                       // $15.000 → 15 + 2
  assert.equal(P([rec(5)]).puntos, 12);                       // $12.500 → 12, sin bono
  assert.equal(P([rec(5)]).faltanBono, 1);                    // "agrega 1 recarga más"
  assert.equal(P([rec(6, true, 2000)]).puntos, 14);           // recarga 12 L: $12.000 → 12 + 2
  assert.equal(P([rec(4, false, 2990)]).puntos, 0);           // envase de otra marca: no suma
  assert.equal(P([rec(2), rec(1, false, 8990)]).puntos, 5);   // el dispensador no suma
});

test("CP-U28b los puntos se calculan sobre lo pagado: el premio 50% (tope $7.500) no suma", () => {
  const { Befine } = cargar(["data.js"]);
  assert.equal(Befine.club.puntosPedido([rec(10)], 7500).puntos, 19);   // (25.000 − 7.500) / 1.000 = 17 + 2
  assert.equal(Befine.club.puntosPedido([rec(6)], 15000).puntos, 2);    // todo con descuento: solo el bono
  assert.equal(Befine.club.puntosPedido([], 0).puntos, 0);
});

test("CP-U28c Trae un amigo: solo se guarda un código de invitación con formato válido", () => {
  const { Befine, localStorage } = cargar(["data.js"]);
  assert.equal(Befine.club.guardarRef("?ref=bef1a2b3"), "BEF1A2B3");
  assert.equal(Befine.club.refPendiente(), "BEF1A2B3");
  Befine.club.olvidarRef();
  assert.equal(Befine.club.refPendiente(), null);
  for (const malo of ["?ref=<script>", "?ref=BEF1234", "?ref=XYZ12345", "?otra=BEF1A2B3", ""]) {
    assert.equal(Befine.club.guardarRef(malo), null, malo);
  }
  assert.equal(localStorage.getItem("befine_ref"), null);
});

test("CP-U28d las reglas que muestra la tienda coinciden con los parámetros de la migración 08", () => {
  const { Befine } = cargar(["data.js"]);
  const sql = sql08();
  const par = (k) => Number((sql.match(new RegExp(`\\('${k}',\\s*'(\\d+)'`)) || [])[1]);
  const R = Befine.club.reglas;
  assert.equal(R.clpPorPunto, par("clp_por_punto"));
  assert.equal(R.bonoMin, par("club_bono_min_recargas"));
  assert.equal(R.bonoPuntos, par("club_bono_puntos"));
  assert.equal(R.referidoPuntos, par("club_referido_puntos"));
  // Premios 30 / 80 / 150 y tope del 50% = 6 recargas de $2.500
  for (const [cod, pts] of [["menor", 30], ["medio", 80], ["mayor", 150]]) {
    assert.match(sql, new RegExp(`\\('${cod}',[\\s\\S]*?\\n\\s*${pts},`), cod);
  }
  assert.match(sql, /'porcentaje', 50, 0, 7500/);
});

test("CP-U28e datos actuales de las variantes del carrito: a pedido y suma puntos", async () => {
  const filas = [{ id: "A", stock: 0, controla_stock: true, suma_puntos: true }, { id: "B", stock: 5, controla_stock: true, suma_puntos: false }];
  const cliente = { from: () => { const q = { select: () => q, in: () => Promise.resolve({ data: filas, error: null }) }; return q; } };
  const { Befine } = cargar(["data.js"], { cliente });
  const m = await Befine.infoVariantes(["A", "B"]);
  assert.deepEqual([m.get("A").a_pedido, m.get("A").suma_puntos, m.get("B").a_pedido, m.get("B").suma_puntos], [true, true, false, false]);
  assert.deepEqual([...(await Befine.disponibilidad(["A", "B"]))], ["A"]);
});
