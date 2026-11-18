/* Avisos de pedidos nuevos en el panel (web/js/admin-logic.js → pedidosNuevos) — 2 pruebas
   Caso CP-U36: suena solo con pedidos pagados que el panel no había visto. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);

test("CP-U36a solo avisa los pedidos que no se habían visto, del más antiguo al más nuevo", () => {
  const vistos = new Set(["a", "b"]);
  const lista = [{ id: "d", numero: 62 }, { id: "c", numero: 60 }, { id: "b", numero: 59 }, { id: "a", numero: 58 }];
  assert.equal(L.pedidosNuevos(vistos, lista).map((p) => p.numero).join(","), "60,62");
  assert.equal(L.pedidosNuevos(new Set(["a", "b", "c", "d"]), lista).length, 0);   // (arreglos de otro contexto: se compara el largo)
  assert.equal(L.pedidosNuevos(vistos, null).length, 0);
});

test("CP-U36b el panel carga el aviso y su sonido; el webhook avisa al dueño solo en la primera confirmación", () => {
  const web = path.join(__dirname, "..", "..", "web");
  assert.match(fs.readFileSync(path.join(web, "admin.html"), "utf8"), /<script src="js\/admin-avisos\.js"><\/script>/);
  assert.ok(fs.existsSync(path.join(web, "assets", "sonidos", "caja-registradora.mp3")));
  const wh = fs.readFileSync(path.join(web, "supabase", "functions", "mp-webhook", "index.ts"), "utf8");
  assert.match(wh, /if \(data && data\.ok === true && !data\.repetido\) await avisarDueno\(sb, pedidoId\);/);
  assert.match(wh, /"Idempotency-Key": `aviso-\$\{pedidoId\}`/);
});
