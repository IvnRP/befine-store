-- =====================================================================
-- Reversa de la migración 04 (reglas de cupones)
-- Deja crear_pedido() como en la migración 01 y quita las columnas nuevas.
-- Ejecutar DESPUÉS de esta reversa: la sección 5 de 20261009_01_seguridad_roles.sql
-- (crear_pedido de la 01) y su sección 6 (permisos de crear_pedido).
-- =====================================================================
drop trigger  if exists trg_pedido_cancelado_cupon on public.pedidos;
drop function if exists public.devolver_uso_cupon();
drop function if exists public.revisar_cupon(text, jsonb);
drop index    if exists public.idx_pedidos_cupon;
alter table public.cupones drop constraint if exists cupones_bienvenida_con_cuenta;
-- crear_pedido() de la 04 depende de _evaluar_cupon(): se elimina y se vuelve a crear la de la 01
drop function if exists public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text);
drop function if exists public._evaluar_cupon(text, uuid, text, text, jsonb, boolean);
alter table public.cupones
  drop column if exists requiere_cuenta,
  drop column if exists solo_primera_compra,
  drop column if exists usos_por_cliente,
  drop column if exists descripcion;
delete from supabase_migrations.schema_migrations where version = '20261019000004';
