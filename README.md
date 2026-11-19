# Befine Store

Plataforma de comercio electrónico propia para **Agua Purificada Befine**, microempresa de reparto de agua purificada a domicilio en Quilicura, Santiago (≈ 450 clientes activos). Proyecto de título Capstone APT · Duoc UC Plaza Norte · Grupo N3 (Plaxi Solutions) · 2026-2.

**En producción desde el 17-nov-2026:** [aguabefine.cl](https://aguabefine.cl) · Panel: [aguabefine.cl/admin](https://aguabefine.cl/admin)

Documentación completa del proyecto: [Cmfg96/Documentos_Capstone_Grupo_N3](https://github.com/Cmfg96/Documentos_Capstone_Grupo_N3)

## Descripción

- **Qué hace:** tienda web *mobile-first* con catálogo, carrito, checkout por comuna, pago con Mercado Pago, cuenta del cliente (correo, Google o compra como invitado), programa de puntos Club Befine, correo de confirmación de compra, reseñas reales de Google y panel de administración con roles (pedidos, reparto del chofer, clientes, catálogo y precios, inventario, cupones, equipo y roles).
- **Para quién:** clientes residenciales y empresas que compran agua a domicilio, y el dueño y los choferes de Befine que gestionan los pedidos.
- **Qué problema resuelve:** reemplaza la tienda en Shopify (≈ $35.000 al mes, sin fidelización ni reparto propio) por una plataforma propia con costo fijo $0, y centraliza en un solo sistema los pedidos, el reparto y los clientes.

## Tecnologías

| Capa | Tecnología |
|---|---|
| Frontend | HTML5, CSS3 y JavaScript sin framework ni build (SC-02); supabase-js versionado en `web/vendor/` |
| Backend / base de datos | Supabase (plan gratuito, SC-04): PostgreSQL con Row Level Security, Auth, Storage y Edge Functions (Deno/TypeScript) |
| Pagos | Mercado Pago Checkout Pro, confirmado por webhook |
| Correo | Resend (dominio aguabefine.cl): confirmación de compra, aviso de pedido al dueño y correos de cuenta |
| Integraciones | Google OAuth (inicio de sesión) y Google Places API (reseñas) |
| Posicionamiento y medición | Google Search Console (sitemap e indexación), perfil de Google del negocio con productos y Cloudflare Web Analytics |
| Hosting de producción | Cloudflare Pages (HTTPS, CDN, vista previa por rama y rollback; CM-04) |
| Despliegue reproducible | Docker + nginx |
| Integración continua | GitHub Actions: pruebas e imagen Docker en cada PR; ping programado a Supabase |
| Pruebas | `node:test` (Node.js ≥ 20) |
| Gestión | GitHub Projects (Kanban), issues y Pull Requests con revisión obligatoria |

La boleta electrónica automática (OpenFactura) fue descartada por la situación financiera del cliente (SC-06): la boleta se emite de forma manual y el cliente la pide respondiendo el correo de confirmación.

## Integrantes y roles

| Integrante | Rol |
|---|---|
| Iván Rodríguez Pinares | Product Owner y patrocinador; desarrollo de la tienda, pagos, Club, reparto, correo, despliegue y Go-Live |
| Carlos Fuentes González | Base de datos y seguridad (migraciones 01, 01b y 04), panel de administración (pedidos, catálogo, inventario, cupones), revisión de Pull Requests y documentación del proyecto |
| Felipe Moraga López | Diseño de interfaz mobile-first (prototipo en Figma), planes de gestión de requisitos, calidad y comunicaciones, Scrum Master de los Sprints 1 y 4 y revisión de Pull Requests |

## Metodología

Híbrida **PMBOK + Scrum**: PMBOK para dirigir el proyecto (hitos, líneas base y control de cambios SC-01 a SC-06 y CM-01 a CM-05) y Scrum para construir el producto en sprints de dos semanas, con Product Backlog, Sprint Backlog, Definition of Done y retrospectivas. El trabajo se sigue en el tablero Kanban del proyecto y cada cambio entra a `main` mediante Pull Request aprobado por otro integrante.

## Arquitectura

**El navegador solo muestra; el servidor decide.** Precios, despacho, descuentos, totales, stock, puntos y estados del pedido se calculan en PostgreSQL (funciones `SECURITY DEFINER`) o en Edge Functions.

```
Navegador (HTML + CSS + JS)  ── publicado en Cloudflare Pages (aguabefine.cl)
  ├── js/data.js        →  único punto de acceso a Supabase de la tienda (clave pública protegida por RLS)
  └── js/admin-data.js  →  acceso del panel de administración (lo que puede cada rol lo decide el RLS)

Supabase (plan gratuito, São Paulo)
  ├── Auth: correo y contraseña, Google e invitados anónimos (SMTP de Resend)
  ├── PostgreSQL: 28 tablas, RLS en todas, 13 permisos configurables por rol
  ├── Funciones SQL: crear_pedido(), confirmar_pago(), tiene_permiso(), reparto_del_dia(), asignar_rol()…
  ├── Storage: bucket "productos" (fotos WebP)
  └── Edge Functions
        ├── crear-pago      → arma la preferencia de Mercado Pago con el total del servidor
        ├── mp-webhook      → confirma el pago consultando a Mercado Pago, avisa al dueño por correo
        ├── enviar-correo   → confirmación de compra al cliente (Resend, un solo envío por pedido)
        └── resenas-google  → reseñas reales con caché de 1 hora

Servicios externos: Mercado Pago · Resend · Google (OAuth y Places) · WhatsApp (wa.me)
```

Las claves privadas viven solo como secretos de las Edge Functions; nunca en el navegador ni en el repositorio. Detalle y diagramas UML en el repositorio de documentación (`05-Diseno/`).

## Panel de administración

`admin.html` (también enlazado desde *Mi cuenta* para el equipo). Herramienta de trabajo del dueño y su equipo, separada de la tienda y pensada para usarse desde el celular. Avisa con sonido de caja registradora cuando entra un pedido pagado.

| Sección | Qué permite | Permiso |
|---|---|---|
| Pedidos (RF-16) | Indicadores del día y del mes, filtros por estado y por fecha de entrega (hoy, siguiente día hábil, esta semana o rango), búsqueda, detalle con WhatsApp al cliente, cambio de estado (pagado → en preparación → en camino → entregado, o cancelar) | `pedidos.ver` / `pedidos.gestionar` |
| Reparto (HU-16, HU-17) | Para el celular del chofer: pedidos **pagados** de hoy (con atrasados) o mañana, por comuna; "En camino" y "Entregado" abren WhatsApp con el aviso al cliente; mapa y llamar. El chofer no ve la lista general de pedidos (migración 02) | `pedidos.repartir` |
| Clientes (HU-23) | Lista con buscador, indicadores (nuevos del mes, recurrencia, ticket promedio, por recuperar) y segmentos; ficha con contacto, compras, direcciones, pedidos, Club Befine y cambios; editar datos y Bloquear/Activar (auditado en `cambios_cliente`, migración 14). "Eliminar" se reemplazó por "Bloquear" (CM-03) | `clientes.ver` / `clientes.gestionar` |
| Catálogo y precios (RF-17) | Crear y editar productos y variantes, dirección amigable del producto, publicar u ocultar, editar precios | `catalogo.gestionar` / `precios.gestionar` |
| Inventario (RF-18) | Stock por variante con alerta de stock bajo (umbral en `parametros.stock_alerta`); el stock nunca frena una venta (HU-22) | `catalogo.gestionar` (umbral: `config.gestionar`) |
| Cupones (RF-20) | Campañas (fechas, usos totales y por cliente, compra mínima, productos) y cupón de bienvenida (solo 1ª compra, con cuenta); pausar y ver usos (CM-01) | `promociones.gestionar` |
| Equipo y roles (HU-31) | Buscar una cuenta por correo y asignarle chofer, administrador o cliente (auditado en `cambios_rol`; nadie cambia su propio rol ni queda la tienda sin administrador) | solo administrador |

Seguridad en dos capas: el panel muestra solo lo que el rol puede usar y el **RLS** de Supabase bloquea cualquier cambio no permitido. El estado *Pagado* lo marca solo la confirmación de Mercado Pago.

**Crear el primer administrador** (una vez, en Supabase → SQL Editor, con el correo de la cuenta del dueño ya registrada):

```sql
update public.perfiles set rol = 'admin'
 where id = (select id from auth.users where email = 'correo-del-dueno@ejemplo.cl');
```

## Ejecutar en local con Docker

Requisito: [Docker Desktop](https://www.docker.com/products/docker-desktop/) instalado y abierto.

```bash
git clone https://github.com/IvnRP/befine-store.git
cd befine-store
cp .env.example .env      # opcional: cambiar el puerto con WEB_PORT
docker compose up -d --build
```

Abrir **http://localhost:8080**. Para detenerlo: `docker compose down`.

| Archivo | Para qué sirve |
|---|---|
| `Dockerfile` | Construye la imagen: nginx 1.27 + la carpeta `web/` (sin `web/supabase`) |
| `docker-compose.yml` | Levanta el contenedor en el puerto 8080 |
| `docker/nginx.conf` | Compresión, caché y cabeceras de seguridad |
| `.env.example` | Nombres de las variables y secretos (sin valores; el `.env` real nunca se sube) |

Docker es el despliegue reproducible del proyecto; la tienda en producción se publica en Cloudflare Pages (ver **Despliegue**). Ambos sirven el mismo sitio con las mismas cabeceras de seguridad y usan el mismo backend en Supabase.

## Ejecutar sin Docker

```bash
npm start        # http://localhost:8080 (http-server, sin caché)
```

No abrir los HTML con doble clic (`file://`): el inicio de sesión con Google requiere `http://`.

**Atención:** en local, en la vista previa y en producción la tienda usa la misma base de datos y el mismo Mercado Pago de producción: un pago de prueba es un cobro real. Probar pagos solo con montos chicos y devolverlos desde Mercado Pago.

## Despliegue

### Producción en Cloudflare Pages

| Configuración | Valor |
|---|---|
| Proyecto | `befine-store`, conectado a este repositorio |
| Comando de compilación | `bash deploy/construir.sh` |
| Carpeta publicada | `dist` |
| Rama de producción | `main` → aguabefine.cl y www.aguabefine.cl |
| Vista previa | cada rama en `<rama>.befine-store.pages.dev` |

`deploy/construir.sh` copia `web/` a `dist/` **sin** la carpeta `supabase` (las migraciones y funciones no son públicas) y agrega:

| Archivo | Para qué sirve |
|---|---|
| `deploy/_headers` | Cabeceras de seguridad (nosniff, X-Frame-Options, Referrer-Policy, Permissions-Policy); imágenes con caché de 30 días y JS/CSS con `no-cache` |
| `deploy/_redirects` | Direcciones antiguas de Shopify a las páginas nuevas (no se pierden enlaces de Google, Instagram o WhatsApp) y fichas en `/productos/<nombre>` |
| `deploy/robots.txt` y `deploy/sitemap.js` | Reglas para buscadores y `sitemap.xml` con las páginas y una ficha por producto activo |

Cloudflare Pages ya convierte `/pagina.html` en `/pagina`: en `_redirects` los destinos van sin `.html` y nunca se redirige una ruta que existe en la tienda (causa del incidente M-06 del Go-Live).

### Cómo se publica un cambio

1. Programar en la rama propia y probar en local (`npm test` y `npm start` o Docker).
2. Push: corre la integración continua y Cloudflare publica la vista previa de la rama.
3. Revisar la vista previa (incluidas redirecciones si se tocaron).
4. Pull Request a `main` con los checks en verde y 1 aprobación → Merge.
5. Cloudflare publica `main` en aguabefine.cl en 1 a 2 minutos.
6. Si algo falla en producción: **Rollback** en Cloudflare Pages (un clic, vuelve al despliegue anterior) y luego un PR con la corrección.

**No se publica con el merge:** las migraciones (se aplican en Supabase → SQL Editor, con prueba en seco antes), las Edge Functions (Supabase → Edge Functions) y los secretos.

### Edge Functions y secretos

Los secretos se configuran solo en Supabase → Edge Functions → Secrets. Ninguno está en el código ni en este repositorio; `.env.example` lista solo sus nombres.

| Función | Acceso | Secretos que usa |
|---|---|---|
| `crear-pago` | Requiere sesión | `MP_ACCESS_TOKEN`, `SITE_URL` |
| `mp-webhook` | Público (lo llama Mercado Pago); vuelve a consultar el pago antes de confirmar | `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET` (opcional), `AVISO_PEDIDOS_EMAIL` (opcional), `RESEND_API_KEY`, `CORREO_REMITENTE` |
| `enviar-correo` | Interno | `RESEND_API_KEY`, `CORREO_REMITENTE`, `SITE_URL` |
| `resenas-google` | Público, con caché de 1 hora | `GOOGLE_PLACES_KEY`, `GOOGLE_PLACE_ID` |

La clave publicable de Supabase está en `web/js/data.js` a propósito: es pública y la protege el RLS. La clave `service_role` nunca llega al navegador.

### Integración continua y mantenimiento

| Flujo | Cuándo | Qué hace |
|---|---|---|
| `.github/workflows/ci.yml` | Cada PR y merge a `main` | "Pruebas unitarias" (sintaxis de los JS + `npm test`) e "Imagen Docker" (construye, levanta y revisa cabeceras). Ambos checks son obligatorios para fusionar |
| `.github/workflows/ping-supabase.yml` | Lunes y jueves 12:17 UTC (y a mano) | Lee 1 fila de `parametros` para que el plan gratuito de Supabase no se pause por inactividad (SC-04); si falla, GitHub avisa por correo |

Respaldo de la base: la SC-04 define un respaldo manual semanal con `pg_dump`; aún no está en operación.

## Base de datos y migraciones

La base parte del esquema definitivo (16-sep-2026) y cambia solo por migraciones versionadas en `web/supabase/migrations/` (`AAAAMMDD_NN_nombre.sql`), cada una con su **reversa** (`_reversa.sql`) y su **prueba en seco** (`_prueba_en_seco.sql`: corre la migración y sus casos en una transacción que se deshace al final).

| N° | Migración | Aplicada | Qué hace |
|---|---|---|---|
| 01 | Seguridad y roles (SC-03) | 09-10-2026 | Roles y permisos, `tiene_permiso()`, RLS reescrito, `crear_pedido()` como única vía para comprar |
| 01b | Proteger `es_empresa` | 09-10-2026 | Solo el administrador marca a un cliente como empresa |
| 04 | Reglas de cupones (CM-01) | 20-10-2026 | Campañas, usos, compra mínima, productos y cupón de bienvenida |
| 03 | Invitados y confirmación de pago | 05-11-2026 | El invitado que crea cuenta conserva pedidos y puntos; `confirmar_pago()` solo para el servidor |
| 05 | Stock sin bloqueos (HU-22) | 05-11-2026 | El stock nunca frena una venta; marca la sobreventa |
| 06 | Aceptación de Términos (HU-25) | 06-11-2026 | Exige aceptar Términos y guarda fecha y versión |
| 07 | Fotos de productos | 06-11-2026 | Bucket público `productos` (solo imágenes, máx. 2 MB, solo admin escribe) |
| 08 | Club Befine (CM-02) | 07-11-2026 | Puntos, premios, Trae un amigo, vencimiento y reversa al cancelar |
| 02 | Reparto y roles (HU-16, 17, 31) | 11-11-2026 | Chofer con `pedidos.repartir`, avisos de WhatsApp, equipo y roles con auditoría |
| 09 | Reparto: entregados hoy | 11-11-2026 | Corrige que lo entregado hoy desapareciera del reparto |
| 10 | Avisos sin emojis | 11-11-2026 | Mensajes de WhatsApp en texto limpio |
| 11 | Correo de confirmación (HU-10) | 11-11-2026 | Un solo envío por pedido y registro de error |
| 14 | Clientes (HU-23, CM-03) | 13-11-2026 | Resumen, ficha, edición y bloqueo de clientes con auditoría |
| 15 | Despacho desde $7.000 (CM-05) | 18-11-2026 | $2.500 en todas las comunas, gratis desde $7.000; Términos v2026-11-17 |
| 16 | Dirección amigable de productos | 18-11-2026 | `productos.slug` y fichas en `/productos/<nombre>` (SEO) |

Números reservados: **12** (tareas programadas con pg_cron) y **13** (formulario de contacto).

## Pruebas automatizadas

Requisito: Node.js 20 o superior (no hay que instalar dependencias).

```bash
npm test
```

138 pruebas unitarias (`node:test`) en 22 archivos de `tests/unit/`, sobre el código real de `web/js/` y de la plantilla del correo: carrito, despacho por comuna y envío gratis desde $7.000 en todas las comunas, días hábiles de entrega (sin feriados) y rango de 24 a 48 h hábiles, validaciones (RUT, celular, correo, política de contraseñas), franjas horarias y reglas del panel de administración (acceso por rol, flujo de estados y filtro por fecha de entrega de pedidos, precios, SKU, inventario y cupones), el cupón del checkout y el pago con Mercado Pago (llamada a `crear-pago`, redirección segura y vuelta del pago), el historial de pedidos del cliente (detalle y "Volver a pedir" con el precio vigente), la reutilización del pedido pendiente de pago (M-02), la aceptación obligatoria de Términos y Privacidad (HU-25, Ley 21.719), la información legal (identificación del proveedor y derecho a retracto por producto), los productos "disponibles a pedido", las fotos de productos, el Club Befine, el reparto del chofer y la asignación de roles, el correo de confirmación de compra, la sección Clientes, los avisos de pedido pagado, las direcciones amigables y datos para buscadores (SEO) y las mejoras de rendimiento. Cada migración tiene además su prueba en seco SQL. Detalle en el Plan de Pruebas del repositorio de documentación (`06-Calidad/`).

**Integración continua:** cada Pull Request a `main` ejecuta automáticamente la revisión de sintaxis, las pruebas unitarias y la construcción de la imagen Docker con una prueba de que el sitio responde y envía sus cabeceras de seguridad. El PR muestra ✓ o ✗ antes de aprobarlo.

## Forma de trabajo

- **Kanban:** GitHub Projects "Befine Store - Desarrollo"; un milestone por sprint.
- **Ramas:** `main` protegida (Pull Request + 1 aprobación + 2 checks obligatorios) · ramas de trabajo `ivan`, `carlos`, `felipe` o `feature/HU-XX`.
- **Trazabilidad:** tarjeta `HU-XX` → rama → PR con `Cierra #N` → sección del informe.
- **Control de cambios:** solicitudes SC-01 a SC-06 y cambios menores CM-01 a CM-05, según el Plan de Gestión de Cambios (issues con la etiqueta `tipo:cambio`).
- **Plantillas:** issues de historia, cambio y bug, y plantilla de Pull Request en `.github/`.
- **Seguridad:** ninguna clave privada en el repositorio; los secretos viven en Supabase.
- **Historial de cambios:** [`CHANGELOG.md`](CHANGELOG.md).

## Estructura

```
web/              Sitio (inicio, catálogo, producto, checkout, cuenta, cómo funciona, 4 páginas legales, 404) y panel (admin.html)
  css/ js/        Estilos por capas y lógica por responsabilidad
  assets/ vendor/ Imágenes, sonidos y supabase-js versionado
  supabase/       Edge Functions y migraciones SQL (no se publican)
deploy/           Publicación en Cloudflare Pages: construir.sh, _headers, _redirects, robots.txt, sitemap.js
docker/           Configuración de nginx
tests/            Pruebas automatizadas (npm test)
.github/          Integración continua, ping a Supabase y plantillas de issues y PR
```
