# Migraciones pendientes — Befine Store

Estas migraciones **ya están escritas** pero **no aplicadas**. Cuando se cumpla su requisito, se mueven a `../` (carpeta `migrations/`) y se aplican en Supabase como migración. Cada una tiene su archivo de reversa.

Estado al 20-nov-2026: **todas las migraciones escritas están aplicadas en producción** (orden de aplicación: 01, 01b, 04, 03, 05, 06, 07, 08, 02, 09, 10, 11, 14, 15, 16 y 17). Esta carpeta queda vacía de migraciones. Números reservados: **12** (tareas programadas con pg_cron) y **13** (formulario de contacto).

## 20 · La boleta o factura llega por correo al subirla — `../20261122_20_correo_documento.sql` (escrita el 22-nov-2026; prueba en seco T01..T08 OK en Postgres local)

Decisión del dueño: al subir el PDF en el panel, el cliente lo recibe **adjunto** en su correo (con o sin cuenta). Columnas `correo_enviado_at`, `correo_destino`, `correo_id` y `correo_error` en `documentos_tributarios`; la Edge Function `enviar-correo` con `{ tipo: "documento" }` (solo con `documentos.gestionar`) reserva el envío con un UPDATE condicional (sin duplicados), adjunta el PDF del bucket privado y, si Resend falla, lo deja pendiente con el motivo para reintentar desde el panel. Si el documento se reemplaza por otro folio, el trigger `trg_dte_reiniciar_correo` deja el envío pendiente y guarda el anterior en `raw_response->'correo_anterior'`. **Orden:** (1) aplicar 20, (2) desplegar `enviar-correo` (index.ts + plantilla.ts), (3) publicar el panel. Prueba en seco `../20261122_20_prueba_en_seco.sql` (T01..T08). Reversa `../20261122_20_correo_documento_reversa.sql`.

---

## 19 · Boletas y facturas en la tienda (opción A) — `../20261122_19_documentos_tributarios.sql` (escrita el 22-nov-2026; prueba en seco T01..T12 OK en Postgres local) — aplicada el 22-nov-2026

Decisión del dueño: los documentos se siguen emitiendo en Haulmer y la tienda guarda el PDF y el folio de cada pedido. Bucket **privado** `documentos` (solo PDF, 3 MB; sube el equipo con `documentos.gestionar`, lee el dueño del pedido con enlace temporal), columnas `archivo` y `registrado_por` en `documentos_tributarios`, un documento emitido por pedido y `registrar_documento(pedido, tipo, folio)` (pedido pagado, tipo pedido por el cliente, folio no repetido, PDF ya subido; neto = total/1,19 como Haulmer; reemplazo auditado). Deja lista la tabla para la emisión automática propia (opción B). **Aplicar ANTES de publicar** el panel con "Subir documento". Prueba en seco `../20261122_19_prueba_en_seco.sql` (T01..T12). Reversa `../20261122_19_documentos_tributarios_reversa.sql`.

---

## 18 · Trae un amigo a prueba de abusos — `../20261121_18_referidos_seguros.sql` (escrita el 21-nov-2026; prueba en seco T01..T09 OK en Postgres local)

Decisión del dueño: los 10 puntos de Trae un amigo se dan cuando el primer pedido del amigo se **entrega** (ya no al pagar); si ese pedido se cancela, se descuentan a los dos (sin saldos negativos) y la invitación queda pendiente; tope de `club_referido_tope_mes` = 10 amigos premiados al mes para quien invita (el amigo igual recibe su bienvenida). Nueva versión de Términos `2026-11-21`. **Aplicar junto con** la versión del sitio que trae los textos nuevos (`terminos.html`, `cuenta.js`, `Befine.legalVersion`). Prueba en seco `../20261121_18_prueba_en_seco.sql` (T01..T09). Reversa `../20261121_18_referidos_seguros_reversa.sql`.

---

## 17 · Compra como invitado desde otro navegador — `../20261120_17_pedidos_invitado.sql` (escrita y aplicada el 20-nov-2026; prueba en seco T01..T12 OK)

Incidente 19-nov-2026: una clienta pagó como invitada desde el navegador de WhatsApp y Mercado Pago la devolvió a otro navegador (sin su sesión): el pago quedó confirmado, pero la tienda mostró "No pudimos revisar tu pedido" y no pudo crear su cuenta. `pedido_vuelta(id)` muestra el resultado del pago sin sesión (número, estado, montos y correo enmascarado; 7 días) y `reclamar_pedidos_invitado()` pasa a la cuenta con correo **confirmado** las compras como invitado hechas con ese correo (pedidos, direcciones y puntos; auditado en `cambios_cliente`). **Aplicar ANTES de publicar** el sitio que las usa. Prueba en seco `../20261120_17_prueba_en_seco.sql` (T01..T12). Reversa `../20261120_17_pedidos_invitado_reversa.sql`.

---

