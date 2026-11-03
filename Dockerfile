# Befine Store — imagen del sitio web
# Sirve la carpeta web/ (HTML/CSS/JS) con nginx. El backend (Supabase) vive en la nube,
# por lo que el contenedor solo entrega archivos estáticos.

FROM nginx:1.27-alpine

# Configuración del servidor (compresión, caché y cabeceras de seguridad)
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf

# Sitio público (lo que ve el cliente)
COPY web/ /usr/share/nginx/html/

EXPOSE 80

# Docker revisa cada 30 s que el sitio responda
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -q --spider http://localhost/ || exit 1
