/* La boleta o factura le llega al cliente por correo al subirla al panel (migración 20) — 5 pruebas
   Caso CP-U42: el correo lleva el PDF adjunto (también a invitados), los datos se escapan, el envío
   exige el permiso documentos.gestionar y no se duplica, y el panel muestra a quién y cuándo se envió.
   La lógica de la Edge Function se probó además con Deno y Resend simulado (evidencia 07). */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const RAIZ = path.join(__dirname, "..", "..", "web");
const FN = path.join(RAIZ, "supabase", "functions", "enviar-correo");
const T = require(path.join(FN, "plantilla.ts"));
const { AdminLogic: L } = cargar(["admin-logic.js"]);
const SITIO = "https://aguabefine.cl";
const doc = (o = {}) => ({ numero: 28, contacto_nombre: "Benjamín Earle", tipo: "boleta", folio: 11298, total: 10000, con_cuenta: true, ...o });

test("CP-U42a correo de boleta: folio, pedido, total, proveedor y enlace a Mis pedidos (cliente con cuenta)", () => {
  const c = T.armarCorreoDocumento(doc(), SITIO);
  assert.equal(c.asunto, "Befine: tu boleta N° 11298 del pedido #28");
  assert.match(c.html, /aguabefine\.cl\/cuenta\.html/);
  for (const t of [c.html.replace(/<[^>]+>/g, ""), c.texto]) {
    assert.match(t, /Hola Benjamín/);
    assert.match(t, /boleta electrónica N° 11298/);
    assert.match(t, /pedido #28/);
    assert.match(t, /\$10\.000/);
    assert.match(t, /77\.861\.415-4/);
  }
  assert.match(c.texto, /aguabefine\.cl\/cuenta\.html/);
  assert.equal(T.nombreAdjunto("boleta", 11298), "Boleta_Befine_N11298.pdf");
  assert.equal(T.nombreAdjunto("factura", "496"), "Factura_Befine_N496.pdf");
  assert.equal(T.nombreAdjunto("boleta", "../x"), "Boleta_Befine_N0.pdf");        // nunca rutas raras en el adjunto
});

test("CP-U42b invitado sin cuenta: sin enlace a Mi cuenta (el PDF va adjunto); factura a nombre de la empresa", () => {
  const inv = T.armarCorreoDocumento(doc({ con_cuenta: false }), SITIO);
  assert.ok(!/cuenta\.html/.test(inv.html + inv.texto));
  assert.match(inv.texto, /Guarda este correo/);
  const f = T.armarCorreoDocumento(doc({ tipo: "factura", folio: 496, total: 25000, razon_social: "Empresa Prueba SpA" }), SITIO);
  assert.equal(f.asunto, "Befine: tu factura N° 496 del pedido #28");
  assert.match(f.texto, /factura electrónica N° 496 a nombre de Empresa Prueba SpA/);
});

test("CP-U42c los datos del cliente se escapan en el HTML del correo", () => {
  const c = T.armarCorreoDocumento(doc({ contacto_nombre: "<img src=x onerror=alert(1)>", tipo: "factura",
    razon_social: '"><script>x</script>' }), SITIO);
  assert.ok(!c.html.includes("<img src=x"));
  assert.ok(!c.html.includes("<script>"));
  assert.match(c.html, /&lt;script&gt;/);
});

test("CP-U42d la Edge Function exige permiso, adjunta el PDF y no duplica; la migración 20 audita el envío", () => {
  const idx = fs.readFileSync(path.join(FN, "index.ts"), "utf8");
  assert.match(idx, /body\.tipo === "documento"/);
  assert.match(idx, /tiene_permiso", \{ p_permiso: "documentos\.gestionar" \}/);
  assert.match(idx, /attachments: \[\{ filename: nombreAdjunto/);
  assert.match(idx, /\.is\("correo_enviado_at", null\)/);                          // reserva condicional
  assert.match(idx, /Idempotency-Key/);
  assert.match(idx, /storage\.from\("documentos"\)\.download/);                     // PDF del bucket privado
  const m = fs.readFileSync(path.join(RAIZ, "supabase", "migrations", "20261122_20_correo_documento.sql"), "utf8");
  assert.match(m, /add column if not exists correo_enviado_at timestamptz/);
  assert.match(m, /before update of tipo, folio on public\.documentos_tributarios/);
  assert.match(m, /correo_anterior/);
});

test("CP-U42e el panel envía al guardar y muestra a quién y cuándo se envió (o el error para reintentar)", () => {
  assert.equal(L.estadoCorreoDoc(null).estado, "pendiente");
  assert.equal(L.estadoCorreoDoc({ folio: 1 }).estado, "pendiente");
  const e = L.estadoCorreoDoc({ correo_enviado_at: "2026-11-22T15:30:00Z", correo_destino: "cliente@correo.cl" });
  assert.equal(e.estado, "enviado");
  assert.match(e.texto, /Enviada por correo a cliente@correo\.cl el /);
  assert.match(L.estadoCorreoDoc({ correo_enviado_at: "2026-11-22T15:30:00Z", correo_error: "Resend 500: x" }).texto, /El último reenvío falló/);
  const x = L.estadoCorreoDoc({ correo_error: "Resend 403: domain not verified" });
  assert.equal(x.estado, "error");
  assert.match(x.texto, /No se pudo enviar por correo \(Resend 403/);
  const js = fs.readFileSync(path.join(RAIZ, "js", "admin-pedidos.js"), "utf8");
  assert.match(js, /x\.correo = await A\(\)\.enviarDocumento\(id\)/);              // guardar → enviar
  assert.match(js, /data-enviar-doc=/);                                            // botón Enviar / Reenviar
  const data = fs.readFileSync(path.join(RAIZ, "js", "admin-data.js"), "utf8");
  assert.match(data, /tipo: "documento"/);
});
