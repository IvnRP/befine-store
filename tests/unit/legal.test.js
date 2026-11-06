/* Pruebas de la información legal de la tienda (web/js/data.js) — 4 pruebas
   Casos CP-U25 del Plan de Pruebas (HU-25): identificación del proveedor, derecho a retracto por
   tipo de producto y coherencia de la versión de los textos legales con la base (migración 06). */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const { Befine } = cargar(["data.js"]);

test("CP-U25a la identificación del proveedor trae todos los campos que exige el Reglamento de Comercio Electrónico", () => {
  for (const campo of ["nombre_fantasia", "razon_social", "rut", "domicilio", "representante_legal", "correo"]) {
    assert.ok(campo in Befine.proveedor, campo);
  }
  assert.match(Befine.proveedor.razon_social, /E\.I\.R\.L\./);
});

test("CP-U25b bidones, recargas y packs: derecho a retracto solo con sello intacto y la advertencia usa la expresión legal", () => {
  for (const cat of ["recargas", "bidones", "packs"]) {
    const r = Befine.retractoDe(cat);
    assert.equal(r.condicionado, true, cat);
    assert.match(r.titulo, /^Derecho a retracto/);
    assert.match(r.texto, /sello/);
  }
});

test("CP-U25c dispensadores y productos sin categoría: derecho a retracto de 10 días sin condición de sello", () => {
  for (const cat of ["dispensadores", null, undefined]) {
    const r = Befine.retractoDe(cat);
    assert.equal(r.aplica, true);
    assert.equal(r.condicionado, false);
    assert.match(r.titulo, /10 días/);
  }
});

test("CP-U25d la versión de los textos legales coincide con la que registra la base (migración 06)", () => {
  const dir = path.join(__dirname, "..", "..", "web", "supabase", "migrations");
  const archivo = fs.readdirSync(dir).find((f) => /_06_aceptacion_terminos\.sql$/.test(f));
  assert.ok(archivo, "falta la migración 06");
  const sql = fs.readFileSync(path.join(dir, archivo), "utf8");
  const m = sql.match(/'terminos_version',\s*'([^']+)'/);
  assert.ok(m, "la migración 06 no define terminos_version");
  assert.equal(Befine.legalVersion, m[1]);
});
