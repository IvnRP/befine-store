# Migraciones pendientes — Befine Store

Estas migraciones **ya están escritas** pero **no aplicadas**. Cuando se cumpla su requisito, se mueven a `../` (carpeta `migrations/`) y se aplican en Supabase como migración. Cada una tiene su archivo de reversa.

Orden: **01, 01b, 04, 03, 05, 06, 07 y 08 (aplicadas) → 02** (escrita y movida a `../`; se aplica con las secciones Reparto y Equipo y roles). Esta carpeta queda vacía de migraciones.

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
