-- =====================================================================
-- Reversa de la migración 06 (aceptación de Términos y Privacidad)
-- Pasos (en este orden):
--   1. Ejecutar de nuevo la sección 1 de 20261105_05_stock_sin_bloqueos.sql
--      (crear_pedido de la 05, sin exigir la aceptación) y sus permisos.
--   2. Ejecutar este archivo.
-- Ojo: borra la prueba de aceptación de los pedidos ya creados. Antes de revertir,
-- respaldar: select id, numero, terminos_aceptados_at, terminos_version from pedidos;
-- =====================================================================
alter table public.pedidos
  drop column if exists terminos_aceptados_at,
  drop column if exists terminos_version;
delete from public.parametros where clave = 'terminos_version';
delete from supabase_migrations.schema_migrations where version = '20261106000006';
