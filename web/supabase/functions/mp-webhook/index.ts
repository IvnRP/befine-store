// =====================================================================
// Edge Function: mp-webhook  (Supabase · Deno) — HU-09
// ---------------------------------------------------------------------
// Recibe las notificaciones de pago de Mercado Pago y, si el pago está
// aprobado, confirma el pedido con confirmar_pago() (migración 03):
// pendiente_pago → pagado → en_preparacion, descuenta stock y suma puntos.
// Después pide a enviar-correo la confirmación de compra por correo (HU-10) y
// avisa al dueño por correo con el resumen del pedido (el panel además suena con admin-avisos.js).
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
//   AVISO_PEDIDOS_EMAIL = correo del dueño para el aviso de pedido nuevo (opcional;
//                         por defecto befine.cl@gmail.com, el contacto del negocio)
// RESEND_API_KEY y CORREO_REMITENTE ya existen (los usa enviar-correo).
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los entrega Supabase automáticamente.
// =====================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const MP_TOKEN = Deno.env.get("MP_ACCESS_TOKEN");
const MP_SECRET = Deno.env.get("MP_WEBHOOK_SECRET");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_API_KEY");
const REMITENTE = Deno.env.get("CORREO_REMITENTE") ?? "Befine <onboarding@resend.dev>";
const AVISO_EMAIL = Deno.env.get("AVISO_PEDIDOS_EMAIL") ?? "befine.cl@gmail.com";

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

const clp = (n: number) => "$" + Math.round(Number(n) || 0).toLocaleString("es-CL");
const escHtml = (s: unknown) => String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));

// Aviso al dueño por CORREO cuando un pedido queda PAGADO (solo la primera vez, nunca en los avisos
// repetidos de Mercado Pago). Usa Resend, igual que el correo al cliente. Un fallo aquí NUNCA hace
// fallar el webhook (el pago ya quedó confirmado).
async function avisarDueno(sb: ReturnType<typeof createClient>, pedidoId: string) {
  if (!RESEND_KEY || !AVISO_EMAIL) return;
  try {
    const { data: p, error } = await sb.from("pedidos")
      .select("numero,total,contacto_nombre,contacto_telefono,fecha_entrega,direccion:direcciones(calle,numero,comuna)," +
              "detalle_pedido(cantidad,subtotal,variante:variantes_producto(nombre,producto:productos(nombre)))")
      .eq("id", pedidoId).maybeSingle();
    if (error || !p) { console.warn("avisarDueno: pedido", error); return; }
    const q = p as any;
    const filas = (q.detalle_pedido ?? []).map((d: any) => {
      const v = d.variante ?? {}, nom = v.producto?.nombre ?? "Producto";
      const det = v.nombre && v.nombre !== "Estándar" ? ` (${escHtml(v.nombre)})` : "";
      return `<tr><td style="padding:4px 8px">${d.cantidad} x ${escHtml(nom)}${det}</td><td style="padding:4px 8px;text-align:right">${clp(d.subtotal)}</td></tr>`;
    }).join("");
    const dir = q.direccion ? `${escHtml(q.direccion.calle)} ${escHtml(q.direccion.numero)}, ${escHtml(q.direccion.comuna)}` : "";
    const entrega = q.fecha_entrega ? String(q.fecha_entrega).split("-").reverse().join("-") : "estándar (24 a 48 h hábiles)";
    const html = `<div style="font-family:Arial,sans-serif;font-size:15px;color:#10333f">
      <h2 style="margin:0 0 8px">Nuevo pedido #${q.numero} · ${clp(q.total)}</h2>
      <p style="margin:0 0 12px">${escHtml(q.contacto_nombre)} · ${escHtml(q.contacto_telefono ?? "")}<br>${dir}<br>Entrega: ${entrega}</p>
      <table style="border-collapse:collapse">${filas}</table>
      <p style="margin:16px 0 0"><a href="https://aguabefine.cl/admin#pedidos">Abrir el panel de pedidos</a></p></div>`;
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json", "Idempotency-Key": `aviso-${pedidoId}` },
      body: JSON.stringify({
        from: REMITENTE, to: [AVISO_EMAIL],
        subject: `Nuevo pedido #${q.numero} · ${clp(q.total)} · ${q.direccion?.comuna ?? ""}`,
        html, text: `Nuevo pedido #${q.numero} · ${clp(q.total)} · ${q.contacto_nombre ?? ""} · ${dir.replace(/<[^>]+>/g, "")}`,
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (!r.ok) console.warn("avisarDueno", r.status, await r.text());
  } catch (e) { console.warn("avisarDueno", e); }
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

  // Aviso al dueño por correo: solo cuando el pago se confirmó AHORA (no en avisos repetidos)
  if (data && data.ok === true && !data.repetido) await avisarDueno(sb, pedidoId);

  // 3. Correo de confirmación de compra (HU-10, exigido por ley). Es idempotente: si Mercado
  //    Pago repite el aviso, no se duplica. Un fallo del correo NO hace fallar el webhook
  //    (el pago ya quedó confirmado); la tienda lo vuelve a intentar al mostrar el pedido.
  if (data && (data.ok === true || data.repetido)) {
    try {
      const rc = await fetch(`${SUPABASE_URL}/functions/v1/enviar-correo`, {
        method: "POST",
        headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ pedido_id: pedidoId }),
      });
      if (!rc.ok) console.warn("enviar-correo", rc.status, await rc.text());
    } catch (e) { console.warn("enviar-correo", e); }
  }
  return ok({ ok: true, pedido: pedidoId, resultado: data });
});
