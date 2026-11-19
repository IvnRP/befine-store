# Historial de cambios — Befine Store

Cambios relevantes del producto, del más reciente al más antiguo, agrupados por la fecha en que llegaron a `main`. Cada entrada indica la historia de usuario (HU), requerimiento (RF), solicitud de cambio (SC), cambio menor (CM) o defecto (M) que la respalda. Detalle de cada commit en el historial de Git; solicitudes de cambio en el repositorio de documentación (`08-Gestion-PMBOK/`).

## 18-nov-2026 · PR #54 y #55 — Posicionamiento, velocidad y avisos al dueño

- **SEO:** direcciones amigables `/productos/<nombre>` para cada producto (migración 16), `sitemap.xml`, `robots.txt`, página 404, redirección de cada producto de Shopify a su ficha nueva, vista previa para redes sociales, favicon y datos estructurados con costo y plazo de envío.
- **Velocidad:** supabase-js local y versionado, precarga de la foto principal, logo en WebP y menos consultas al cargar.
- **Accesibilidad:** etiquetas en los selectores de cantidad, contraste, áreas táctiles, contenido principal y orden de encabezados.
- **Inicio:** comuna rotando en el título, fecha de entrega en la tarjeta, nota de Google, textos de confianza y beneficio "Factura para empresas".
- **Ficha de producto:** descripción legible sobre la foto, con saltos de línea y enlaces.
- **Avisos de pedido pagado:** sonido de caja registradora en el panel y correo al dueño desde `mp-webhook` (Resend).
- Pruebas: 138 unitarias.

## 17-nov-2026 · PR #51, #52 y #53 — Go-Live en aguabefine.cl

- **Go-Live:** la tienda pasa a producción en aguabefine.cl (Cloudflare Pages, CM-04), 4 días antes de lo planificado. Verificado con una compra real y su devolución.
- **Clientes (HU-23, CM-03):** sección del panel con indicadores, segmentos, ficha, edición y Bloquear/Activar con auditoría (migración 14).
- **SC-04:** ping programado a Supabase (lunes y jueves) para que el plan gratuito no se pause.
- **Redirecciones de Shopify:** las direcciones antiguas llevan a las páginas nuevas.
- **M-05:** en Mi cuenta, el texto del Club ya no hereda el tamaño del saldo de puntos.
- **M-06:** las redirecciones creaban un bucle en `/checkout` en producción; se revirtió con Rollback y se corrigió `_redirects` (destinos sin `.html` y sin redirigir rutas existentes).
- **Despacho (CM-05):** $2.500 en todas las comunas, incluida Quilicura, y gratis desde $7.000 (migración 15); barra "Te faltan $X para el envío gratis" en el carrito y el checkout; página **Cómo funciona**; Términos v2026-11-17.

## 12-nov-2026 · PR #50 — Publicación en Cloudflare Pages

- Script `deploy/construir.sh`, cabeceras de seguridad y primera vista previa en Cloudflare Pages.
- **SC-06:** sin boleta automática (OpenFactura descartada por la situación financiera del cliente): se quitan "Descargar boleta" y "Boleta en proceso"; el cliente la pide respondiendo el correo o por WhatsApp.
- **M-04:** el panel quedaba en blanco con bloqueadores de anuncios; las clases pasan al prefijo `pn-`.

## 11-nov-2026 · PR #49 — Club, reparto, roles y correo

- **Club Befine (HU-11, HU-12, HU-19, CM-02):** puntos por recargas con envase Befine, bono por pedido grande, premios, Trae un amigo y vencimiento (migración 08).
- **Reparto del chofer (HU-16, HU-17):** pedidos pagados del día por comuna, "En camino" y "Entregado" con aviso por WhatsApp (migración 02).
- **Equipo y roles (HU-31):** asignar administrador, chofer o cliente con auditoría (migración 02).
- **M-07:** lo entregado hoy desaparecía del reparto (migración 09).
- **M-08:** los avisos de WhatsApp mostraban símbolos rotos por los emojis (migración 10).
- **Correo de confirmación de compra (HU-10):** Resend desde pedidos@aguabefine.cl, un solo envío por pedido (migración 11).

## 05 y 06-nov-2026 · PR #30 y #49 — Invitados, stock, legal y fotos

- **Invitados y confirmación de pago (HU-09):** el invitado conserva pedidos y puntos al crear cuenta; `confirmar_pago()` solo para el servidor (migración 03).
- **Stock sin bloqueos (HU-22):** el stock nunca frena una venta; productos "disponibles a pedido" con entrega aplazada (migración 05).
- **Legal (HU-25):** casilla obligatoria de Términos y Privacidad con fecha y versión registradas (migración 06); páginas de Términos, Privacidad, Despacho y Cambios; identificación del proveedor.
- **Fotos reales de productos** en Supabase Storage (migración 07) y fondos con fotos de Befine.
- Despliegue: el navegador revalida JS y CSS para no usar versiones antiguas.

## 23 al 28-oct-2026 · PR #28, #29 y #30 — Pago con Mercado Pago

- **HU-08 y HU-09:** Edge Functions `crear-pago` (preferencia con el total del servidor) y `mp-webhook` (confirma consultando a Mercado Pago); el checkout paga con Checkout Pro.
- **HU-18:** detalle del pedido y "Volver a pedir" en Mi cuenta.
- **HU-14:** integración continua con GitHub Actions (pruebas y Docker en cada PR).
- **M-02:** cada visita al checkout creaba otro pedido pendiente; ahora se reutiliza.
- **M-03:** al volver de Mercado Pago con "Atrás" el botón quedaba en "Conectando…".
- **HU-07:** filtro por fecha de entrega en el panel de pedidos.

## 19 al 22-oct-2026 · PR #24 y #27 — Panel de administración y seguridad

- **SC-03:** migraciones 01 y 01b: roles y permisos configurables, RLS reescrito y `crear_pedido()` como única vía para comprar.
- **HU-13:** panel de administración con acceso por rol.
- **RF-16, RF-17, RF-18:** gestión de pedidos, catálogo y precios, e inventario con alerta de stock bajo.
- **RF-20 (CM-01):** cupones con reglas de campaña y bienvenida (migración 04, aplicada el 20-oct).
- Seguridad: política de contraseñas y límite de consultas en `resenas-google`.
- CFG-04: plantillas de issues y Pull Request.

## 09 al 15-oct-2026 · PR #19 — Base del proyecto en la web

- **HU-06:** el checkout crea el pedido en el servidor y permite comprar como invitado.
- **M-01:** no se ofrecen entregas en feriados de Chile.
- **HU-14:** 31 pruebas unitarias automatizadas.
- Docker con nginx.

## 16-sep al 01-oct-2026 — Inicio

- Conexión a Supabase y catálogo real (esqueleto funcional, 16-sep).
- Maqueta HTML/CSS/JS: inicio, catálogo, ficha y reseñas de Google.
- **SC-02:** se retira Flutter; el frontend pasa a HTML/CSS/JS.
- **HU-01:** registro, ingreso y compra como invitado.
