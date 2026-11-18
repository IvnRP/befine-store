/* Dirección amigable del producto en el panel (web/js/admin-logic.js) — 2 pruebas
   Caso CP-U34: slugDe (misma regla que public.slug_de) y su validación. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);

test("CP-U34a slugDe arma la dirección desde el nombre (sin tildes, ñ ni símbolos)", () => {
  assert.equal(L.slugDe("Bidón + Recarga 12 Litros"), "bidon-recarga-12-litros");
  assert.equal(L.slugDe("  Niño  Ñandú!! "), "nino-nandu");
  assert.equal(L.slugDe("Pack Inicial — 3 Bidones de 20 Litros"), "pack-inicial-3-bidones-de-20-litros");
  assert.equal(L.slugDe("—"), "");
  assert.ok(L.slugDe("a ".repeat(100)).length <= 80);
});

test("CP-U34b validarProducto: la dirección es opcional y, si viene, con formato válido", () => {
  const base = { nombre: "Recarga Bidón 20 Litros", categoria_id: 1 };
  assert.deepEqual(Object.keys(L.validarProducto({ ...base, slug: "" })), []);
  assert.deepEqual(Object.keys(L.validarProducto({ ...base, slug: "recarga-agua-purificada-bidon-20-litros" })), []);
  for (const s of ["Con Mayúsculas", "con espacios", "doble--guion", "-al-inicio", "tilde-bidón", "x".repeat(81)])
    assert.ok(L.validarProducto({ ...base, slug: s }).slug, s);
});
