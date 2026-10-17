// =====================================================================
// Edge Function: resenas-google  (Supabase · Deno)
// ---------------------------------------------------------------------
// Consulta Google Places API (New) y devuelve la nota, el total y hasta
// 5 reseñas reales de Agua Purificada Befine, en el formato que usa la
// home (Befine.getResenas en js/data.js).
//
// Secretos requeridos (Supabase → Edge Functions → Secrets):
//   GOOGLE_PLACES_KEY  = clave de API de Google (restringida a Places API (New))
// Opcional:
//   GOOGLE_PLACE_ID    = Place ID del negocio (si no, usa el de abajo)
//
// La clave de Google vive SOLO aquí (servidor). Nunca en el navegador.
// =====================================================================

const PLACE_ID = Deno.env.get("GOOGLE_PLACE_ID") ?? "ChIJeYwZwvzpd2ERzvv77dwJwAE";
const API_KEY = Deno.env.get("GOOGLE_PLACES_KEY");
const URL_ESCRIBIR = "https://g.page/r/Cc77--3cCcABEBM/review"; // enlace oficial para dejar reseña

// POLÍTICA DE COSTO CERO: se consulta a Google como máximo 1 vez por hora
// por instancia y se reutiliza la respuesta para todos los visitantes.
// (1.000 consultas gratis/mes en el SKU de reseñas → ~24/día queda muy abajo.)
const CACHE_MS = 60 * 60 * 1000;
let cache: { t: number; body: unknown } | null = null;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!API_KEY) return json({ error: "Falta el secreto GOOGLE_PLACES_KEY" }, 500);

  if (cache && Date.now() - cache.t < CACHE_MS) return json(cache.body);

  try {
    const url = `https://places.googleapis.com/v1/places/${PLACE_ID}?languageCode=es&regionCode=CL`;
    const r = await fetch(url, {
      headers: {
        "X-Goog-Api-Key": API_KEY,
        // Pide SOLO los campos necesarios (Google cobra según los campos).
        "X-Goog-FieldMask": "rating,userRatingCount,googleMapsUri,googleMapsLinks,reviews",
      },
    });
    if (!r.ok) {
      const detalle = await r.text();
      console.error("Places API", r.status, detalle);
      return json({ error: `Google respondió ${r.status}` }, 502);
    }
    const p = await r.json();

    const body = {
      fuente: "Google",
      promedio: p.rating ?? null,
      total: p.userRatingCount ?? 0,
      url_resenas: p.googleMapsLinks?.reviewsUri ?? p.googleMapsUri ?? null,
      url_escribir: URL_ESCRIBIR,
      items: (p.reviews ?? []).map((rv: any) => ({
        autor: rv.authorAttribution?.displayName ?? "Cliente de Google",
        autor_url: rv.authorAttribution?.uri ?? null,
        foto: rv.authorAttribution?.photoUri ?? null,
        estrellas: rv.rating ?? 0,
        fecha: rv.relativePublishTimeDescription ?? "",
        texto: rv.text?.text ?? rv.originalText?.text ?? "",
        url: rv.googleMapsUri ?? null,
      })),
    };
    cache = { t: Date.now(), body };
    return json(body);
  } catch (e) {
    console.error(e);
    return json({ error: "Error interno al leer reseñas" }, 500);
  }
});
