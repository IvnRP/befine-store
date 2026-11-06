-- =====================================================================
-- Reversa de la migración 07 (fotos de productos en Storage)
-- Pasos (en este orden):
--   1. Ejecutar este archivo (quita las políticas y las rutas de fotos de la 07).
--   2. En el panel: Storage → productos → seleccionar todo → Delete; luego
--      "Delete bucket". Supabase no permite borrar archivos ni buckets con SQL directo.
-- La tienda vuelve a mostrar el degradado por categoría (no se rompe nada).
-- =====================================================================
drop policy if exists productos_fotos_subir     on storage.objects;
drop policy if exists productos_fotos_modificar on storage.objects;
drop policy if exists productos_fotos_borrar    on storage.objects;

update public.productos
   set imagen_url = null
 where imagen_url like '%-1000.webp' and imagen_url not like 'http%';

delete from supabase_migrations.schema_migrations where version = '20261106000007';
