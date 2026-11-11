-- =====================================================================
-- Reversa de la migración 02 (reparto, avisos por WhatsApp y roles)
-- No cambia el estado de pedidos ya marcados ni los roles ya asignados.
-- Devuelve al chofer el permiso pedidos.ver (comportamiento de la migración 01).
-- Ojo: borra el registro de cambios de rol. Antes de revertir, respaldar:
--   select * from public.cambios_rol;
-- =====================================================================
drop function if exists public.asignar_rol(uuid, text);
drop function if exists public.buscar_usuario(text);
drop function if exists public.equipo();
drop function if exists public.aviso_reparto(uuid);
drop function if exists public.marcar_reparto(uuid, public.estado_pedido);
drop function if exists public.reparto_del_dia(date);
drop function if exists public._mensaje_reparto(uuid);
drop table if exists public.cambios_rol;

drop policy if exists direcciones_reparto on public.direcciones;
create policy direcciones_reparto on public.direcciones for select to authenticated
  using (public.tiene_permiso('pedidos.ver')
         and exists (select 1 from public.pedidos p where p.direccion_id = direcciones.id));

insert into public.rol_permisos (rol_id, permiso) values ('chofer', 'pedidos.ver') on conflict do nothing;
delete from public.rol_permisos where permiso = 'pedidos.repartir';
delete from public.permisos     where codigo  = 'pedidos.repartir';
update public.roles set descripcion = 'Ve los pedidos y datos de entrega' where id = 'chofer';
delete from supabase_migrations.schema_migrations where version = '20261110000002';
