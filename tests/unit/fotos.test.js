/* Pruebas de las fotos de productos (web/js/data.js, web/js/ui.js) — 3 pruebas
   Casos CP-U27 del Plan de Pruebas: URL de la foto desde la ruta del bucket "productos" (migración 07),
   versión liviana para tarjetas y carrito, y miniatura del carrito sin confiar en localStorage. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const BASE = "https://tbnevbvvwwzpnowxqyps.supabase.co/storage/v1/object/public/productos/";

test("CP-U27a la foto se arma desde la ruta del bucket; tarjetas usan la versión de 400 px y la ficha la de 1000 px", () => {
  const { Befine } = cargar(["data.js"]);
  assert.equal(Befine.foto("bidon-12l-1000.webp"), BASE + "bidon-12l-1000.webp");
  assert.equal(Befine.foto("bidon-12l-1000.webp", "sm"), BASE + "bidon-12l-400.webp");
  assert.equal(Befine.foto("https://otro.cl/a.jpg", "sm"), "https://otro.cl/a.jpg");   // URL completa: se respeta
  assert.equal(Befine.foto(" "), null);
  assert.equal(Befine.foto(null, "sm"), null);                                       // sin foto: degradado
});

test("CP-U27b miniatura del carrito: usa la foto solo si es una URL https segura; si no, el degradado", () => {
  const w = cargar(["data.js", "ui.js"]);
  assert.match(w.fondoItem({ foto: BASE + "bidon-12l-400.webp", grad: "red" }), /url\('https:\/\/tbnevbvvwwzpnowxqyps/);
  for (const malo of ["javascript:alert(1)", "https://x.cl/a.webp') ; color:red", "http://x.cl/a.webp", ""]) {
    assert.equal(w.fondoItem({ foto: malo, grad: "red" }), "background:red", malo);
  }
});

test("CP-U27c la migración 07 asigna foto a los 11 productos y siempre la versión -1000.webp", () => {
  const dir = path.join(__dirname, "..", "..", "web", "supabase", "migrations");
  const archivo = fs.readdirSync(dir).find((f) => /_07_fotos_productos\.sql$/.test(f));
  assert.ok(archivo, "falta la migración 07");
  const sql = fs.readFileSync(path.join(dir, archivo), "utf8");
  const filas = [...sql.matchAll(/\('(BEF-[A-Z0-9-]+)',\s*'([^']+)'\)/g)];
  assert.equal(new Set(filas.map((m) => m[1])).size, 11);
  assert.ok(filas.every((m) => /^[a-z0-9-]+-1000\.webp$/.test(m[2])));
});
