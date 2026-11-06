# Migraciones pendientes — Befine Store

Estas migraciones **ya están escritas** pero **no aplicadas**. Cuando se cumpla su requisito, se mueven a `../` (carpeta `migrations/`) y se aplican en Supabase como migración. Cada una tiene su archivo de reversa.

Orden: **01, 01b, 04, 03, 05 y 06 (aplicadas) → 02** (pendiente: se aplica con la vista del chofer).

---

## 02 · Reparto y avisos por WhatsApp — `02_reparto_whatsapp.sql`

**Aplicar cuando:** exista la pantalla del chofer en el frontend.

**Qué agrega**
- Permiso `pedidos.repartir` (asignado al rol `chofer`).
- Función `marcar_reparto(pedido, estado)`. Solo permite:
  - `en_preparacion → en_ruta` (botón **"En camino"**)
  - `en_ruta → entregado` (botón **"Entregado"**, cierra el ciclo)
- Cada cambio queda en `historial_pedido` con el chofer y la hora.
- Devuelve `telefono` (569XXXXXXXX) y `mensaje` listo para WhatsApp.

**Qué hace el frontend**
```js
const { data, error } = await sb.rpc("marcar_reparto", { p_pedido: id, p_estado: "en_ruta" }); // o "entregado"
if (!error) window.open(`https://wa.me/${data.telefono}?text=${encodeURIComponent(data.mensaje)}`);
```

**Futuro (API WhatsApp Business):** reemplazar el `window.open` por una Edge Function que envíe `data.mensaje` con la API de Meta. Requiere: verificación del negocio en Meta, número dedicado, plantillas aprobadas ("en camino" y "entregado"), token como secreto en Supabase.

---

## Aplicadas el 05-nov-2026: 03 y 05

Se movieron a `../` con su fecha (`20261105_03_*` y `20261105_05_*`). Prueba en seco T01..T07 OK antes de aplicarlas.

- **03 · Invitados + confirmación de pago:** trigger `on_auth_user_upgraded` (el invitado que crea cuenta conserva su id, pedidos y puntos) y `confirmar_pago()` (solo `service_role`, la llama el webhook `mp-webhook`): `pendiente_pago → pagado → en_preparacion`, descuenta stock, suma puntos, idempotente.
- **05 · El stock nunca frena una venta (HU-22):** `crear_pedido()` sin rechazo por stock, columna `pedidos.sobreventa` y `confirmar_pago()` con la marca de sobreventa.
- **Captcha:** activarlo en Authentication → Attack Protection **solo cuando el checkout envíe el token**; activarlo antes bloquea las compras como invitado.

---

## Aplicada el 06-nov-2026: 06

**06 · Aceptación obligatoria de Términos y Privacidad (HU-25, Ley 21.719):** `crear_pedido()` exige `p_contacto.acepta_terminos = true` y guarda `pedidos.terminos_aceptados_at` (hora del servidor) y `terminos_version` (parámetro `terminos_version`, hoy `2026-11`). Se movió a `../20261106_06_*`. Prueba en seco T01..T05 OK.
