/* Pruebas de despacho, fechas de entrega y formato CLP (web/js/data.js) — 10 pruebas
   Casos CP-U08 a CP-U11 del Plan de Pruebas. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { Befine } = cargar(["data.js"]);

// Misma forma que devuelve Befine.getCobertura() (datos reales del schema)
const cobertura = {
  envioGratisDesde: 7000,
  comunas: [
    { comuna: "Quilicura", costo: 2500 },   // migración 15: Quilicura paga igual que el resto bajo $7.000
    { comuna: "Huechuraba", costo: 2500 },
    { comuna: "Recoleta", costo: 2500 },
  ],
};

test("CP-U11 formato de pesos chilenos", () => {
  assert.equal(Befine.clp(2500), "$2.500");
  assert.equal(Befine.clp(1234567), "$1.234.567");
  assert.equal(Befine.clp(0), "$0");
});

test("CP-U08a Quilicura paga $2.500 bajo $7.000 y tiene envío gratis desde $7.000 (migración 15)", () => {
  assert.equal(Befine.costoDespacho(cobertura, "Quilicura", 2500), 2500);
  assert.equal(Befine.costoDespacho(cobertura, "Quilicura", 6999), 2500);
  assert.equal(Befine.costoDespacho(cobertura, "Quilicura", 7000), 0);
});

test("CP-U08d sin conexión a la base, ninguna comuna queda con despacho gratis sin mínimo", async () => {
  const resp = await Befine.getCobertura();   // en las pruebas no hay base: devuelve el respaldo de data.js
  assert.equal(resp.envioGratisDesde, 7000);
  assert.ok(resp.comunas.length > 0);
  for (const c of resp.comunas) assert.ok(c.costo > 0, c.comuna + " no debería tener despacho $0");
});

test("CP-U08b comuna con tarifa paga despacho bajo el mínimo", () => {
  assert.equal(Befine.costoDespacho(cobertura, "Huechuraba", 5000), 2500);
  assert.equal(Befine.costoDespacho(cobertura, "Huechuraba", 6999), 2500);
});

test("CP-U08c envío gratis desde $7.000 (límite incluido)", () => {
  assert.equal(Befine.costoDespacho(cobertura, "Huechuraba", 7000), 0);
  assert.equal(Befine.costoDespacho(cobertura, "Recoleta", 12000), 0);
});

test("CP-U09 comuna sin cobertura devuelve null (no permite continuar)", () => {
  assert.equal(Befine.costoDespacho(cobertura, "Las Condes", 10000), null);
  assert.equal(Befine.costoDespacho(cobertura, "", 10000), null);
});

test("CP-U10a entrega estándar al siguiente día hábil", () => {
  assert.equal(Befine.isoFecha(Befine.diasEntrega(new Date(2026, 9, 15, 15)).estandar), "2026-10-16"); // jueves -> viernes
  assert.equal(Befine.isoFecha(Befine.diasEntrega(new Date(2026, 9, 6, 10)).estandar), "2026-10-07");  // martes -> miércoles
  assert.equal(Befine.isoFecha(Befine.diasEntrega(new Date(2026, 9, 17, 10)).estandar), "2026-10-19"); // sábado -> lunes
});

test("CP-U10c no se entrega en feriados (mejora M-01)", () => {
  // viernes 09-10 -> lunes 12-10 es feriado -> martes 13-10
  assert.equal(Befine.isoFecha(Befine.diasEntrega(new Date(2026, 9, 9, 15)).estandar), "2026-10-13");
  // lunes 07-12 -> martes 08-12 es feriado -> miércoles 09-12
  assert.equal(Befine.isoFecha(Befine.diasEntrega(new Date(2026, 11, 7, 10)).estandar), "2026-12-09");
  // jueves 31-12 -> viernes 01-01 es feriado -> lunes 04-01
  assert.equal(Befine.isoFecha(Befine.diasEntrega(new Date(2026, 11, 31, 10)).estandar), "2027-01-04");
  // los feriados no aparecen como fechas agendables
  const isos = Array.from(Befine.diasEntrega(new Date(2026, 11, 1)).agendables, Befine.isoFecha);
  assert.ok(!isos.includes("2026-12-08") && !isos.includes("2026-12-25"));
});

test("CP-U10d rango de entrega 24 a 48 h hábiles (estandarHasta y siguienteHabil)", () => {
  const f = (d) => Befine.isoFecha(d);
  // jueves 15-10 -> llega entre viernes 16-10 y lunes 19-10 (salta el fin de semana)
  const jue = Befine.diasEntrega(new Date(2026, 9, 15, 15));
  assert.equal(f(jue.estandar), "2026-10-16");
  assert.equal(f(jue.estandarHasta), "2026-10-19");
  // viernes 09-10 (lunes 12-10 feriado) -> entre martes 13-10 y miércoles 14-10
  const vie = Befine.diasEntrega(new Date(2026, 9, 9, 15));
  assert.equal(f(vie.estandar), "2026-10-13");
  assert.equal(f(vie.estandarHasta), "2026-10-14");
  // siguienteHabil salta fines de semana y feriados
  assert.equal(f(Befine.siguienteHabil(new Date(2026, 9, 16))), "2026-10-19"); // viernes -> lunes
  assert.equal(f(Befine.siguienteHabil(new Date(2026, 9, 9))), "2026-10-13");  // viernes -> martes (lunes feriado)
  assert.equal(f(Befine.siguienteHabil(new Date(2026, 11, 31))), "2027-01-04"); // 31-12 -> lunes 04-01
  assert.equal(Befine.horarioReparto, "9:00 a 17:00");
});

test("CP-U10b 20 fechas agendables, en orden, sin sábados ni domingos y sin repetir", () => {
  const { agendables } = Befine.diasEntrega(new Date(2026, 9, 9));
  const isos = Array.from(agendables, Befine.isoFecha);   // Array de Node (el original viene del contexto aislado)
  assert.equal(isos.length, 20);
  assert.ok(Array.from(agendables).every((d) => d.getDay() !== 0 && d.getDay() !== 6));
  assert.equal(new Set(isos).size, 20);
  assert.deepEqual([...isos].sort(), isos);
});

test("CP-U10e texto del inicio 'Pide hoy y recibe …' con días y meses en español", () => {
  const f = (a, m, d) => new Date(a, m - 1, d);
  assert.equal(Befine.textoRangoEntrega(f(2026, 11, 19), f(2026, 11, 20)), "el jueves 19 o el viernes 20 de noviembre");
  assert.equal(Befine.textoRangoEntrega(f(2026, 11, 27), f(2026, 11, 30)), "el viernes 27 o el lunes 30 de noviembre");
  assert.equal(Befine.textoRangoEntrega(f(2026, 11, 30), f(2026, 12, 1)), "el lunes 30 de noviembre o el martes 1 de diciembre");
  assert.equal(Befine.textoRangoEntrega(f(2026, 11, 19)), "el jueves 19 de noviembre");
  // Con las fechas reales de la regla de entrega (jueves 15-10 → viernes 16 o lunes 19)
  const d = Befine.diasEntrega(new Date(2026, 9, 15, 15));
  assert.equal(Befine.textoRangoEntrega(d.estandar, d.estandarHasta), "el viernes 16 o el lunes 19 de octubre");
});

test("CP-U08e la cobertura se consulta una sola vez por página (carrito, inicio y checkout la comparten)", () => {
  assert.equal(Befine.getCobertura(), Befine.getCobertura());
});
