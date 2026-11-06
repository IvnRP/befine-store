-- =====================================================================
-- Reversa de la migración 05 (el stock nunca frena una venta)
-- No borra pedidos, pagos ni movimientos de stock ya registrados.
-- Pasos (en este orden, en el SQL Editor):
--   1. Ejecutar de nuevo la sección 4 de 20261020_04_cupones_reglas.sql
--      (crear_pedido de la 04, que vuelve a rechazar por falta de stock).
--   2. Ejecutar de nuevo la sección 2 de 20261105_03_invitados_pago.sql
--      (confirmar_pago de la 03, sin marca de sobreventa) y sus permisos.
--   3. Ejecutar este archivo (quita la columna y el registro).
-- =====================================================================
alter table public.pedidos drop column if exists sobreventa;
delete from supabase_migrations.schema_migrations where version = '20261105000005';
