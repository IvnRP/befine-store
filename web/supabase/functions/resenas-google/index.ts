// =====================================================================
// Edge Function: resenas-google  (Supabase · Deno)        v7 · 2026-10-09
// ---------------------------------------------------------------------
// Consulta Google Places API (New) y devuelve la nota, el total y hasta
// 5 reseñas reales de Agua Purificada Befine, en el formato que usa la
// home (Befine.getResenas en js/data.js).
//
// Es pública (verify_jwt = false) porque la home la ve cualquier visitante.
// Para que nadie pueda gastar la cuota de Google llamándola en bucle:
//   1. Caché de 1 hora en memoria (todas las visitas reutilizan la respuesta).
//   2. Una sola consulta a Google a la vez (las visitas simultáneas esperan
//      la misma respuesta en vez de llamar cada una a Google).
//   3. Si Google falla: se sirve la última respuesta buena; si no hay, se
//      espera 5 minutos antes de reintentar (no se llama a Google en cada visita).
//   4. Cache-Control: el navegador reutiliza la respuesta y no vuelve a
//      llamar a la función en cada carga de página.
//
// Secretos (Supabase → Edge Functions → Secrets):
//   GOOGLE_PLACES_KEY  = clave de API de Google (restringida a Places API (New))
// Opcional:
//   GOOGLE_PLACE_ID    = Place ID del negocio (si no, usa el de abajo)
// La clave de Google vive SOLO aquí (servidor). Nunca en el navegador.
// =====================================================================

const PLACE_ID = Deno.env.get("GOOGLE_PLACE_ID") ?? "ChIJSanzCtbHYpYRbaEOsyMHQlI";
const API_KEY = Deno.env.get("GOOGLE_PLACES_KEY");
const URL_ESCRIBIR = "https://g.page/r/Cc77--3cCcABEBM/review"; // enlace oficial para dejar reseña

const CACHE_MS = 60 * 60 * 1000;        // respuesta buena: 1 hora
const ERROR_MS = 5 * 60 * 1000;         // tras un error: no reintentar por 5 minutos
const BROWSER_MAX_AGE = 30 * 60;        // navegador: 30 minutos (segundos)

let cache: { t: number; body: unknown } | null = null;   // última respuesta buena
let errorHasta = 0;                                       // no llamar a Google antes de esta hora
let enCurso: Promise<unknown> | null = null;              // consulta a Google en progreso

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: unknown, status = 200, maxAge = 0) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS,
      "Content-Type": "application/json",
      "Cache-Control": maxAge > 0 ? `public, max-age=${maxAge}` : "no-store",
    },
  });
}

async function consultarGoogle(): Promise<unknown> {
  const url = `https://places.googleapis.com/v1/places/${PLACE_ID}?languageCode=es&regionCode=CL`;
  const r = await fetch(url, {
    headers: {
      "X-Goog-Api-Key": API_KEY!,
      // Pide SOLO los campos necesarios (Google cobra según los campos).
      "X-Goog-FieldMask": "rating,userRatingCount,googleMapsUri,googleMapsLinks,reviews",
    },
  });
  if (!r.ok) {
    console.error("Places API", r.status, await r.text());
    throw new Error(`Google respondió ${r.status}`);
  }
  const p = await r.json();
  return {
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
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!API_KEY) return json({ error: "Falta el secreto GOOGLE_PLACES_KEY" }, 500);

  const ahora = Date.now();

  // 1. Caché vigente
  if (cache && ahora - cache.t < CACHE_MS) return json(cache.body, 200, BROWSER_MAX_AGE);

  // 3. Google falló hace poco: servir lo último bueno o un error, sin llamar a Google
  if (ahora < errorHasta) {
    if (cache) return json(cache.body, 200, 300);
    return json({ error: "Reseñas no disponibles por el momento" }, 503);
  }

  // 2. Una sola consulta a Google a la vez
  if (!enCurso) {
    enCurso = consultarGoogle()
      .then((body) => { cache = { t: Date.now(), body }; errorHasta = 0; return body; })
      .finally(() => { enCurso = null; });
  }

  try {
    const body = await enCurso;
    return json(body, 200, BROWSER_MAX_AGE);
  } catch (e) {
    console.error(e);
    errorHasta = Date.now() + ERROR_MS;
    if (cache) return json(cache.body, 200, 300);   // respuesta anterior, aunque esté vencida
    return json({ error: "Reseñas no disponibles por el momento" }, 503);
  }
});
