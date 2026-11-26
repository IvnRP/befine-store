/* Auditoría de seguridad (25-nov) — 5 pruebas
   Caso CP-U45: el webhook de Mercado Pago exige una firma válida (#1); la migración 22 (cupones, pedidos
   sin pago, permisos y direcciones: #2, #3, #5, #7) trae su reversa y su prueba en seco; y lo "pendiente de
   revisar": lo que viene de la base no se pinta como HTML (XSS) y las cabeceras CSP/HSTS del hosting. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { cargar } = require("../helpers/cargar");

const RAIZ = path.join(__dirname, "..", "..");
const leer = (...p) => fs.readFileSync(path.join(RAIZ, ...p), "utf8");
const MALO = `<img src=x onerror="alert(1)">`;

test("CP-U45a Befine.esc y la tarjeta de producto no dejan pasar HTML", () => {
  const W = cargar(["data.js", "cards.js"]);
  W.catGrad = () => "linear-gradient(#000,#fff)";
  assert.equal(W.Befine.esc(`<b a="1">&'`), "&lt;b a=&quot;1&quot;&gt;&amp;&#39;");
  assert.equal(W.Befine.esc(null), "");
  const html = W.productCardHTML({ id: "p1", slug: "x", nombre: MALO, categoria: MALO, categoria_slug: "recargas",
    imagen_url: null, desde_precio: 2500, variantes: [{ id: "v1", nombre: MALO, precio: 2500 }] });
  assert.doesNotMatch(html, /<img src=x/);
  assert.doesNotMatch(html, /onerror="/);
  assert.match(html, /&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/);
});

test("CP-U45b las páginas públicas escapan nombres de productos, categorías, variantes y carrito", () => {
  const js = (f) => leer("web", "js", f);
  assert.doesNotMatch(js("cards.js"), /\$\{p\.(nombre|categoria)\}/);
  assert.doesNotMatch(js("catalogo.js"), /\$\{c\.(slug|nombre)\}/);
  assert.match(js("catalogo.js"), /CSS\.escape\(estado\.categoria\)/);
  assert.doesNotMatch(js("home.js"), /\$\{(prod|v)\.nombre\}/);
  assert.doesNotMatch(js("producto.js"), /<h1>\$\{p\.nombre\}|\$\{p\.categoria\}|cat=\$\{p\.categoria_slug\}|\$\{v\.nombre\}/);
  assert.doesNotMatch(js("ui.js"), /\$\{i\.(nombre|variante|variante_id)\}/);
  assert.doesNotMatch(js("checkout.js"), /\$\{i\.variante_id\}/);
});

test("CP-U45c la CSP calza con los <script> en línea de cada página y es igual en Cloudflare y nginx", () => {
  const cf = leer("deploy", "_headers"), ng = leer("docker", "nginx.conf");
  const cspCf = (cf.match(/Content-Security-Policy: (.+)/) || [])[1];
  const cspNg = (ng.match(/Content-Security-Policy "([^"]+)"/) || [])[1];
  assert.ok(cspCf && cspNg, "falta la CSP");
  assert.equal(cspCf.trim(), cspNg);
  for (const d of ["default-src 'self'", "object-src 'none'", "base-uri 'self'", "frame-ancestors 'self'", "form-action 'self'"]) assert.ok(cspCf.includes(d), d);
  assert.doesNotMatch(cspCf, /script-src[^;]*'unsafe-(inline|eval)'/);
  const huellas = new Set();
  for (const f of fs.readdirSync(path.join(RAIZ, "web")).filter((x) => x.endsWith(".html"))) {
    const html = leer("web", f);
    assert.doesNotMatch(html, /\son(click|load|error|submit|change|input)=/i, f + " tiene un manejador en línea");
    for (const m of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
      const h = "'sha256-" + crypto.createHash("sha256").update(m[1], "utf8").digest("base64") + "'";
      huellas.add(h);
      assert.ok(cspCf.includes(h), `${f}: su <script> en línea cambió; actualiza la huella ${h} en _headers y nginx.conf`);
    }
  }
  assert.ok(huellas.size >= 1);
  assert.match(cf, /Strict-Transport-Security: max-age=31536000/);
  assert.match(ng, /Strict-Transport-Security "max-age=31536000"/);
});

test("CP-U45d webhook de Mercado Pago: firma en tiempo constante, marca de tiempo razonable y solo CLP", () => {
  const ts = leer("web", "supabase", "functions", "mp-webhook", "index.ts");
  const trozo = (nombre) => { const i = ts.indexOf("function " + nombre); return ts.slice(i, ts.indexOf("\n}\n", i) + 2); };
  const cte = ts.match(/const MAX_FUTURO_MS[^\n]+/)[0];
  const fns = new Function(`${cte}\n${trozo("igualSeguro")}\n${trozo("tsRazonable")}\nreturn { igualSeguro, tsRazonable };`.replace(/: string/g, ""))();
  assert.equal(fns.igualSeguro("abc", "abc"), true);
  assert.equal(fns.igualSeguro("abc", "abd"), false);
  assert.equal(fns.igualSeguro("abc", "abcd"), false);
  const ahora = Date.now();
  assert.equal(fns.tsRazonable(String(Math.floor(ahora / 1000)), ahora), true);        // segundos
  assert.equal(fns.tsRazonable(String(ahora - 3600e3), ahora), true);                 // milisegundos, 1 h atrás (reintento)
  assert.equal(fns.tsRazonable(String(ahora + 3600e3), ahora), false);                // 1 h en el futuro
  assert.equal(fns.tsRazonable(String(ahora - 8 * 864e5), ahora), false);             // más de 7 días
  assert.equal(fns.tsRazonable("abc", ahora), false);
  assert.match(ts, /igualSeguro\(await hmacHex\(MP_SECRET, manifiesto\)/);
  assert.doesNotMatch(ts, /\) === partes\.v1/);
  assert.match(ts, /currency_id !== "CLP"/);
});

test("CP-U45e la migración 22 trae reversa y prueba en seco con todos los casos", () => {
  const dir = path.join(RAIZ, "web", "supabase", "migrations");
  const base = "20261125_22_seguridad_auditoria";
  const m = fs.readFileSync(path.join(dir, base + ".sql"), "utf8");
  assert.ok(fs.existsSync(path.join(dir, base + "_reversa.sql")));
  const p = fs.readFileSync(path.join(dir, "20261125_22_prueba_en_seco.sql"), "utf8");
  for (const t of ["T01", "T05", "T06", "T07", "T08", "T09", "T10b", "T11", "T13", "T14"]) assert.match(p, new RegExp("'" + t + " "), t);
  assert.match(m, /function public\.vencer_pedidos_pendientes/);
  assert.match(m, /revoke execute on function public\.vencer_pedidos_pendientes\(integer\) from public, anon, authenticated/);
  assert.match(m, /security definer/i);
  assert.doesNotMatch(m, /usos_actuales = usos_actuales \+ 1[\s\S]{0,200}crear_pedido/);
});
