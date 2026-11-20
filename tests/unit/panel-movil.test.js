/* Panel en el celular (web/admin.html, js/admin.js, js/admin-avisos.js, css/admin.css) — 3 pruebas
   Caso CP-U38: "Atrás" del celular no saca del panel, hay flecha ← y botón a la tienda visibles,
   y el aviso de pedido puede sonar (desbloqueo con un toque y pantalla encendida). */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const web = path.join(__dirname, "..", "..", "web");
const leer = (f) => fs.readFileSync(path.join(web, f), "utf8");

test("CP-U38a Atrás cierra el detalle o vuelve a la sección anterior sin salir del panel", () => {
  const js = leer("js/admin.js");
  assert.match(js, /if \(!ya\) empujar\("detalle"\);/);                 // abrir un pedido agrega una entrada
  assert.match(js, /if \(!ya\) empujar\("modal"\);/);
  assert.match(js, /if \(!desdeHistorial && actual && id !== actual\) empujar\("sec", "#" \+ id\);/);
  assert.match(js, /window\.addEventListener\("popstate"/);
  assert.match(js, /function cerrarModal\(\) \{/);                         // sin argumentos: seguro como listener de click
  assert.doesNotMatch(js, /history\.replaceState\(null, "", "#" \+ id\)/);
});

test("CP-U38b en el celular se ven la flecha ←, la tienda y salir (íconos)", () => {
  const h = leer("admin.html");
  assert.match(h, /id="pnAtras"[^>]*aria-label="Volver atrás"/);
  assert.match(h, /class="pn-btn ghost pn-tienda" href="index\.html" aria-label="Ver tienda"/);
  const css = leer("css/admin.css");
  assert.doesNotMatch(css, /\.pn-top \.pn-btn\.ghost\[href\] \{ display: none; \}/);   // antes se ocultaba "Ver tienda"
  assert.match(css, /\.pn-tienda \.txt, \.pn-salir \.txt \{ display: none; \}/);
  assert.match(css, /\.pn-shell \{ grid-template-columns: 1fr; align-content: start; \}/);
});

test("CP-U38c el sonido del aviso se desbloquea con el primer toque y la pantalla no se apaga", () => {
  const js = leer("js/admin-avisos.js");
  assert.match(js, /\["pointerdown", "keydown"\]\.forEach/);
  assert.match(js, /navigator\.wakeLock\.request\("screen"\)/);
  assert.match(js, /const sono = await sonar\(\);/);                      // al activar la campana suena para probar
});
