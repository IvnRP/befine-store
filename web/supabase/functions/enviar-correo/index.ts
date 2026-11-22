// =====================================================================
// Edge Function: enviar-correo  (Supabase · Deno) — HU-10 / RF-09
// ---------------------------------------------------------------------
// Envía UNA vez el correo de confirmación de compra (Resend) cuando el
// pedido ya está pagado (o es un canje de $0 del Club Befine).
// Con { tipo: "documento" } envía la boleta o factura del pedido con el PDF
// ADJUNTO (migración 20): la llama el panel al subir el documento y solo la
// puede usar quien tiene el permiso documentos.gestionar.
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
import { armarCorreo, armarCorreoDocumento, nombreAdjunto, PROVEEDOR, type PedidoCorreo } from "./plantilla.ts";

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

  let body: { pedido_id?: string; tipo?: string; reenviar?: boolean } = {};
  try { body = await req.json(); } catch (_) { /* sin cuerpo */ }
  const pedidoId = String(body.pedido_id ?? "");
  if (!UUID.test(pedidoId)) return json({ error: "Pedido no válido" }, 400);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Falta la sesión" }, 401);
  const srv = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  // Boleta o factura con el PDF adjunto (panel → al subir el documento)
  if (body.tipo === "documento") return await enviarDocumento(srv, token, pedidoId, body.reenviar === true);

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
    id: pedidoId,                                   // enlace "Repetir este pedido" del correo
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

// =====================================================================
// Boleta o factura por correo (migración 20)
// ---------------------------------------------------------------------
//  - Solo con el permiso documentos.gestionar (se pregunta a la base con la sesión de quien llama).
//  - Reserva el envío en documentos_tributarios.correo_enviado_at con un UPDATE condicional: dos clics
//    no envían dos correos. "reenviar" vuelve a enviarlo (p. ej. el cliente lo perdió), como máximo
//    una vez cada 2 minutos. Si Resend falla, se deja como estaba y se guarda el motivo (correo_error).
//  - El PDF se lee del bucket privado "documentos" con la clave de servicio y va ADJUNTO, así le llega
//    también a quien compró como invitado. Va con copia oculta a befine.cl@gmail.com (respaldo).
// =====================================================================
const MAX_ADJUNTO = 3 * 1024 * 1024;   // igual que el límite del bucket
// Copia oculta (CCO) de cada boleta/factura enviada, para el respaldo del negocio (decisión del dueño 22-nov-2026).
// Se puede cambiar con el secreto CORREO_COPIA_DOCUMENTOS; vacío = sin copia.
const COPIA_DOCUMENTOS = (Deno.env.get("CORREO_COPIA_DOCUMENTOS") ?? PROVEEDOR.correo).trim();

function aBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// deno-lint-ignore no-explicit-any
async function enviarDocumento(srv: any, token: string, pedidoId: string, reenviar: boolean): Promise<Response> {
  // 1. Permiso de quien llama
  if (token !== SERVICE_KEY) {
    const usr = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: u, error: eu } = await usr.auth.getUser(token);
    if (eu || !u?.user) return json({ error: "Sesión no válida" }, 401);
    const { data: puede } = await usr.rpc("tiene_permiso", { p_permiso: "documentos.gestionar" });
    if (puede !== true) return json({ error: "No tienes permiso para enviar boletas o facturas." }, 403);
  }

  // 2. Documento emitido del pedido (estado previo, para dejarlo igual si el envío falla)
  const { data: d0, error: e0 } = await srv.from("documentos_tributarios")
    .select("id,tipo,folio,archivo,razon_social,monto_total,correo_enviado_at,correo_destino,correo_id")
    .eq("pedido_id", pedidoId).eq("estado", "emitido").maybeSingle();
  if (e0) { console.error("documento", e0); return json({ error: "No se pudo leer el documento" }, 500); }
  if (!d0 || !d0.archivo) return json({ ok: false, enviado: false, motivo: "sin_documento", mensaje: "El pedido aún no tiene su PDF subido." });
  if (d0.correo_enviado_at && !reenviar) return json({ ok: true, enviado: false, motivo: "ya_enviado", destino: d0.correo_destino, enviado_at: d0.correo_enviado_at });

  // 3. Reservar el envío (condicional: evita duplicados)
  const ahora = new Date();
  let q = srv.from("documentos_tributarios").update({ correo_enviado_at: ahora.toISOString(), correo_error: null })
    .eq("id", d0.id).eq("estado", "emitido").eq("folio", d0.folio);
  q = d0.correo_enviado_at
    ? q.lt("correo_enviado_at", new Date(ahora.getTime() - 2 * 60 * 1000).toISOString())   // reenviar: máx. 1 cada 2 min
    : q.is("correo_enviado_at", null);
  const { data: reservado, error: er } = await q.select("id").maybeSingle();
  if (er) { console.error("reservar documento", er); return json({ error: "No se pudo preparar el correo" }, 500); }
  if (!reservado) return json({ ok: true, enviado: false, motivo: reenviar ? "recien_enviado" : "ya_enviado",
                                mensaje: reenviar ? "Se envió hace un momento. Espera 2 minutos para reenviarlo." : undefined });

  const liberar = async (motivo: string) => {
    await srv.from("documentos_tributarios").update({ correo_enviado_at: d0.correo_enviado_at ?? null, correo_error: motivo.slice(0, 300) })
      .eq("id", d0.id);
  };

  // 4. Datos del pedido y del cliente
  const { data: p } = await srv.from("pedidos").select("numero,contacto_nombre,contacto_email,perfil_id,total").eq("id", pedidoId).maybeSingle();
  if (!p || !p.contacto_email) { await liberar("El pedido no tiene correo de contacto"); return json({ error: "El pedido no tiene correo de contacto" }, 422); }
  let conCuenta = false;
  if (p.perfil_id) {
    const { data: au } = await srv.auth.admin.getUserById(p.perfil_id);
    conCuenta = !!au?.user && !au.user.is_anonymous && !!au.user.email;
  }

  // 5. PDF del bucket privado
  const { data: blob, error: eb } = await srv.storage.from("documentos").download(d0.archivo);
  if (eb || !blob) { await liberar("No se encontró el PDF en el bucket"); return json({ error: "No se encontró el PDF del documento" }, 404); }
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (!bytes.length || bytes.length > MAX_ADJUNTO) { await liberar("PDF vacío o de más de 3 MB"); return json({ error: "El PDF está vacío o pesa más de 3 MB" }, 422); }

  // 6. Enviar con Resend (PDF adjunto)
  const correo = armarCorreoDocumento({
    numero: p.numero, contacto_nombre: p.contacto_nombre, tipo: d0.tipo, folio: d0.folio,
    total: d0.monto_total ?? p.total, razon_social: d0.razon_social, con_cuenta: conCuenta,
  }, SITE_URL);
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json",
               "Idempotency-Key": reenviar ? `dte-${d0.id}-${d0.folio}-${ahora.getTime()}` : `dte-${d0.id}-${d0.tipo}-${d0.folio}` },
    body: JSON.stringify({ from: REMITENTE, to: [p.contacto_email], reply_to: PROVEEDOR.correo,
                           ...(COPIA_DOCUMENTOS && COPIA_DOCUMENTOS.toLowerCase() !== String(p.contacto_email).toLowerCase()
                             ? { bcc: [COPIA_DOCUMENTOS] } : {}),
                           subject: correo.asunto, html: correo.html, text: correo.texto,
                           attachments: [{ filename: nombreAdjunto(d0.tipo, d0.folio), content: aBase64(bytes) }] }),
  });
  const res = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error("Resend documento", r.status, res);
    await liberar(`Resend ${r.status}: ${res?.message ?? "error"}`);
    return json({ error: "No se pudo enviar el correo", detalle: res?.message ?? null }, 502);
  }
  await srv.from("documentos_tributarios").update({ correo_destino: p.contacto_email, correo_id: res?.id ?? null }).eq("id", d0.id);
  return json({ ok: true, enviado: true, destino: p.contacto_email, id: res?.id ?? null });
}
