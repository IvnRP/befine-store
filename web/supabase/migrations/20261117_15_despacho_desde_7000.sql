-- =====================================================================
-- Migración 15: el mismo despacho para todas las comunas, gratis desde $7.000
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-07 / RF-07 (costo de despacho por zona) · decisión del dueño del 17-nov-2026
-- Requiere:  01 a 14 aplicadas (en producción desde el Go-Live).
-- Aplicar:   junto con la versión del sitio que dice "Envío gratis en pedidos desde $7.000".
-- Reversa:   20261117_15_despacho_desde_7000_reversa.sql
-- Prueba:    20261117_15_prueba_en_seco.sql (15 + prueba; T01..T06)
--
-- Qué cambia:
--   1. Quilicura deja de tener despacho gratis con cualquier monto: paga $2.500 bajo $7.000,
--      igual que el Sector Norte. Desde $7.000 de subtotal el despacho es gratis en TODAS
--      las comunas (crear_pedido ya aplica parametros.envio_gratis_minimo a las zonas con costo,
--      no hay que cambiar la función).
--   2. El despacho gratis para clientes elegidos se entrega con un cupón personal (panel → Cupones).
--   3. Cambian las condiciones de despacho publicadas: nueva versión de los textos legales
--      (parametros.terminos_version = '2026-11-17'). Los pedidos nuevos guardan esa versión y
--      los anteriores conservan la que aceptaron.
-- Sin cambios de estructura: solo datos. Los pedidos ya creados no se recalculan.
-- =====================================================================

do $m15$
declare n int;
begin
  -- 1. Quilicura: $2.500 bajo el mínimo (mismo valor que el Sector Norte)
  update public.zonas_despacho set costo_despacho = 2500 where nombre = 'Quilicura';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'No se encontró la zona Quilicura (filas: %).', n; end if;

  -- El mínimo para el envío gratis debe existir (hoy $7.000)
  if not exists (select 1 from public.parametros
                  where clave = 'envio_gratis_minimo' and nullif(trim(valor), '') is not null) then
    raise exception 'Falta el parámetro envio_gratis_minimo.';
  end if;

  -- Ninguna zona activa debe quedar con despacho gratis sin mínimo
  if exists (select 1 from public.zonas_despacho where activo and costo_despacho = 0) then
    raise exception 'Quedó una zona activa con despacho $0.';
  end if;
end;
$m15$;

-- 3. Nueva versión de los textos legales (despacho.html cambia)
update public.parametros set valor = '2026-11-17' where clave = 'terminos_version';

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261117000015', '15_despacho_desde_7000') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
