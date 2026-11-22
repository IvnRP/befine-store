// =====================================================================
// plantilla.ts — Correo de confirmación de compra (HU-10 / RF-09)
// ---------------------------------------------------------------------
// Funciones PURAS (sin red ni Deno): reciben el pedido y devuelven el
// asunto, el HTML y el texto del correo. Las usa index.ts y se prueban
// con node:test (tests/unit/correo.test.js).
//
// Contenido exigido por la ley chilena para la confirmación escrita de una
// compra a distancia (Ley 19.496 art. 12 A y Reglamento de Comercio
// Electrónico): identificación del proveedor, detalle de lo comprado,
// precio total con despacho, plazo de entrega, derecho a retracto y acceso
// a los Términos aceptados. Sin esta confirmación el retracto sube a 90 días.
// =====================================================================

// Debe coincidir con PROVEEDOR de web/js/data.js (lo verifica la prueba CP-U30c)
export const PROVEEDOR = {
  nombre_fantasia: "Agua Purificada Befine",
  razon_social: "Comercializadora de Agua Purificada e Insumos Iván Rodríguez Pinares E.I.R.L.",
  rut: "77.861.415-4",
  domicilio: "Pasaje Los Tailandeses 1156, Villa Juan Francisco Gonzales, Quilicura",
  correo: "befine.cl@gmail.com",
  whatsapp: "56958549641",
};
export const HORARIO_REPARTO = "9:00 a 17:00";

export type Linea = { cantidad: number; producto: string; variante?: string | null; precio_unitario: number; subtotal: number };
export type PedidoCorreo = {
  id?: string | null;                     // uuid del pedido: enlace "Repetir este pedido"
  numero: number;
  contacto_nombre?: string | null;
  contacto_email: string;
  fecha_entrega?: string | null;          // AAAA-MM-DD
  direccion?: { calle?: string; numero?: string; depto?: string | null; comuna?: string; referencia?: string | null } | null;
  lineas: Linea[];
  subtotal: number;
  costo_despacho: number;
  descuento_cupon: number;
  total: number;
  tipo_documento?: string | null;         // boleta | factura
  es_canje?: boolean;
  puntos_ganados?: number;
  terminos_version?: string | null;
  terminos_aceptados_at?: string | null;
};

export const esc = (s: unknown): string => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" } as Record<string, string>)[c]);
export const clp = (n: number): string => "$" + Math.round(Number(n) || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".");

export function fechaLarga(iso?: string | null): string {
  if (!iso || !/^\d{4}-\d{2}-\d{2}$/.test(iso)) return "por confirmar";
  return new Date(iso + "T12:00:00").toLocaleDateString("es-CL", { weekday: "long", day: "numeric", month: "long" });
}

const primerNombre = (n?: string | null) => (String(n || "").trim().split(/\s+/)[0] || "");
const textoVariante = (l: Linea) => (l.variante && l.variante !== "Estándar" ? ` (${l.variante})` : "");
function textoDireccion(d: PedidoCorreo["direccion"]): string {
  if (!d || !d.calle) return "";
  return `${d.calle} ${d.numero || ""}${d.depto ? ", depto " + d.depto : ""}, ${d.comuna || ""}`.replace(/\s+,/g, ",").trim();
}

