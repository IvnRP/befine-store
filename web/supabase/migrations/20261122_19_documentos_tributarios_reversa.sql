-- =====================================================================
-- Reversa de la migración 19 (boletas y facturas en la tienda) — Befine Store
-- Publicar ANTES la versión del sitio sin "Subir documento" ni "Descargar boleta".
-- Los PDF ya subidos NO se borran (quedan en el bucket "documentos" como respaldo); para
-- eliminarlos, hacerlo a mano en Storage. Las filas de documentos_tributarios se conservan.
-- =====================================================================
drop function if exists public.registrar_documento(uuid, public.tipo_dte, bigint);
drop index if exists public.dte_un_emitido_por_pedido;
alter table public.documentos_tributarios drop column if exists registrado_por, drop column if exists archivo;
drop policy if exists documentos_subir     on storage.objects;
drop policy if exists documentos_modificar on storage.objects;
drop policy if exists documentos_borrar    on storage.objects;
drop policy if exists documentos_ver       on storage.objects;
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261122000019'$q$;
  end if;
end;
$reg$;
