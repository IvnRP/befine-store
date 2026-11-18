/* =====================================================================
   sitemap.js — Genera dist/sitemap.xml al publicar (lo llama deploy/construir.sh)
   Incluye las páginas públicas y una ficha por cada producto ACTIVO, leído de
   Supabase con la clave pública (la misma que usa la tienda; solo lectura).
   Si la base no responde, el sitemap sale igual con las páginas (no frena la publicación).
   Uso: node deploy/sitemap.js dist
   ===================================================================== */
const fs = require("node:fs");
const path = require("node:path");

const SITIO = "https://aguabefine.cl";
// Cloudflare Pages quita el .html: estas son las direcciones canónicas
const PAGINAS = ["/", "/catalogo", "/como-funciona", "/despacho", "/terminos", "/privacidad", "/cambios"];

const escXml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]));

/* Direcciones del sitemap: páginas + fichas de producto */
/* productos: [{ id, slug }] → /productos/<slug> (migración 16); sin slug, la dirección antigua ?id= */
function urlsDe(productos = []) {
  return [
    ...PAGINAS.map((p) => SITIO + p),
    ...productos.map((p) => p.slug ? SITIO + "/productos/" + encodeURIComponent(p.slug) : SITIO + "/producto?id=" + encodeURIComponent(p.id)),
  ];
}

function sitemapXML(urls) {
  return '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
    urls.map((u) => `  <url><loc>${escXml(u)}</loc></url>`).join("\n") +
    "\n</urlset>\n";
}

/* URL y clave pública de Supabase: se leen de web/js/data.js (una sola fuente) */
function credenciales() {
  const js = fs.readFileSync(path.join(__dirname, "..", "web", "js", "data.js"), "utf8");
  const url = (js.match(/const SUPABASE_URL = "([^"]+)"/) || [])[1];
  const key = (js.match(/const SUPABASE_ANON_KEY = "([^"]+)"/) || [])[1];
  if (!url || !key) throw new Error("no se encontró SUPABASE_URL / SUPABASE_ANON_KEY en data.js");
  return { url, key };
}

async function productosActivos() {
  const { url, key } = credenciales();
  const r = await fetch(`${url}/rest/v1/productos?select=id,slug&activo=eq.true&order=nombre`, {
    headers: { apikey: key, Authorization: `Bearer ${key}` },
    signal: AbortSignal.timeout(15000),
  });
  if (!r.ok) throw new Error("Supabase respondió " + r.status);
  return (await r.json()).map((p) => ({ id: p.id, slug: p.slug || null }));
}

module.exports = { SITIO, PAGINAS, urlsDe, sitemapXML };

if (require.main === module) {
  (async () => {
    const salida = process.argv[2] || "dist";
    let ids = [];
    try { ids = await productosActivos(); }
    catch (e) { console.warn("Aviso: sitemap sin fichas de producto (" + e.message + ")"); }
    fs.writeFileSync(path.join(salida, "sitemap.xml"), sitemapXML(urlsDe(ids)));
    console.log(`sitemap.xml: ${PAGINAS.length} páginas + ${ids.length} productos`);
  })();
}
