-- =====================================================================
-- Migración 07: fotos de productos en Supabase Storage (aplicada el 06-nov-2026)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  Pulido de la tienda (fotos reales) · RF-03/RF-04 (catálogo y ficha), RF-17 (catálogo admin)
-- Requiere:  01 aplicada (tiene_permiso). Independiente de 03, 04, 05 y 06.
-- Aplicar:   cuando quieras; la tienda funciona igual sin fotos (muestra el degradado).
--            Después de aplicarla, subir las 20 imágenes WebP al bucket "productos"
--            (Storage → productos → Upload) desde D:\CAPSTONE\Fotos_Befine\web_productos.
-- Reversa:   20261106_07_fotos_productos_reversa.sql
-- Prueba:    20261106_07_prueba_en_seco.sql (07 + prueba; T01..T05 OK el 06-nov-2026)
--
-- Qué cambia:
--   1. Bucket público "productos": solo imágenes (webp, jpeg, png) de hasta 2 MB.
--      Público = se lee por URL sin sesión (lo sirve el CDN de Supabase).
--   2. Políticas de storage.objects: solo quien tiene catalogo.gestionar (admin) sube,
--      reemplaza o borra fotos de ese bucket. Los clientes y anónimos no pueden escribir.
--   3. productos.imagen_url: ruta del archivo GRANDE dentro del bucket (ej. "bidon-12l-1000.webp").
--      Se guarda la ruta y no la URL completa para que no dependa del proyecto (igual que el
--      SKU en vez del UUID). La tienda arma la URL y usa la versión "-400" en tarjetas y carrito.
--      Solo se completa donde imagen_url está vacía (no pisa fotos cargadas desde el panel).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Bucket público de fotos de productos
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('productos', 'productos', true, 2097152, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------
-- 2. Quién puede escribir en el bucket (lectura: pública por URL)
-- ---------------------------------------------------------------------
drop policy if exists productos_fotos_subir     on storage.objects;
drop policy if exists productos_fotos_modificar on storage.objects;
drop policy if exists productos_fotos_borrar    on storage.objects;

create policy productos_fotos_subir on storage.objects
  for insert to authenticated
  with check (bucket_id = 'productos' and public.tiene_permiso('catalogo.gestionar'));

create policy productos_fotos_modificar on storage.objects
  for update to authenticated
  using      (bucket_id = 'productos' and public.tiene_permiso('catalogo.gestionar'))
  with check (bucket_id = 'productos' and public.tiene_permiso('catalogo.gestionar'));

create policy productos_fotos_borrar on storage.objects
  for delete to authenticated
  using (bucket_id = 'productos' and public.tiene_permiso('catalogo.gestionar'));

-- ---------------------------------------------------------------------
-- 3. Foto de cada producto (por SKU de una de sus variantes: estable entre bases)
-- ---------------------------------------------------------------------
comment on column public.productos.imagen_url is
  'Foto del producto: ruta del archivo grande en el bucket "productos" (ej. bidon-12l-1000.webp) o URL completa. La tienda usa la versión -400 en tarjetas.';

update public.productos p
   set imagen_url = x.archivo
  from public.variantes_producto v
  join (values
    ('BEF-PACK-4REC12',    'pack-4-recargas-12l-1000.webp'),
    ('BEF-PACK-3BID20',    'pack-3-bidones-20l-1000.webp'),
    ('BEF-DISP-MESA',      'dispensador-sobre-mesa-1000.webp'),
    ('BEF-DISP-OCULTO',    'dispensador-bidon-oculto-1000.webp'),
    ('BEF-DISP-USB',       'dispensador-usb-1000.webp'),
    ('BEF-DISP-SINOCULTO', 'dispensador-sin-bidon-oculto-1000.webp'),
    ('BEF-DISP-SOPORTE',   'dispensador-soporte-blanco-1000.webp'),
    ('BEF-BID-12',         'bidon-12l-1000.webp'),
    ('BEF-BID-20',         'bidon-20l-1000.webp'),
    ('BEF-REC-12',         'bidon-12l-1000.webp'),
    ('BEF-REC-20-BEFINE',  'bidon-20l-befine-1000.webp')
  ) as x(sku, archivo) on x.sku = v.sku
 where v.producto_id = p.id
   and coalesce(p.imagen_url, '') = '';

-- ---------------------------------------------------------------------
-- 4. Registro en el historial de migraciones de Supabase
-- ---------------------------------------------------------------------
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261106000007', '07_fotos_productos') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
