-- =====================================================================
-- Reversa de la migración 15 (despacho desde $7.000) — Befine Store
-- Quilicura vuelve a despacho gratis con cualquier monto y los textos legales a la versión
-- 2026-11-07. Publicar a la vez la versión anterior del sitio (despacho.html y data.js).
-- =====================================================================
update public.zonas_despacho set costo_despacho = 0 where nombre = 'Quilicura';
update public.parametros set valor = '2026-11-07' where clave = 'terminos_version';
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261117000015'$q$;
  end if;
end;
$reg$;
