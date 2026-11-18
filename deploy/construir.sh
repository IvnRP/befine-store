#!/usr/bin/env bash
# Arma la carpeta "dist" que se publica (Cloudflare Pages / Netlify):
# el sitio de web/ SIN la carpeta supabase (migraciones y funciones no son públicas) + cabeceras
# y redirecciones de las direcciones antiguas de Shopify.
set -euo pipefail
rm -rf dist
mkdir -p dist
tar -C web --exclude=./supabase --exclude=./README.md -cf - . | tar -C dist -xf -
cp deploy/_headers dist/_headers
cp deploy/_redirects dist/_redirects   # direcciones antiguas de Shopify → páginas nuevas
echo "Sitio listo en dist/ ($(find dist -type f | wc -l) archivos)"