## 16 · Dirección amigable de productos (SEO) — `../20261118_16_productos_slug.sql` (escrita y aplicada el 18-nov-2026; prueba en seco T01..T08 OK)

Auditoría SEO: `productos.slug` (único, minúsculas y guiones) con las 11 direcciones decididas por el dueño, `slug_de()` y trigger que la genera desde el nombre si el panel la deja vacía (con -2, -3 si se repite). La ficha queda en `https://aguabefine.cl/productos/<slug>` (`deploy/_redirects`: reescritura 200 a `producto.html`). **Aplicar ANTES de publicar** el sitio que lee `slug` (la versión actual no lo usa). Reversa `../20261118_16_productos_slug_reversa.sql`.

---

## 15 · Despacho gratis desde $7.000 en todas las comunas — `../20261117_15_despacho_desde_7000.sql` (escrita el 17-nov-2026, aplicada el 18-nov-2026; prueba en seco T01..T06 OK; CM-05)

Decisión del dueño: Quilicura deja de tener despacho gratis con cualquier monto y paga $2.500 bajo $7.000, igual que el Sector Norte; desde $7.000 de subtotal el envío es gratis en todas las comunas. Solo datos (`zonas_despacho`) y nueva versión de textos legales `2026-11-17`. El despacho gratis para clientes elegidos se da con un cupón personal. Prueba en seco `../20261117_15_prueba_en_seco.sql` (T01..T06). Reversa `../20261117_15_despacho_desde_7000_reversa.sql`. Se aplica junto con la versión del sitio que trae la franja "Envío gratis en pedidos desde $7.000" y la página Cómo funciona.

---

## 14 · Clientes en el panel — `../20261112_14_clientes.sql` (aplicada el 13-nov-2026; prueba en seco T01..T14 OK)

HU-23 / RF-19 ajustado por CM-03: `clientes_resumen()`, `cliente_detalle(id)` y `editar_cliente(id, datos)` (permisos `clientes.ver` / `clientes.gestionar`), auditoría en `cambios_cliente`. "Eliminar" → "Bloquear" (un cliente bloqueado no puede comprar). Prueba en seco `../20261112_14_prueba_en_seco.sql` (T01..T14). Se aplica junto con la sección Clientes del panel. Números reservados: 12 (Carlos, pg_cron) y 13 (Felipe, contacto).

---

## 07 · Fotos de productos — `../20261106_07_fotos_productos.sql` (aplicada el 06-nov-2026)

Bucket público `productos` (solo imágenes, máx. 2 MB), políticas para que solo el admin (`catalogo.gestionar`) suba o borre, y `productos.imagen_url` con la ruta del archivo grande (`*-1000.webp`). La tienda usa la versión `-400` en tarjetas y carrito. Prueba en seco T01..T05 OK, aplicada y las 20 WebP subidas de `D:\CAPSTONE\Fotos_Befine\web_productos` en Storage → productos.

---

## 02 · Reparto, WhatsApp y roles — movida a `../20261110_02_reparto_roles.sql` (10-nov-2026)

Revisada y ampliada: el chofer pasa de `pedidos.ver` (veía todos los pedidos) a `pedidos.repartir` y ve solo los pedidos **pagados** de una fecha con `reparto_del_dia()`; `marcar_reparto()` y `aviso_reparto()` devuelven el teléfono y el mensaje para WhatsApp; `equipo()`, `buscar_usuario()` y `asignar_rol()` (solo admin, auditado en `cambios_rol`). Prueba en seco `../20261110_02_prueba_en_seco.sql` (T01..T13). Se aplica junto con las secciones Reparto y Equipo y roles del panel.
---

## Aplicadas el 05-nov-2026: 03 y 05

Se movieron a `../` con su fecha (`20261105_03_*` y `20261105_05_*`). Prueba en seco T01..T07 OK antes de aplicarlas.

- **03 · Invitados + confirmación de pago:** trigger `on_auth_user_upgraded` (el invitado que crea cuenta conserva su id, pedidos y puntos) y `confirmar_pago()` (solo `service_role`, la llama el webhook `mp-webhook`): `pendiente_pago → pagado → en_preparacion`, descuenta stock, suma puntos, idempotente.
- **05 · El stock nunca frena una venta (HU-22):** `crear_pedido()` sin rechazo por stock, columna `pedidos.sobreventa` y `confirmar_pago()` con la marca de sobreventa.
- **Captcha:** activarlo en Authentication → Attack Protection **solo cuando el checkout envíe el token**; activarlo antes bloquea las compras como invitado.

---

## Aplicada el 06-nov-2026: 06

**06 · Aceptación obligatoria de Términos y Privacidad (HU-25, Ley 21.719):** `crear_pedido()` exige `p_contacto.acepta_terminos = true` y guarda `pedidos.terminos_aceptados_at` (hora del servidor) y `terminos_version` (parámetro `terminos_version`, hoy `2026-11`). Se movió a `../20261106_06_*`. Prueba en seco T01..T05 OK.
