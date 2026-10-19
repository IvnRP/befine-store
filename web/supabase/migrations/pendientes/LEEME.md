# Migraciones pendientes — Befine Store

Estas migraciones **ya están escritas** pero **no aplicadas**. Cuando se cumpla su requisito, se mueven a `../` (carpeta `migrations/`) y se aplican en Supabase como migración. Cada una tiene su archivo de reversa.

Orden: **01 (aplicada) → 02, 03 y 04** (no dependen entre sí).

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

## 04 · Reglas de cupones: campañas y bienvenida — `04_cupones_reglas.sql` (RF-20 · cambio menor CM-01)

**Aplicar cuando:** se publique la sección **Cupones** del panel y el campo de cupón del checkout (rama `carlos`).

**Qué agrega**
- Columnas en `cupones`: `requiere_cuenta`, `solo_primera_compra`, `usos_por_cliente` y `descripcion` (nota interna). Un cupón de primera compra siempre exige cuenta (restricción `cupones_bienvenida_con_cuenta`).
- `_evaluar_cupon()` (interna, no expuesta): única lógica de cupones — vigencia, usos totales, compra mínima, productos a los que aplica y las reglas nuevas.
- `revisar_cupon(codigo, items)` (anon y authenticated): el checkout muestra el descuento o el motivo por el que no aplica **antes de pagar**. No gasta usos y, para no revelar datos de terceros, revisa la primera compra solo con la cuenta del propio usuario.
- `crear_pedido()`: misma versión de la 01, con el bloque de cupón reemplazado por `_evaluar_cupon()`.
- Trigger `trg_pedido_cancelado_cupon`: al cancelar un pedido con cupón se devuelve su uso.

**Reglas del cupón de bienvenida** (`solo_primera_compra`)
- Exige cuenta registrada: un invitado ve "Este cupón es para clientes con cuenta. Crea tu cuenta gratis para usarlo."
- Se rechaza si la **cuenta**, el **correo** o el **teléfono** del pedido ya tienen una compra pagada (pagado, en preparación, en camino o entregado).
- Un pedido pendiente de pago con el cupón también cuenta: no se pueden crear dos pedidos con él. Si ese pedido se cancela, vuelve a quedar disponible.

**Antes de aplicar:** `crear_pedido()` se reemplaza completa. Verificar en Supabase que la versión en producción es la de la 01:
```sql
select pg_get_functiondef('public.crear_pedido(jsonb,jsonb,jsonb,jsonb,jsonb,text,text)'::regprocedure);
```
**Prueba en seco:** `04_prueba_en_seco.sql` (20 casos). En el SQL Editor pegar en una misma consulta el contenido de `04_cupones_reglas.sql` seguido del de `04_prueba_en_seco.sql` (sin `begin`/`commit`) y ejecutar; termina con un error intencional que deshace todo y lista T01–T20 (no debe aparecer FALLA). Verificada el 19-oct-2026 sobre una réplica local (schema DEFINITIVO + catálogo + 01 + 01b): 20/20 OK, y la reversa también.

---

## Pendientes generales (no son migraciones)
- [ ] Crear el **primer administrador** (asignar `rol = 'admin'` a la cuenta del dueño).
- [ ] Conectar `checkout.js` a `crear_pedido` (hoy está en modo demo).
- [ ] Activar **protección de contraseñas filtradas** (Authentication → Attack Protection).
- [ ] Definir qué pasa con pedidos `pendiente_pago` que nunca se pagan (cancelación automática). La devolución del uso del cupón al cancelar la resuelve la 04.
- [ ] Regla B2B `b2b_minimo_recargas` (mínimo de recargas para empresas) aún no se valida en `crear_pedido`.
