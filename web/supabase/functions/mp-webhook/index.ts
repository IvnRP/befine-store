// =====================================================================
// Edge Function: mp-webhook  (Supabase · Deno) — HU-09
// ---------------------------------------------------------------------
// Recibe las notificaciones de pago de Mercado Pago y, si el pago está
// aprobado, confirma el pedido con confirmar_pago() (migración 03):
// pendiente_pago → pagado → en_preparacion, descuenta stock y suma puntos.
//
// Seguridad:
//  - Nunca se confía en el cuerpo de la notificación: el pago se CONSULTA
//    a la API de Mercado Pago con el Access Token (secreto).
//  - confirmar_pago() verifica que el monto pagado = total del pedido y es
//    idempotente (si Mercado Pago repite el aviso, no duplica nada).
//  - Si existe el secreto MP_WEBHOOK_SECRET, se valida además la firma
//    x-signature que envía Mercado Pago.
//  - Esta función se publica con "Verify JWT" DESACTIVADO, porque Mercado
//    Pago no envía un JWT de Supabase.
//
// Secretos (Supabase → Edge Functions → Secrets):
//   MP_ACCESS_TOKEN    = Access Token de Mercado Pago (obligatorio)
//   MP_WEBHOOK_SECRET  = clave secreta de Webhooks de Mercado Pago (recomendado)
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los entrega Supabase automáticamente.
// =====================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const MP_TOKEN = Deno.env.get("MP_ACCESS_TOKEN");
const MP_SECRET = Deno.env.get("MP_WEBHOOK_SECRET");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function ok(body: unknown = { ok: true }, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function hmacHex(clave: string, texto: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(clave), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const firma = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(firma)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Firma de Mercado Pago: x-signature = "ts=...,v1=..."; manifiesto "id:<data.id>;request-id:<x-request-id>;ts:<ts>;"
async function firmaValida(req: Request, dataId: string) {
  if (!MP_SECRET) return true; // sin secreto configurado, la seguridad descansa en consultar el pago a la API
  const sig = req.headers.get("x-signature") ?? "";
  const reqId = req.headers.get("x-request-id") ?? "";
  const partes = Object.fromEntries(sig.split(",").map((p) => p.trim().split("=").map((s) => s.trim())));
  if (!partes.ts || !partes.v1) return false;
  const id = /^[a-z0-9]+$/i.test(dataId) ? dataId.toLowerCase() : dataId;
  const manifiesto = `id:${id};request-id:${reqId};ts:${partes.ts};`;
  return (await hmacHex(MP_SECRET, manifiesto)) === partes.v1;
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") return ok({ error: "Método no permitido" }, 405);
  if (!MP_TOKEN) return ok({ error: "Falta el secreto MP_ACCESS_TOKEN" }, 500);

  // El id del pago puede venir en el cuerpo (Webhooks) o en la URL (IPN)
  const url = new URL(req.url);
  let body: any = {};
  try { body = await req.json(); } catch (_) { /* IPN sin cuerpo */ }
  const tipo = String(body?.type ?? body?.topic ?? url.searchParams.get("type") ?? url.searchParams.get("topic") ?? "");
  const paymentId = String(body?.data?.id ?? url.searchParams.get("data.id") ?? url.searchParams.get("id") ?? "");

  // Solo interesan los avisos de pago; el resto se confirma con 200 para que MP no reintente
  if (tipo !== "payment" || !/^\d+$/.test(paymentId)) return ok({ ok: true, ignorado: tipo || "sin_tipo" });

  if (!(await firmaValida(req, paymentId))) {
    console.warn("Firma de Mercado Pago inválida", paymentId);
    return ok({ error: "Firma inválida" }, 401);
  }

  // 1. Consultar el pago real a Mercado Pago
  const r = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, {
    headers: { Authorization: `Bearer ${MP_TOKEN}` },
  });
  if (!r.ok) {
    console.error("Consultar pago", r.status, await r.text());
    return ok({ error: "No se pudo consultar el pago" }, 502); // MP reintentará
  }
  const pago = await r.json();
  const pedidoId = String(pago.external_reference ?? pago.metadata?.pedido_id ?? "");

  if (!UUID.test(pedidoId)) {
    console.warn("Pago sin pedido asociado", paymentId);
    return ok({ ok: true, ignorado: "sin_pedido" });
  }
  // Pendiente o rechazado: el pedido sigue en pendiente_pago; se informa y no se reintenta
  if (pago.status !== "approved") return ok({ ok: true, pedido: pedidoId, estado_pago: pago.status });

  // 2. Confirmar el pedido en la base (solo service_role puede hacerlo)
  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const { data, error } = await sb.rpc("confirmar_pago", {
    p_pedido: pedidoId,
    p_mp_payment_id: String(pago.id),
    p_monto: Math.round(Number(pago.transaction_amount)),
    p_raw: {
      id: pago.id, status: pago.status, status_detail: pago.status_detail,
      transaction_amount: pago.transaction_amount, payment_method_id: pago.payment_method_id,
      payment_type_id: pago.payment_type_id, date_approved: pago.date_approved,
      payer_email: pago.payer?.email ?? null,
    },
    p_mp_preference_id: pago.metadata?.preference_id ?? null,
  });
  if (error) {
    console.error("confirmar_pago", error);
    return ok({ error: "No se pudo confirmar el pago" }, 500); // MP reintentará
  }
  if (data && data.ok === false) console.warn("confirmar_pago no aplicado", pedidoId, data);
  return ok({ ok: true, pedido: pedidoId, resultado: data });
});