/* Arma el correo. sitio = URL pública de la tienda (SITE_URL), sin "/" final. */
export function armarCorreo(p: PedidoCorreo, sitio: string): { asunto: string; html: string; texto: string } {
  const base = String(sitio || "").replace(/\/+$/, "");
  const nombre = primerNombre(p.contacto_nombre);
  const dir = textoDireccion(p.direccion);
  // El documento se emite en Haulmer y llega en otro correo, con el PDF adjunto, al subirlo al panel (migración 20).
  const docHtml = p.tipo_documento === "factura"
    ? "Pediste <b>factura</b>: te la enviaremos a este correo apenas la emitamos."
    : "Te enviaremos tu <b>boleta electrónica</b> a este correo apenas la emitamos.";
  const docTexto = docHtml.replace(/<[^>]+>/g, "");
  const asunto = `Befine: confirmación de tu pedido #${p.numero}`;
  const filas = (p.lineas || []).map((l) =>
    `<tr><td style="padding:6px 0">${esc(l.cantidad)} x ${esc(l.producto)}${esc(textoVariante(l))}</td>` +
    `<td style="padding:6px 0;text-align:right;white-space:nowrap">${clp(l.subtotal)}</td></tr>`).join("");
  const fila = (k: string, v: string, fuerte = false) =>
    `<tr><td style="padding:4px 0;color:#5F7484">${k}</td><td style="padding:4px 0;text-align:right;${fuerte ? "font-weight:700;font-size:16px" : ""}">${v}</td></tr>`;
  const retracto = `Tienes derecho a retracto dentro de 10 días desde la entrega. En bidones, recargas y packs con agua, solo si el sello de seguridad está intacto (agua para consumo humano).`;
  // Recompra en 1 toque: abre la tienda con este pedido cargado (Mi cuenta → checkout). Solo con un uuid válido.
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const urlRepetir = p.id && UUID.test(String(p.id)) && !p.es_canje ? `${base}/cuenta.html?repetir=${p.id}` : "";
  const aceptacion = p.terminos_version
    ? `Aceptaste los Términos y la Política de privacidad (versión ${esc(p.terminos_version)}) al comprar.`
    : `Al comprar aceptaste los Términos y la Política de privacidad.`;

  const html = `<!doctype html><html lang="es"><body style="margin:0;background:#F3F7FA;font-family:Arial,Helvetica,sans-serif;color:#13293A">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F3F7FA;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:14px;padding:24px">
<tr><td>
  <p style="margin:0;font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#0B7FC2;font-weight:700">Agua Purificada Befine</p>
  <h1 style="margin:6px 0 4px;font-size:22px">¡Gracias por tu compra${nombre ? ", " + esc(nombre) : ""}!</h1>
  <p style="margin:0 0 16px;color:#5F7484">${p.es_canje ? "Canjeaste un premio del Club Befine." : "Recibimos tu pago."} Este correo confirma tu pedido <b>#${esc(p.numero)}</b>.</p>

  <h2 style="font-size:15px;margin:16px 0 6px">Productos</h2>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;border-bottom:1px solid #E1E8ED">${filas}</table>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;margin-top:6px">
    ${fila("Subtotal", clp(p.subtotal))}
    ${p.descuento_cupon ? fila("Descuento", "−" + clp(p.descuento_cupon)) : ""}
    ${fila("Despacho", p.costo_despacho ? clp(p.costo_despacho) : "Gratis")}
    ${fila(p.es_canje ? "Total" : "Total pagado", clp(p.total), true)}
  </table>
  ${p.puntos_ganados ? `<p style="margin:10px 0 0;font-size:13px;color:#A3610B">Con esta compra sumas <b>${esc(p.puntos_ganados)} puntos</b> del Club Befine.</p>` : ""}
  ${urlRepetir ? `<p style="margin:16px 0 0"><a href="${esc(urlRepetir)}" style="display:inline-block;background:#F5A623;color:#13293A;font-weight:700;text-decoration:none;padding:12px 20px;border-radius:10px">Repetir este pedido</a></p>
  <p style="margin:6px 0 0;font-size:12px;color:#5F7484">La próxima vez, pídelo en 1 toque con los precios del día.</p>` : ""}

  <h2 style="font-size:15px;margin:18px 0 6px">Entrega</h2>
  <p style="margin:0;font-size:14px">${dir ? esc(dir) + "<br>" : ""}Fecha: <b>${esc(fechaLarga(p.fecha_entrega))}</b>, de ${HORARIO_REPARTO} h (sin hora exacta).
  En la entrega estándar el pedido puede llegar hasta el día hábil siguiente.</p>
  ${p.direccion && p.direccion.referencia ? `<p style="margin:4px 0 0;font-size:13px;color:#5F7484">Referencia: ${esc(p.direccion.referencia)}</p>` : ""}

  <h2 style="font-size:15px;margin:18px 0 6px">Documento</h2>
  <p style="margin:0;font-size:14px">${docHtml}</p>

  <h2 style="font-size:15px;margin:18px 0 6px">Tus derechos</h2>
  <p style="margin:0;font-size:13px;line-height:1.5">${retracto} <a href="${esc(base)}/cambios.html#retracto" style="color:#0B7FC2">Ver condiciones</a>.
  La garantía legal es de 6 meses. ${aceptacion} <a href="${esc(base)}/terminos.html" style="color:#0B7FC2">Términos</a> ·
  <a href="${esc(base)}/privacidad.html" style="color:#0B7FC2">Privacidad</a>.</p>

  <p style="margin:18px 0 0;font-size:14px">¿Dudas? Responde este correo o escríbenos por
  <a href="https://wa.me/${PROVEEDOR.whatsapp}?text=${encodeURIComponent("Hola Befine, consulta por mi pedido #" + p.numero)}" style="color:#0B7FC2">WhatsApp</a>.</p>
  <hr style="border:0;border-top:1px solid #E1E8ED;margin:20px 0 10px">
  <p style="margin:0;font-size:11.5px;color:#5F7484;line-height:1.5">${esc(PROVEEDOR.nombre_fantasia)} · ${esc(PROVEEDOR.razon_social)} · RUT ${esc(PROVEEDOR.rut)} · ${esc(PROVEEDOR.domicilio)} · ${esc(PROVEEDOR.correo)}</p>
</td></tr></table></td></tr></table></body></html>`;

  const texto = [
    `¡Gracias por tu compra${nombre ? ", " + nombre : ""}!`,
    `${p.es_canje ? "Canjeaste un premio del Club Befine." : "Recibimos tu pago."} Este correo confirma tu pedido #${p.numero}.`,
    "", "PRODUCTOS",
    ...(p.lineas || []).map((l) => `- ${l.cantidad} x ${l.producto}${textoVariante(l)}: ${clp(l.subtotal)}`),
    `Subtotal: ${clp(p.subtotal)}`,
    ...(p.descuento_cupon ? [`Descuento: -${clp(p.descuento_cupon)}`] : []),
    `Despacho: ${p.costo_despacho ? clp(p.costo_despacho) : "Gratis"}`,
    `${p.es_canje ? "Total" : "Total pagado"}: ${clp(p.total)}`,
    ...(p.puntos_ganados ? [`Sumas ${p.puntos_ganados} puntos del Club Befine.`] : []),
    ...(urlRepetir ? [`Repetir este pedido en 1 toque: ${urlRepetir}`] : []),
    "", "ENTREGA",
    ...(dir ? [dir] : []),
    `Fecha: ${fechaLarga(p.fecha_entrega)}, de ${HORARIO_REPARTO} h (sin hora exacta). En la entrega estándar puede llegar hasta el día hábil siguiente.`,
    "", "DOCUMENTO", docTexto,
    "", "TUS DERECHOS", retracto, `Condiciones: ${base}/cambios.html#retracto`,
    `Garantía legal: 6 meses. ${aceptacion.replace(/<[^>]+>/g, "")} Términos: ${base}/terminos.html`,
    "", `¿Dudas? Responde este correo o escríbenos por WhatsApp: https://wa.me/${PROVEEDOR.whatsapp}`,
    "", `${PROVEEDOR.nombre_fantasia} · ${PROVEEDOR.razon_social} · RUT ${PROVEEDOR.rut} · ${PROVEEDOR.domicilio} · ${PROVEEDOR.correo}`,
  ].join("\n");

  return { asunto, html, texto };
}

