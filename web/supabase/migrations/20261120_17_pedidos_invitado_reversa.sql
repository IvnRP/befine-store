-- =====================================================================
-- Reversa de la migración 17 (pedidos de invitado) — Befine Store
-- Publicar ANTES la versión del sitio sin pedido_vuelta / reclamar_pedidos_invitado
-- (si no, la vuelta desde otro navegador vuelve a mostrar "No pudimos revisar tu pedido").
-- Los pedidos que ya pasaron a una cuenta quedan en esa cuenta (es su dueña con correo
-- confirmado); el detalle de cada traspaso queda en cambios_cliente.
-- =====================================================================
drop function if exists public.reclamar_pedidos_invitado();
drop function if exists public.pedido_vuelta(uuid);
drop function if exists public.correo_mascara(text);
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261120000017'$q$;
  end if;
end;
$reg$;
