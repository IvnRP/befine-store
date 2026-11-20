# Befine Store — Sitio web (`web/`)

Tienda y panel de administración de Befine Store hechos con **HTML + CSS + JavaScript sin framework ni build** (SC-02), conectados a Supabase. Esta carpeta es lo que se publica en producción (aguabefine.cl, Cloudflare Pages) y lo que sirve el contenedor Docker, salvo `supabase/`, que nunca se publica.

Cómo ejecutarlo, desplegarlo y probarlo: ver el [README principal](../README.md).

## Páginas

| Página | Qué es |
|---|---|
| `index.html` | Inicio: compra rápida del producto más pedido, reseñas de Google, beneficios y escenas según la hora |
| `catalogo.html` | Catálogo con categorías, buscador sin acentos y etiqueta de oferta |
| `producto.html` | Ficha de producto con variantes y fotos; se publica como `/productos/<nombre>` |
| `checkout.html` | Compra en una página: invitado o cuenta, comuna, entrega, boleta o factura, cupón, puntos, aceptación de Términos y pago con Mercado Pago |
| `cuenta.html` | Registro, ingreso (correo o Google), recuperar contraseña, mis datos, mis pedidos, "Volver a pedir" y Club Befine |
| `como-funciona.html` | Compra en 6 pasos, costo de despacho, Club Befine y preguntas frecuentes |
| `terminos.html`, `privacidad.html`, `despacho.html`, `cambios.html` | Páginas legales (Ley 19.496, Ley 19.628 y Ley 21.719) |
| `404.html` | Página no encontrada |
| `admin.html` | Panel de administración (secciones según el rol) |

## Estilos (`css/`, por capas)

`tokens.css` (colores y fuentes de marca) → `base.css` → `shell.css` (barra, menú, carrito, pie) → `components.css` → `forms.css`, y una hoja por página: `home.css`, `catalogo.css`, `producto.css`, `checkout.css`, `cuenta.css`, `como.css`, `legal.css` y `admin.css` (clases con prefijo `pn-` para que los bloqueadores de anuncios no oculten el panel, M-04).

## Lógica (`js/`, por responsabilidad)

| Archivo | Responsabilidad |
|---|---|
| `data.js` | **Único punto de acceso a Supabase de la tienda** (`window.Befine`): catálogo, cobertura y despacho, pedidos, pago, cuenta, Club, textos legales |
| `admin-data.js` | Acceso a Supabase del panel (`Befine.admin`) |
| `store.js` | Carrito en el navegador (localStorage), compartido entre páginas |
| `shell.js`, `ui.js` | Cascarón común: barra, menú, pie, carrito lateral con barra de envío gratis, avisos |
| `cards.js` | Tarjeta de producto (inicio y catálogo) |
| `home.js`, `catalogo.js`, `producto.js`, `checkout.js`, `cuenta.js`, `legal.js` | Lógica de cada página |
| `forms.js` | Validaciones compartidas: RUT (módulo 11), celular, correo y contraseña |
| `admin.js`, `admin-logic.js` | Núcleo del panel y reglas sin acceso a datos (probadas con `npm test`) |
| `admin-pedidos.js`, `admin-reparto.js`, `admin-clientes.js`, `admin-catalogo.js`, `admin-inventario.js`, `admin-cupones.js`, `admin-equipo.js` | Una sección del panel cada uno |
| `admin-avisos.js` | Sonido de caja registradora cuando entra un pedido pagado |
| `water.js`, `fx.js`, `scenes.js`, `bands.js`, `theme.js`, `transitions.js`, `perf.js` | Experiencia visual: efecto de agua, escenas por horario, modo claro/oscuro, transiciones y modo ligero automático en equipos lentos |

La interfaz nunca calcula montos que importen: precios, despacho, descuentos, totales, stock, puntos y estados los decide el servidor (`crear_pedido()`, `confirmar_pago()` y las Edge Functions). Todo texto ingresado por un cliente se escapa antes de mostrarse.

## Otras carpetas

| Carpeta | Contenido |
|---|---|
| `assets/` | Logos, fondos y escenas en WebP, sonidos del panel |
| `vendor/` | supabase-js versionado y fijo (se sirve desde el propio sitio) |
| `supabase/functions/` | Edge Functions: `crear-pago`, `mp-webhook`, `enviar-correo`, `resenas-google` |
| `supabase/migrations/` | Migraciones SQL con reversa y prueba en seco (detalle en el README principal) |
