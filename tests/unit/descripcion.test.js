/* Enlaces dentro de la descripción de un producto (web/js/data.js → Befine.enlaceTienda) — 2 pruebas
   Caso CP-U32: solo se aceptan enlaces a la propia tienda; el resto queda como texto. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { Befine } = cargar(["data.js"]);

test("CP-U32a acepta enlaces a la propia tienda", () => {
  for (const u of [
    "https://aguabefine.cl/producto?id=7f3c2a1e-0b4d-4c55-9a1e-2b3c4d5e6f70",
    "https://www.aguabefine.cl/catalogo?cat=packs",
    "https://aguabefine.cl",
    "producto.html?id=7f3c2a1e-0b4d-4c55-9a1e-2b3c4d5e6f70",
    "catalogo?cat=packs",
    "/como-funciona",
    "despacho.html#cobertura",
  ]) assert.equal(Befine.enlaceTienda(u), true, u);
});

test("CP-U32b rechaza otros dominios y esquemas peligrosos", () => {
  for (const u of [
    "javascript:alert(1)",
    "data:text/html,hola",
    "https://otra-tienda.cl/producto",
    "https://aguabefine.cl.evil.com/x",
    "http://aguabefine.cl/producto",
    "//evil.com",
    "producto?id=1\" onmouseover=\"x",
    "",
  ]) assert.equal(Befine.enlaceTienda(u), false, u);
});
