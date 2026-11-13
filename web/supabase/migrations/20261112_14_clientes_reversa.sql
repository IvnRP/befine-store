-- =====================================================================
-- Reversa de la migración 14 (clientes en el panel) — Befine Store
-- Deja la base como antes de la 14. Se pierde el registro de cambios_cliente
-- (los datos editados de los clientes se conservan como están).
-- =====================================================================
drop function if exists public.editar_cliente(uuid, jsonb);
drop function if exists public.cliente_detalle(uuid);
drop function if exists public.clientes_resumen();
drop table if exists public.cambios_cliente;
