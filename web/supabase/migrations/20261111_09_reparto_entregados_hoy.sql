-- =====================================================================
-- Migración 09: corrección del reparto del día (pendiente de aplicar)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-16 (vista del chofer) · defecto hallado en la prueba manual del 11-nov-2026
-- Requiere:  02 aplicada.
-- Reversa:   volver a ejecutar la sección 2 (reparto_del_dia) de 20261110_02_reparto_roles.sql.
-- Prueba:    20261111_09_prueba_en_seco.sql (09 + prueba; T01..T02)
--
-- Defecto: un pedido atrasado (agendado para un día anterior) que el chofer entrega hoy
-- desaparecía del reparto de hoy, porque solo se mostraban los entregados con fecha de entrega
-- = hoy. El contador "Entregados" quedaba en 0 aunque el chofer sí entregó.
-- Corrección: reparto_del_dia() incluye también lo entregado HOY (según el historial), y un
-- pedido entregado ya no se marca como "atrasado".
-- =====================================================================

-- Pedidos para repartir en una fecha: SOLO pagados y SOLO los datos para entregar.
-- Si la fecha es hoy, incluye además los atrasados (fecha anterior aún sin entregar).
create or replace function public.reparto_del_dia(p_fecha date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
$$;

revoke execute on function public.reparto_del_dia(date) from public, anon;
grant  execute on function public.reparto_del_dia(date) to authenticated;