// =====================================================================
// Correo con la boleta o factura (migración 20): se envía al subir el PDF en el panel, con el
// documento ADJUNTO, a clientes con cuenta y a invitados. Funciones puras (tests/unit/correo-documento.test.js).
// =====================================================================
export type DocumentoCorreo = {
  numero: number;                    // n° del pedido
  contacto_nombre?: string | null;
  tipo: "boleta" | "factura" | string;
  folio: number | string;
  total: number;
  razon_social?: string | null;      // factura: a nombre de quién
  con_cuenta?: boolean;              // true: también la ve en Mi cuenta → Mis pedidos
};

const etiquetaDoc = (t: string) => (t === "factura" ? "Factura" : "Boleta");

/* Nombre del PDF adjunto: Boleta_Befine_N11298.pdf (solo letras y números: seguro para cualquier correo) */
export function nombreAdjunto(tipo: string, folio: number | string): string {
  return `${etiquetaDoc(tipo)}_Befine_N${String(folio).replace(/\D/g, "") || "0"}.pdf`;
}

export function armarCorreoDocumento(d: DocumentoCorreo, sitio: string): { asunto: string; html: string; texto: string } {
  const base = String(sitio || "").replace(/\/+$/, "");
  const nombre = primerNombre(d.contacto_nombre);
  const doc = etiquetaDoc(String(d.tipo));
  const genero = d.tipo === "factura" ? "tu factura" : "tu boleta";
  const asunto = `Befine: ${genero} N° ${d.folio} del pedido #${d.numero}`;
  const aNombre = d.tipo === "factura" && d.razon_social ? ` a nombre de <b>${esc(d.razon_social)}</b>` : "";
  const cuentaHtml = d.con_cuenta
    ? `<p style="margin:12px 0 0;font-size:14px">También queda guardada en <a href="${esc(base)}/cuenta.html" style="color:#0B7FC2">Mi cuenta → Mis pedidos</a>.</p>`
    : `<p style="margin:12px 0 0;font-size:14px">Guarda este correo: es tu respaldo de la compra.</p>`;

  const html = `<!doctype html><html lang="es"><body style="margin:0;background:#F3F7FA;font-family:Arial,Helvetica,sans-serif;color:#13293A">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F3F7FA;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:14px;padding:24px">
<tr><td>
  <p style="margin:0;font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#0B7FC2;font-weight:700">Agua Purificada Befine</p>
  <h1 style="margin:6px 0 4px;font-size:22px">${nombre ? "Hola " + esc(nombre) + ", aquí" : "Aquí"} está ${genero}</h1>
  <p style="margin:0;font-size:14px">Adjuntamos la <b>${doc.toLowerCase()} electrónica N° ${esc(d.folio)}</b>${aNombre} de tu pedido <b>#${esc(d.numero)}</b>
  por <b>${clp(d.total)}</b> (IVA incluido). Es un documento válido ante el SII.</p>
  ${cuentaHtml}
  <p style="margin:18px 0 0;font-size:14px">¿Algún dato no corresponde? Responde este correo o escríbenos por
  <a href="https://wa.me/${PROVEEDOR.whatsapp}?text=${encodeURIComponent("Hola Befine, consulta por la " + doc.toLowerCase() + " de mi pedido #" + d.numero)}" style="color:#0B7FC2">WhatsApp</a>.</p>
  <hr style="border:0;border-top:1px solid #E1E8ED;margin:20px 0 10px">
  <p style="margin:0;font-size:11.5px;color:#5F7484;line-height:1.5">${esc(PROVEEDOR.nombre_fantasia)} · ${esc(PROVEEDOR.razon_social)} · RUT ${esc(PROVEEDOR.rut)} · ${esc(PROVEEDOR.domicilio)} · ${esc(PROVEEDOR.correo)}</p>
</td></tr></table></td></tr></table></body></html>`;

  const texto = [
    `${nombre ? "Hola " + nombre + ", aquí" : "Aquí"} está ${genero}.`,
    `Adjuntamos la ${doc.toLowerCase()} electrónica N° ${d.folio}${d.tipo === "factura" && d.razon_social ? " a nombre de " + d.razon_social : ""} de tu pedido #${d.numero} por ${clp(d.total)} (IVA incluido). Es un documento válido ante el SII.`,
    d.con_cuenta ? `También queda guardada en Mi cuenta → Mis pedidos: ${base}/cuenta.html` : "Guarda este correo: es tu respaldo de la compra.",
    "", `¿Algún dato no corresponde? Responde este correo o escríbenos por WhatsApp: https://wa.me/${PROVEEDOR.whatsapp}`,
    "", `${PROVEEDOR.nombre_fantasia} · ${PROVEEDOR.razon_social} · RUT ${PROVEEDOR.rut} · ${PROVEEDOR.domicilio} · ${PROVEEDOR.correo}`,
  ].join("\n");

  return { asunto, html, texto };
}
