/* SEO técnico (auditoría 18-nov-2026) — 8 pruebas
   Casos CP-U33: texto para buscadores, datos estructurados de producto, sitemap, redirecciones de
   Shopify por producto, etiquetas de vista previa/ícono/canónica y un solo H1 en el inicio. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");
const { urlsDe, sitemapXML, PAGINAS } = require("../../deploy/sitemap.js");

const { Befine } = cargar(["data.js"]);
const RAIZ = path.join(__dirname, "..", "..");
const leer = (r) => fs.readFileSync(path.join(RAIZ, r), "utf8");

const prod = {
  id: "4ec5bff2-2afe-40b4-bf78-0ab183cf1231", nombre: "Recarga Bidón 20 Litros", categoria: "Recargas",
  imagen_url: "bidon-20l-befine-1000.webp",
  descripcion: "Agua purificada en bidón de 20 litros.\n\n• Envío gratis.\n¿Sin bidón? Elige [Bidón + Recarga](producto?id=abc).",
  variantes: [
    { sku: "BEF-REC-20-BEFINE", nombre: "Con bidón Befine", precio: 2500, a_pedido: false },
    { sku: "BEF-REC-20-OTRA", nombre: "Bidón de otra marca", precio: 2990, a_pedido: true },
  ],
};

test("CP-U33a textoPlano quita los enlaces [texto](dirección) y los saltos de línea", () => {
  assert.equal(Befine.textoPlano(prod.descripcion), "Agua purificada en bidón de 20 litros. • Envío gratis. ¿Sin bidón? Elige Bidón + Recarga.");
  const corto = Befine.textoPlano(prod.descripcion, 30);
  assert.ok(corto.length <= 30 && corto.endsWith("…"), corto);
  assert.equal(Befine.textoPlano(null), "");
});

test("CP-U33b datos estructurados Product: una oferta por variante, en CLP y con disponibilidad", () => {
  const ld = Befine.productoLD(prod);
  assert.equal(ld["@type"], "Product");
  assert.equal(ld.url, "https://aguabefine.cl/producto?id=" + prod.id);
  assert.equal(ld.offers.length, 2);
  assert.deepEqual(ld.offers.map((o) => [o.price, o.priceCurrency, o.availability.split("/").pop()]),
    [[2500, "CLP", "InStock"], [2990, "CLP", "BackOrder"]]);
  assert.ok(!ld.description.includes("]("), "la descripción no debe llevar la sintaxis de enlaces");
});

test("CP-U33c sitemap: páginas públicas + una ficha por producto, con & escapado", () => {
  const urls = urlsDe(["a1", "b2"]);
  assert.equal(urls.length, PAGINAS.length + 2);
  assert.ok(urls.includes("https://aguabefine.cl/") && urls.includes("https://aguabefine.cl/producto?id=a1"));
  const xml = sitemapXML(["https://aguabefine.cl/x?a=1&b=2"]);
  assert.match(xml, /<loc>https:\/\/aguabefine\.cl\/x\?a=1&amp;b=2<\/loc>/);
  assert.ok(!urls.some((u) => /checkout|cuenta|admin|\.html/.test(u)), "solo direcciones canónicas e indexables");
});

test("CP-U33d cada producto de Shopify redirige a su ficha, antes de la regla general /products/*", () => {
  const r = leer("deploy/_redirects").split("\n").filter((l) => l.trim() && !l.startsWith("#"));
  const general = r.findIndex((l) => l.startsWith("/products/* "));
  const especificas = r.map((l, i) => [l, i]).filter(([l]) => /^\/products\/[a-z0-9-]+\s/.test(l));
  assert.equal(especificas.length, 11);
  for (const [l, i] of especificas) {
    assert.ok(i < general, "debe ir antes de /products/*: " + l);
    assert.match(l, /\s\/producto\?id=[0-9a-f-]{36}\s+301$/);
  }
});

test("CP-U33e robots.txt publica el sitemap y construir.sh copia robots y genera el sitemap", () => {
  assert.match(leer("deploy/robots.txt"), /^Sitemap: https:\/\/aguabefine\.cl\/sitemap\.xml$/m);
  const sh = leer("deploy/construir.sh");
  assert.match(sh, /cp deploy\/robots\.txt dist\/robots\.txt/);
  assert.match(sh, /node deploy\/sitemap\.js dist/);
});

test("CP-U33f páginas públicas con ícono, canónica y vista previa para WhatsApp/redes", () => {
  for (const f of ["index", "catalogo", "como-funciona", "despacho", "terminos", "privacidad", "cambios"]) {
    const h = leer(`web/${f}.html`);
    assert.match(h, /<link rel="icon" href="favicon\.ico"/, f);
    assert.match(h, new RegExp(`<link rel="canonical" href="https://aguabefine\\.cl/${f === "index" ? "" : f}">`), f);
    assert.match(h, /<meta property="og:image" content="https:\/\/aguabefine\.cl\/assets\/og-befine\.jpg">/, f);
  }
  for (const a of ["web/favicon.ico", "web/apple-touch-icon.png", "web/assets/og-befine.jpg", "web/assets/icon-192.png"]) {
    assert.ok(fs.existsSync(path.join(RAIZ, a)), "falta " + a);
  }
});

test("CP-U33g el inicio tiene un solo H1 y sus datos de negocio local (LocalBusiness)", () => {
  const h = leer("web/index.html");
  assert.equal((h.match(/<h1[\s>]/g) || []).length, 1);
  const ld = JSON.parse(h.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
  assert.equal(ld["@type"], "LocalBusiness");
  assert.equal(ld.areaServed.length, 5);
  assert.equal(ld.telephone, "+" + Befine.contacto.whatsapp);
});

test("CP-U33h página 404 propia: no se indexa y sus enlaces funcionan desde cualquier ruta", () => {
  const h = leer("web/404.html");
  assert.match(h, /<meta name="robots" content="noindex">/);
  assert.match(h, /<base href="\/">/);
  assert.equal((h.match(/<h1[\s>]/g) || []).length, 1);
  assert.match(leer("web/cuenta.html"), /<meta name="robots" content="noindex">/);
});
