-- REVERSA de la migración 21 (pedidos fuera de la página) — Befine Store
-- Vuelve reparto_del_dia() y el aviso de WhatsApp a su versión anterior (migraciones 09 y 10) y quita lo nuevo.
-- PROTECCIÓN: si ya hay pedidos fuera de la página registrados, se detiene sin borrar nada (son ventas reales
-- con su boleta). En ese caso, la reversa solo puede hacerse después de decidir qué hacer con esos pedidos.
do $chk$
begin
  if exists (select 1 from public.pedidos where canal <> 'web') then
    raise exception 'Hay pedidos fuera de la página registrados: la reversa se detiene para no perder ventas.';
  end if;
end;
$chk$;

drop function if exists public.ajustar_pedido_manual(uuid, integer, text);
drop function if exists public.cobrar_pedido(uuid, text);
drop function if exists public.registrar_pedido_manual(jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, text);
drop function if exists public.opciones_pedido_manual();
drop index if exists public.idx_pedidos_fuera_pagina;
alter table public.pedidos
  drop constraint if exists pedidos_cobro_fuera_pagina,
  drop constraint if exists pedidos_perfil_o_fuera_pagina,
  drop constraint if exists pedidos_descuento_manual_check,
  drop constraint if exists pedidos_cobro_estado_check,
  drop constraint if exists pedidos_metodo_pago_check,
  drop constraint if exists pedidos_canal_check,
  drop column if exists creado_por,
  drop column if exists descuento_motivo,
  drop column if exists descuento_manual,
  drop column if exists cobrado_por,
  drop column if exists cobrado_at,
  drop column if exists cobro_estado,
  drop column if exists metodo_pago,
  drop column if exists canal;
alter table public.pedidos alter column perfil_id set not null;
delete from public.direcciones where perfil_id is null and not exists (select 1 from public.pedidos p where p.direccion_id = direcciones.id);
alter table public.direcciones alter column perfil_id set not null;
delete from public.rol_permisos where permiso = 'pedidos.registrar';
delete from public.permisos where codigo = 'pedidos.registrar';

-- Versiones anteriores (migraciones 09 y 10)
CREATE OR REPLACE FUNCTION public.reparto_del_dia(p_fecha date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hoy   date := (now() at time zone 'America/Santiago')::date;
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Santiago')::date);
  v_res   jsonb;
begin
  if not public.tiene_permiso('pedidos.repartir') then
    raise exception 'No tienes permiso para ver el reparto.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x order by x->>'comuna', x->>'calle', (x->>'numero_pedido')::bigint), '[]'::jsonb) into v_res
  from (
    select jsonb_build_object(
             'id', p.id, 'numero_pedido', p.numero, 'estado', p.estado,
             'fecha_entrega', p.fecha_entrega,
             'atrasado', p.fecha_entrega < v_fecha and p.estado <> 'entregado',
             'nombre', p.contacto_nombre, 'telefono', p.contacto_telefono,
             'calle', d.calle, 'numero', d.numero, 'depto', d.depto, 'comuna', d.comuna, 'referencia', d.referencia,
             'notas', p.notas, 'es_canje', p.es_canje,
             'items', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'cantidad', dp.cantidad, 'producto', pr.nombre,
                                 'variante', nullif(vp.nombre, 'Estándar')) order by pr.nombre), '[]'::jsonb)
                         from public.detalle_pedido dp
                         join public.variantes_producto vp on vp.id = dp.variante_id
                         join public.productos pr on pr.id = vp.producto_id
                        where dp.pedido_id = p.id)) as x
      from public.pedidos p
      left join public.direcciones d on d.id = p.direccion_id
     where (p.fecha_entrega = v_fecha and p.estado in ('en_preparacion', 'en_ruta', 'entregado'))
        or (v_fecha = v_hoy and p.fecha_entrega < v_fecha and p.estado in ('en_preparacion', 'en_ruta'))
        -- Corrección 09: lo entregado HOY aparece hoy aunque estuviera agendado para otro día (atrasado)
        or (v_fecha = v_hoy and p.estado = 'entregado' and exists (
              select 1 from public.historial_pedido h
               where h.pedido_id = p.id and h.estado_nuevo = 'entregado'
                 and (h.created_at at time zone 'America/Santiago')::date = v_hoy))
  ) q;
  return v_res;
end;
$function$

;
CREATE OR REPLACE FUNCTION public._mensaje_reparto(p_pedido uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p public.pedidos%rowtype; v_items text; v_dir text; v_nom text; v_msg text; v_hora timestamptz;
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

  select di.calle || ' ' || di.numero || coalesce(', depto ' || nullif(di.depto, ''), '') || ', ' || di.comuna
    into v_dir from public.direcciones di where di.id = v_p.direccion_id;

  v_nom := coalesce(nullif(split_part(trim(coalesce(v_p.contacto_nombre, '')), ' ', 1), ''), 'cliente');

  -- Texto sin emojis (decisión del dueño, 11-nov-2026): se ve igual en cualquier celular.
  -- El *texto* entre asteriscos WhatsApp lo muestra en negrita.
  if v_p.estado = 'en_ruta' then
    v_msg := '*Befine: tu pedido #' || v_p.numero || ' va en camino*' || chr(10)
          || 'Hola, ' || v_nom || '. Tu pedido va en camino a ' || coalesce(v_dir, 'tu dirección') || '.' || chr(10)
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
                  else 'Total pagado: $' || replace(to_char(v_p.total, 'FM999,999,999'), ',', '.') || chr(10) end
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
revoke execute on function public._mensaje_reparto(uuid) from public, anon, authenticated;

do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261125000021'$q$;
  end if;
exception when others then
  raise notice 'No se pudo actualizar schema_migrations: %', sqlerrm;
end;
$reg$;
