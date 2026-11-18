/* Velocidad de carga (auditoría 18-nov-2026) — 3 pruebas
   Caso CP-U35: librería de Supabase local y fija, conexiones anticipadas, foto principal precargada
   y logo liviano. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const WEB = path.join(__dirname, "..", "..", "web");
const html = fs.readdirSync(WEB).filter((f) => f.endsWith(".html"));
const leer = (f) => fs.readFileSync(path.join(WEB, f), "utf8");

test("CP-U35a todas las páginas usan la copia local y fija de supabase-js (sin CDN externo)", () => {
  const archivo = fs.readdirSync(path.join(WEB, "vendor")).find((f) => /^supabase-js-\d+\.\d+\.\d+\.min\.js$/.test(f));
  assert.ok(archivo, "falta web/vendor/supabase-js-X.Y.Z.min.js");
  for (const f of html) {
    const h = leer(f);
    assert.ok(!/cdn\.jsdelivr\.net/.test(h), f + " todavía carga desde jsdelivr");
    assert.match(h, new RegExp(`<script src="/?vendor/${archivo.replace(/\./g, "\\.")}"></script>`), f);
    assert.match(h, /<link rel="preconnect" href="https:\/\/tbnevbvvwwzpnowxqyps\.supabase\.co" crossorigin>/, f);
  }
  assert.match(fs.readFileSync(path.join(WEB, "..", "deploy", "_headers"), "utf8"), /\/vendor\/\*\n\s+Cache-Control: public, max-age=31536000, immutable/);
});

test("CP-U35b el inicio precarga la foto de la Recarga 20 L y no descarga fuentes que no usa", () => {
  const h = leer("index.html");
  assert.match(h, /<link rel="preload" as="image" href="[^"]+bidon-20l-befine-400\.webp" fetchpriority="high">/);
  assert.ok(!/Bodoni/.test(h), "Bodoni Moda no se usa en ningún estilo");
});

test("CP-U35c el logo se sirve en WebP (más liviano que el PNG)", () => {
  for (const n of ["logo-befine", "logo-befine-noche"]) {
    const webp = fs.statSync(path.join(WEB, "assets", n + ".webp")).size;
    const png = fs.statSync(path.join(WEB, "assets", n + ".png")).size;
    assert.ok(webp < png, n);
  }
  for (const f of [...html, "js/shell.js", "js/theme.js", "css/shell.css"]) assert.ok(!/logo-befine(-noche)?\.png/.test(leer(f)), f);
});
