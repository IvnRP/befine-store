-- REVERSA de la migración 23 (ventas del chofer y caja) — Befine Store
-- Deja todo como estaba con 22 aplicada. Pegar completo en el SQL Editor y ejecutar.
-- OJO: BORRA las ventas anotadas por los choferes. Antes, descárgalas (Table Editor → ventas_reparto → Export CSV)
-- o confirma que no hay: la reversa se detiene si encuentra ventas no anuladas.
begin;

do $chk$
begin
  if to_regclass('public.ventas_reparto') is not null
     and exists (select 1 from public.ventas_reparto where anulada_at is null) then
    raise exception 'Hay ventas anotadas por los choferes. Descárgalas y anúlalas antes de deshacer la migración 23.';
  end if;
end;
$chk$;

drop function if exists public.caja_resumen(date, date, uuid);
drop function if exists public.mis_ventas_reparto(date);
drop function if exists public._entregas_rango(date, date, uuid);
drop function if exists public._ventas_lista(date, date, uuid);
drop function if exists public.cliente_reparto(text);
drop function if exists public.anular_venta_reparto(uuid, text);
drop function if exists public.registrar_venta_reparto(jsonb, text, text, text, text, text, integer, text);
drop table if exists public.ventas_reparto_items;
drop table if exists public.ventas_reparto;
delete from public.rol_permisos where permiso = 'caja.ver';
delete from public.permisos where codigo = 'caja.ver';

-- Aviso de reparto original (como en la 21/22)
CREATE OR REPLACE FUNCTION public._mensaje_reparto(p_pedido uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p public.pedidos%rowtype; v_items text; v_dir text; v_nom text; v_msg text; v_hora timestamptz; v_total text; v_medio text;
begin
  select * into v_p from public.pedidos where id = p_pedido;
  if not found then raise exception 'Pedido no encontrado.'; end if;

  select string_agg('- ' || d.cantidad || ' x ' || pr.nombre ||
                    case when vp.nombre is null or vp.nombre = 'Estándar' then '' else ' (' || vp.nombre || ')' end,
                    chr(10) order by pr.nombre, vp.nombre)
    into v_items
    from public.detalle_pedido d
    join public.variantes_producto vp on vp.id = d.variante_id
    join public.productos pr on pr.id = vp.producto_id
   where d.pedido_id = p_pedido;

  select di.calle || coalesce(' ' || nullif(di.numero, ''), '') || coalesce(', depto ' || nullif(di.depto, ''), '') || ', ' || di.comuna
    into v_dir from public.direcciones di where di.id = v_p.direccion_id;

  v_nom   := coalesce(nullif(split_part(trim(coalesce(v_p.contacto_nombre, '')), ' ', 1), ''), 'cliente');
  v_total := '$' || replace(to_char(v_p.total, 'FM999,999,999'), ',', '.');
  v_medio := case v_p.metodo_pago when 'efectivo' then 'efectivo' when 'tarjeta' then 'tarjeta'
                                  when 'transferencia' then 'transferencia' else null end;

  if v_p.estado = 'en_ruta' then
    v_msg := '*Befine: tu pedido #' || v_p.numero || ' va en camino*' || chr(10)
          || 'Hola, ' || v_nom || '. Tu pedido va en camino a ' || coalesce(v_dir, 'tu dirección') || '.' || chr(10)
          || case when v_p.canal <> 'web' and v_p.cobro_estado = 'por_cobrar'
                  then 'Total a pagar: ' || v_total || coalesce(' (' || v_medio || ')', '') || '.' || chr(10) else '' end
          || 'Te avisaremos cuando sea entregado.';
  elsif v_p.estado = 'entregado' then
    select max(h.created_at) into v_hora from public.historial_pedido h
     where h.pedido_id = p_pedido and h.estado_nuevo = 'entregado';
    v_msg := '*Befine: tu pedido #' || v_p.numero || ' fue entregado*' || chr(10)
          || 'Hola, ' || v_nom || '. Tu pedido fue entregado el '
          || to_char(coalesce(v_hora, now()) at time zone 'America/Santiago', 'DD/MM/YYYY "a las" HH24:MI') || ' h.' || chr(10)
          || 'Productos:' || chr(10)
          || coalesce(v_items, '') || chr(10)
          || 'Dirección: ' || coalesce(v_dir, '-') || chr(10)
          || case when v_p.es_canje then 'Premio del Club Befine canjeado.' || chr(10)
                  when v_p.canal <> 'web' and v_p.cobro_estado = 'por_cobrar'
                    then 'Total a pagar: ' || v_total || coalesce(' (' || v_medio || ')', '') || chr(10)
                  else 'Total pagado: ' || v_total || coalesce(' (' || v_medio || ')', '') || chr(10) end
          || '¡Gracias por preferir Befine!';
  else
    raise exception 'El aviso es solo para pedidos "En camino" o "Entregado".';
  end if;

  return jsonb_build_object('pedido_id', v_p.id, 'numero', v_p.numero, 'estado', v_p.estado,
                            'telefono', v_p.contacto_telefono,   -- 569XXXXXXXX
                            'mensaje', v_msg);
end;
$function$

;

drop function if exists public._saludo(text, text);

do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261127000023'$q$;
  end if;
end;
$reg$;
commit;
