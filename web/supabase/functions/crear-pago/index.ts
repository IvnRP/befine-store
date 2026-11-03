// =====================================================================
// Edge Function: crear-pago  (Supabase · Deno) — HU-08 / HU-09
// ---------------------------------------------------------------------
// Recibe { pedido_id } desde la tienda y crea una preferencia de pago de
// Mercado Pago Checkout Pro. Devuelve { init_point } para redirigir al
// cliente a la página de pago de Mercado Pago.
//
// Seguridad (SC-03):
//  - El MONTO se toma de la base (pedidos.total calculado por crear_pedido()),
//    nunca del navegador.
//  - El pedido se lee con la sesión del propio cliente: el RLS garantiza que
//    solo puede pagar SUS pedidos (o un admin).
//  - Solo se cobran pedidos en estado 'pendiente_pago'.
//
// Secretos requeridos (Supabase → Edge Functions → Secrets):
//   MP_ACCESS_TOKEN = Access Token de Mercado Pago (de prueba en desarrollo)
//   SITE_URL        = URL de la tienda, sin "/" final (ej: http://localhost:8080)
// SUPABASE_URL y SUPABASE_ANON_KEY los entrega Supabase automáticamente.
// El token de Mercado Pago vive SOLO aquí (servidor). Nunca en el navegador.
// =====================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const MP_TOKEN = Deno.env.get("MP_ACCESS_TOKEN");
const SITE_URL = (Deno.env.get("SITE_URL") ?? "http://localhost:8080").replace(/\/+$/, "");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  if (!MP_TOKEN) return json({ error: "Falta el secreto MP_ACCESS_TOKEN" }, 500);

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "Debes iniciar sesión o continuar como invitado." }, 401);

  let pedidoId = "";
  try {
    pedidoId = String((await req.json()).pedido_id ?? "");
  } catch (_) { /* cuerpo inválido */ }
  if (!UUID.test(pedidoId)) return json({ error: "Pedido no válido." }, 400);

  // Cliente con la sesión del usuario: el RLS filtra los pedidos que puede ver.
  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });

  const { data: p, error } = await sb
    .from("pedidos")
    .select("id, numero, estado, total, contacto_nombre, contacto_email, detalle_pedido(cantidad, variantes_producto(nombre, productos(nombre)))")
    .eq("id", pedidoId)
    .maybeSingle();

  if (error) {
    console.error("Leer pedido", error);
    return json({ error: "No pudimos leer el pedido." }, 500);
  }
  if (!p) return json({ error: "Pedido no encontrado." }, 404);
  if (p.estado !== "pendiente_pago") return json({ error: "Este pedido ya no está pendiente de pago." }, 409);
  if (!p.total || p.total <= 0) return json({ error: "El pedido no tiene un total válido." }, 400);

  // Descripción legible: "2× Recarga 20L, 1× Dispensador..."
  const detalle = (p.detalle_pedido ?? [])
    .map((d: any) => {
      const v = d.variantes_producto;
      const nombre = v?.productos?.nombre ? `${v.productos.nombre}${v.nombre ? " " + v.nombre : ""}` : (v?.nombre ?? "Producto");
      return `${d.cantidad}× ${nombre}`;
    })
    .join(", ")
    .slice(0, 250);

  // Un solo ítem por el TOTAL del servidor (incluye despacho y descuentos).
  const vuelta = (estado: string) => `${SITE_URL}/checkout.html?pago=${estado}&pedido=${p.id}`;
  const preferencia: Record<string, unknown> = {
    items: [{
      id: p.id,
      title: `Pedido Befine #${p.numero}`,
      description: detalle || `Pedido Befine #${p.numero}`,
      quantity: 1,
      currency_id: "CLP",
      unit_price: p.total,
    }],
    payer: { name: p.contacto_nombre ?? undefined, email: p.contacto_email ?? undefined },
    external_reference: p.id,
    back_urls: { success: vuelta("ok"), pending: vuelta("pendiente"), failure: vuelta("error") },
    notification_url: `${SUPABASE_URL}/functions/v1/mp-webhook`,
    statement_descriptor: "BEFINE",
    metadata: { pedido_id: p.id, numero: p.numero },
  };
  // Mercado Pago solo acepta auto_return con URLs públicas (https).
  if (SITE_URL.startsWith("https://")) preferencia.auto_return = "approved";

  try {
    const r = await fetch("https://api.mercadopago.com/checkout/preferences", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${MP_TOKEN}`,
        "Content-Type": "application/json",
        "X-Idempotency-Key": `pref-${p.id}-${p.total}`,
      },
      body: JSON.stringify(preferencia),
    });
    const mp = await r.json();
    if (!r.ok) {
      console.error("Mercado Pago", r.status, mp);
      return json({ error: "Mercado Pago no pudo crear el pago. Inténtalo de nuevo." }, 502);
    }
    return json({ preference_id: mp.id, init_point: mp.init_point, numero: p.numero, total: p.total });
  } catch (e) {
    console.error(e);
    return json({ error: "Sin conexión con Mercado Pago." }, 502);
  }
});
