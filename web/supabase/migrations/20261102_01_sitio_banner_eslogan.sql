-- =====================================================================
-- Banner y eslogan editables desde el panel (sección "Banner y eslogan")
-- ---------------------------------------------------------------------
-- 1) Valores iniciales en public.parametros (claves sitio_*): son los textos
--    originales de la tienda, así que la página se ve igual hasta que el
--    administrador los cambie.
-- 2) Lectura pública SOLO de las claves sitio_* (la portada las necesita sin
--    iniciar sesión). Escribir sigue exigiendo config.gestionar, por la
--    política existente parametros_admin.
-- 3) Bucket público "banners" en Storage para las imágenes. Subir, reemplazar y
--    borrar exige config.gestionar; verlas es público (son imágenes de la portada).
-- Se puede ejecutar más de una vez sin problema. Reversa al final (comentada).
-- =====================================================================
begin;

insert into public.parametros (clave, valor) values
  ('sitio_eyebrow',          'Agua purificada a domicilio · Quilicura y sector norte'),
  ('sitio_titulo',           'Recarga de agua purificada {a domicilio} en Quilicura'),
  ('sitio_subtitulo',        'Bidones y recargas de agua purificada de 20 L y 12 L, dispensadores frío/calor y despacho a domicilio en Quilicura, Huechuraba, Recoleta, Valle Grande y Valle Lo Campino. Envío gratis desde $7.000 y entrega en 24 horas hábiles.'),
  ('sitio_pie',              'Agua purificada a domicilio en el sector norte de Santiago. 5 años de operación.'),
  ('sitio_banner_desktop',   ''),
  ('sitio_banner_movil',     ''),
  ('sitio_banner_alt',       ''),
  ('sitio_banner_oscuridad', '45')
on conflict (clave) do nothing;

drop policy if exists parametros_sitio_lectura on public.parametros;
create policy parametros_sitio_lectura on public.parametros
  for select to anon, authenticated
  using (clave like 'sitio\_%');

-- Bucket público, solo imágenes, máximo 5 MB (SVG excluido: puede traer scripts)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('banners', 'banners', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists banners_insert on storage.objects;
drop policy if exists banners_update on storage.objects;
drop policy if exists banners_delete on storage.objects;
create policy banners_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'banners' and public.tiene_permiso('config.gestionar'));
create policy banners_update on storage.objects for update to authenticated
  using (bucket_id = 'banners' and public.tiene_permiso('config.gestionar'))
  with check (bucket_id = 'banners' and public.tiene_permiso('config.gestionar'));
create policy banners_delete on storage.objects for delete to authenticated
  using (bucket_id = 'banners' and public.tiene_permiso('config.gestionar'));

commit;

-- ---------------------------------------------------------------------
-- REVERSA (ejecutar solo si hay que deshacer):
--   drop policy if exists parametros_sitio_lectura on public.parametros;
--   drop policy if exists banners_insert on storage.objects;
--   drop policy if exists banners_update on storage.objects;
--   drop policy if exists banners_delete on storage.objects;
--   delete from public.parametros where clave like 'sitio\_%';
--   -- El bucket se borra desde el panel de Supabase (Storage → banners), no por SQL.
-- ---------------------------------------------------------------------
