// =====================================================================
// Edge Function: enviar-correo  (Supabase · Deno) — HU-10 / RF-09
// ---------------------------------------------------------------------
// Envía UNA vez el correo de confirmación de compra (Resend) cuando el
// pedido ya está pagado (o es un canje de $0 del Club Befine).
//
// Quién la llama:
//  - mp-webhook, al confirmar un pago (con la clave de servicio).
//  - La tienda, al mostrar un pedido pagado o un canje de $0 (con la sesión
//    del cliente): solo funciona para pedidos del propio cliente.
// Como el envío es idempotente, que la llamen dos veces no duplica el correo.
//
// Seguridad:
//  - Se publica con "Verify JWT" DESACTIVADO y valida aquí mismo: o es la
//    clave de servicio (llamada interna) o es un usuario cuyo pedido se lee
//    con SU sesión (el RLS garantiza que es suyo).
//  - "Reserva" el envío en la base (correo_confirmacion_at) antes de enviar,
//    con un UPDATE condicional: dos llamadas simultáneas no envían dos correos.
//    Si Resend falla, se libera la reserva y se guarda el error para reintentar.
//
// Secretos (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY   = clave de Resend (obligatoria)
//   CORREO_REMITENTE = "Befine <pedidos@aguabefine.cl>" cuando el dominio esté verificado
//                      (por defecto el remitente de pruebas de Resend)
//   SITE_URL         = URL de la tienda (ya existe para crear-pago)
// SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY los entrega Supabase.
// =====================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import { armarCorreo, PROVEEDOR, type PedidoCorreo } from "./plantilla.ts";

const RESEND_KEY = Deno.env.get("RESEND_API_KEY");
const REMITENTE = Deno.env.get("CORREO_REMITENTE") ?? "Befine <onboarding@resend.dev>";
const SITE_URL = (Deno.env.get("SITE_URL") ?? "http://localhost:8080").replace(/\/+$/, "");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAGADOS = ["pagado", "en_preparacion", "en_ruta", "entregado"];
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  if (!RESEND_KEY) return json({ error: "Falta el secreto RESEND_API_KEY" }, 500);

  let body: { pedido_id?: string } = {};
  try { body = await req.json(); } catch (_) { /* sin cuerpo */ }
  const pedidoId = String(body.pedido_id ?? "");
  if (!UUID.test(pedidoId)) return json({ error: "Pedido no válido" }, 400);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Falta la sesión" }, 401);
  const srv = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  // 1. ¿Quién llama? Clave de servicio (mp-webhook) o un cliente que solo puede pedir SU pedido
  if (token !== SERVICE_KEY) {
    const usr = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: u, error: eu } = await usr.auth.getUser(token);
    if (eu || !u?.user) return json({ error: "Sesión no válida" }, 401);
    const { data: propio } = await usr.from("pedidos").select("id").eq("id", pedidoId).maybeSingle();   // RLS: solo los suyos
    if (!propio) return json({ error: "Pedido no encontrado" }, 404);
  }

  // 2. Reservar el envío: solo si está pagado y aún no se envió (evita duplicados)
  const { data: reservado, error: er } = await srv.from("pedidos")
    .update({ correo_confirmacion_at: new Date().toISOString(), correo_error: null })
    .eq("id", pedidoId).is("correo_confirmacion_at", null).in("estado", PAGADOS)
    .select("id").maybeSingle();
  if (er) { console.error("reservar envío", er); return json({ error: "No se pudo preparar el correo" }, 500); }
  if (!reservado) return json({ ok: true, enviado: false, motivo: "ya_enviado_o_no_pagado" });

  // 3. Datos del pedido (con la clave de servicio: montos y productos tal como se cobraron)
  const { data: p, error: ep } = await srv.from("pedidos")
    .select("numero,contacto_nombre,contacto_email,fecha_entrega,subtotal,costo_despacho,descuento_cupon,total," +
            "tipo_documento,es_canje,puntos_ganados,terminos_version,terminos_aceptados_at," +
            "direccion:direcciones(calle,numero,depto,comuna,referencia)," +
            "detalle_pedido(cantidad,precio_unitario,subtotal,variante:variantes_producto(nombre,producto:productos(nombre)))")
    .eq("id", pedidoId).maybeSingle();

  const liberar = async (motivo: string) => {
    await srv.from("pedidos").update({ correo_confirmacion_at: null, correo_error: motivo.slice(0, 300) }).eq("id", pedidoId);
  };
  if (ep || !p || !p.contacto_email) { await liberar("Sin datos del pedido o sin correo"); return json({ error: "Pedido sin correo de contacto" }, 422); }

  const pedido: PedidoCorreo = {
    ...(p as any),
    lineas: ((p as any).detalle_pedido || []).map((d: any) => ({
      cantidad: d.cantidad, precio_unitario: d.precio_unitario, subtotal: d.subtotal,
      producto: d.variante?.producto?.nombre ?? "Producto", variante: d.variante?.nombre ?? null,
    })),
  };
  const correo = armarCorreo(pedido, SITE_URL);

  // 4. Enviar con Resend
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json", "Idempotency-Key": `pedido-${pedidoId}` },
    body: JSON.stringify({ from: REMITENTE, to: [p.contacto_email], reply_to: PROVEEDOR.correo,
                           subject: correo.asunto, html: correo.html, text: correo.texto }),
  });
  const res = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error("Resend", r.status, res);
    await liberar(`Resend ${r.status}: ${res?.message ?? "error"}`);
    return json({ error: "No se pudo enviar el correo", detalle: res?.message ?? null }, 502);
  }
  await srv.from("pedidos").update({ correo_confirmacion_id: res?.id ?? null }).eq("id", pedidoId);
  return json({ ok: true, enviado: true, id: res?.id ?? null });
});
