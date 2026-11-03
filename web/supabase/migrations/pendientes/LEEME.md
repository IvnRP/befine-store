# Migraciones pendientes — Befine Store

Estas migraciones **ya están escritas** pero **no aplicadas**. Cuando se cumpla su requisito, se mueven a `../` (carpeta `migrations/`) y se aplican en Supabase como migración. Cada una tiene su archivo de reversa.

Orden: **01, 01b y 04 (aplicadas) → 02 y 03** (no dependen entre sí).

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

## 03 · Compra como invitado + confirmación de pago — `03_invitados_pago.sql`

**Aplicar cuando:** se construya la Edge Function del webhook de Mercado Pago.

**Qué agrega**
- Trigger `on_auth_user_upgraded`: cuando un invitado crea su cuenta, completa su perfil (nombre, teléfono). Conserva el mismo id → **sus pedidos y puntos quedan en la cuenta**.
- Función `confirmar_pago(pedido, mp_payment_id, monto, raw, preference_id)` — **solo service_role** (webhook):
  - Verifica que el monto coincida con el total del pedido.
  - Pasa el pedido `pendiente_pago → pagado → en_preparacion` (automático).
  - Descuenta stock y suma los puntos al cliente.
  - Idempotente: si Mercado Pago repite la notificación, no duplica nada.

**Configuración en el panel de Supabase (antes de usar invitados)**
1. Authentication → Sign In / Providers → **Allow anonymous sign-ins: ON**
2. Authentication → Attack Protection → **Captcha (hCaptcha o Turnstile): ON** — obligatorio para que no se creen invitados en masa.

**Qué hace el frontend (checkout)**
```js
// Si no hay sesión: entrar como invitado
if (!(await sb.auth.getSession()).data.session) await sb.auth.signInAnonymously({ options: { captchaToken } });

const { data: pedido, error } = await sb.rpc("crear_pedido", {
  p_items, p_direccion, p_contacto, p_entrega, p_documento, p_cupon_codigo, p_notas,
});

// Casilla "Crear mi cuenta y sumar X puntos" marcada:
await sb.auth.updateUser({ email: contacto.email, password });   // mismo id, conserva pedido y puntos
```
- Puntos a mostrar en la casilla: `pedido.puntos_ganados` (o calcular con `parametros.clp_por_punto`).
- Cliente existente: enlace "¿Ya tienes cuenta? Inicia sesión para no perder tus puntos" → `cuenta.html?volver=checkout.html`.

**Edge Function `mp-webhook` (por construir)**
1. Recibe la notificación de Mercado Pago y **consulta el pago a la API de MP** con el access token (secreto) — nunca confiar en el cuerpo de la notificación.
2. Si el pago está `approved`: `rpc("confirmar_pago", { p_pedido, p_mp_payment_id, p_monto, p_raw })` con el cliente **service_role**.
3. Responder 200 siempre que se haya procesado (MP reintenta si no).

---

## 04 · Reglas de cupones — APLICADA el 20-oct-2026 (RF-20 · cambio menor CM-01)

Se movió a `../20261020_04_cupones_reglas.sql` (con su reversa y su prueba en seco).
Antes de aplicarla se verificó en producción que `crear_pedido()` era la versión de la 01, y la prueba en seco dio 20/20 OK sin dejar cambios. Después de aplicarla, `revisar_cupon()`, `_evaluar_cupon()`, las columnas nuevas de `cupones` y el trigger `trg_pedido_cancelado_cupon` quedaron disponibles.

---

## Pendientes generales (no son migraciones)
- [ ] Crear el **primer administrador** (asignar `rol = 'admin'` a la cuenta del dueño).
- [ ] Conectar `checkout.js` a `crear_pedido` (hoy está en modo demo).
- [ ] Activar **protección de contraseñas filtradas** (Authentication → Attack Protection).
- [ ] Definir qué pasa con pedidos `pendiente_pago` que nunca se pagan (cancelación automática). La devolución del uso del cupón al cancelar la resuelve la 04.
- [ ] Regla B2B `b2b_minimo_recargas` (mínimo de recargas para empresas) aún no se valida en `crear_pedido`.
