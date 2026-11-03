-- REVERSA de la migración 02 (reparto y avisos por WhatsApp)
-- No cambia el estado de pedidos ya marcados; solo quita la función y el permiso.
drop function if exists public.marcar_reparto(uuid, public.estado_pedido);
delete from public.rol_permisos where permiso = 'pedidos.repartir';
delete from public.permisos     where codigo  = 'pedidos.repartir';
