-- =====================================================================
-- Migración 10: avisos de reparto por WhatsApp sin emojis (aplicada el 11-nov-2026)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-17 (avisos por WhatsApp) · observación de la prueba manual del 11-nov-2026
-- Requiere:  02 aplicada.
-- Reversa:   volver a ejecutar la sección 2 (_mensaje_reparto) de 20261110_02_reparto_roles.sql.
-- Prueba:    20261111_10_prueba_en_seco.sql (10 + prueba; T01..T03 OK el 11-nov-2026)
--
-- Observación: los emojis del aviso (camión, check y gota) llegaban como "?" en algunos
-- celulares. Decisión del dueño: texto sin emojis y con buena ortografía. Se reemplazan además
-- la viñeta y el signo de multiplicación por "-" y "x" (caracteres simples en cualquier teclado).
-- =====================================================================

-- Mensaje de WhatsApp según el estado del pedido (en_ruta o entregado)
create or replace function public._mensaje_reparto(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
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
$$;

revoke execute on function public._mensaje_reparto(uuid) from public, anon, authenticated;
