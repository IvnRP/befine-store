# Befine Store

Plataforma de comercio electrónico propia para **Agua Purificada Befine**, microempresa de reparto de agua purificada a domicilio en Quilicura, Santiago (≈ 450 clientes activos). Proyecto de título Capstone APT · Duoc UC Plaza Norte · Grupo N3 (Plaxi Solutions) · 2026-2.

Documentación completa del proyecto: [Cmfg96/Documentos_Capstone_Grupo_N3](https://github.com/Cmfg96/Documentos_Capstone_Grupo_N3)

## Descripción

- **Qué hace:** tienda web *mobile-first* con catálogo, carrito, checkout por comuna (despacho y envío gratis desde $7.000), cuenta del cliente, reseñas reales de Google y, en construcción, pago con Mercado Pago, boleta/factura electrónica con OpenFactura, fidelización por puntos y panel de administración con roles.
- **Para quién:** clientes residenciales y empresas que compran agua a domicilio, y el dueño y los choferes de Befine que gestionan los pedidos.
- **Qué problema resuelve:** reemplaza la tienda en Shopify (costo recurrente, poca personalización) y centraliza en un solo sistema los pedidos que hoy se reparten entre WhatsApp y la tienda, permitiendo delegar la operación.

## Tecnologías

| Capa | Tecnología |
|---|---|
| Frontend | HTML5, CSS3 y JavaScript sin framework (SC-02) |
| Backend / base de datos | Supabase: PostgreSQL con Row Level Security, Auth y Edge Functions (Deno) |
| Integraciones | Google Places API (reseñas), Mercado Pago y OpenFactura (en construcción) |
| Despliegue | Docker + nginx |
| Pruebas | `node:test` (Node.js ≥ 20) |
| Gestión | GitHub Projects (Kanban), issues y Pull Requests con revisión obligatoria |

## Integrantes y roles

| Integrante | Rol |
|---|---|
| Iván Rodríguez Pinares | Product Owner y patrocinador; frontend de la tienda e integración con Supabase |
| Carlos Fuentes González | Backend, base de datos y seguridad |
| Felipe Moraga López | Scrum Master del Sprint 1, gestión ágil y calidad |

## Metodología

Híbrida **PMBOK + Scrum**: PMBOK para dirigir el proyecto (hitos, líneas base, control de cambios SC-01 a SC-04) y Scrum para construir el producto en sprints de dos semanas, con Product Backlog, Sprint Backlog, Definition of Done y retrospectivas. El trabajo se sigue en el tablero Kanban del proyecto y cada cambio entra a `main` mediante Pull Request aprobado por otro integrante.

## Arquitectura

```
Navegador (HTML + CSS + JS)
  └── js/data.js  →  único punto de acceso a Supabase (supabase-js, clave pública protegida por RLS)

Supabase
  ├── Auth (correo/contraseña y Google)
  ├── PostgreSQL: 21 tablas + roles y permisos, RLS en todas las tablas
  ├── Funciones SQL: crear_pedido(), tiene_permiso()
  └── Edge Functions: resenas-google (Mercado Pago y OpenFactura en construcción)

Servicios externos: Google Places · Mercado Pago · OpenFactura/SII · WhatsApp (wa.me)
```

Las claves privadas viven solo como secretos de las Edge Functions; nunca en el navegador. Detalle y diagramas UML en el repositorio de documentación (`05-Diseno/`).

## Ejecutar en local con Docker

Requisito: [Docker Desktop](https://www.docker.com/products/docker-desktop/) instalado y abierto.

```bash
git clone https://github.com/IvnRP/befine-store.git
cd befine-store
cp .env.example .env      # opcional: cambiar el puerto con WEB_PORT
docker compose up --build
```

Abrir **http://localhost:8080**. Para detenerlo: `docker compose down`.

| Archivo | Para qué sirve |
|---|---|
| `Dockerfile` | Construye la imagen: nginx + la carpeta `web/` |
| `docker-compose.yml` | Levanta el contenedor en el puerto 8080 |
| `docker/nginx.conf` | Compresión, caché y cabeceras de seguridad |
| `.env.example` | Variables de entorno de ejemplo (el `.env` real nunca se sube) |

## Ejecutar sin Docker

```bash
cd web
python -m http.server 8080
```

No abrir los HTML con doble clic (`file://`): el inicio de sesión con Google requiere `http://`.

## Pruebas automatizadas

Requisito: Node.js 20 o superior (no hay que instalar dependencias).

```bash
npm test
```

32 pruebas unitarias (`node:test`) sobre el código real de `web/js/`: carrito, despacho por comuna y envío gratis, días hábiles de entrega (sin feriados), validaciones (RUT, celular, correo, contraseña) y franjas horarias. Detalle en el Plan de Pruebas del repositorio de documentación (`06-Calidad/`).

## Forma de trabajo

- **Kanban:** GitHub Projects "Befine Store - Desarrollo"; un milestone por sprint.
- **Ramas:** `main` protegida (Pull Request + 1 aprobación) · ramas de trabajo `ivan`, `carlos`, `felipe` o `feature/HU-XX`.
- **Trazabilidad:** tarjeta `HU-XX` → rama → PR con `Cierra #N` → sección del informe.
- **Control de cambios:** issues con la etiqueta `tipo:cambio` (SC-01 a SC-04), según el Plan de Gestión de Cambios.
- **Plantillas:** issues de historia, cambio y bug, y plantilla de Pull Request en `.github/`.
- **Seguridad:** ninguna clave privada en el repositorio; los secretos viven en Supabase.

## Estructura

```
web/          Sitio (index, catálogo, producto, checkout, cuenta) + css/ js/ assets/
web/supabase/ Edge Functions de Supabase (no se publican en el contenedor)
docker/       Configuración de nginx
tests/        Pruebas automatizadas (npm test)
```
