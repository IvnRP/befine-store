-- =====================================================================
-- Migración 02 (PENDIENTE): reparto y avisos por WhatsApp
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Requiere:  01_seguridad_roles aplicada.
-- Aplicar:   cuando exista la pantalla del chofer en el frontend.
-- Reversa:   02_reparto_whatsapp_reversa.sql
--
-- Flujo:
--   en_preparacion ──(chofer: "En camino")──► en_ruta    → WhatsApp "va en camino"
--   en_ruta        ──(chofer: "Entregado")──► entregado  → WhatsApp con resumen; fin del ciclo
--
-- marcar_reparto() cambia el estado (queda en historial_pedido con el chofer
-- y la hora) y devuelve el teléfono + el mensaje listo. El frontend abre:
--   https://wa.me/<telefono>?text=<encodeURIComponent(mensaje)>
-- Para pasar a la API de WhatsApp Business más adelante, solo se cambia ese
-- paso del frontend por una Edge Function que envíe el mismo mensaje.
-- =====================================================================

insert into public.permisos (codigo, modulo, descripcion) values
  ('pedidos.repartir', 'Pedidos', 'Marcar pedidos "En camino" y "Entregado" y avisar al cliente');

insert into public.rol_permisos (rol_id, permiso) values ('chofer', 'pedidos.repartir');

create or replace function public.marcar_reparto(p_pedido uuid, p_estado public.estado_pedido)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_p      public.pedidos%rowtype;
  v_hora   timestamptz := now();
  v_items  text;
  v_dir    text;
  v_nom    text;
  v_msg    text;
begin
  if not public.tiene_permiso('pedidos.repartir') then
    raise exception 'No tienes permiso para actualizar repartos.' using errcode = '42501';
  end if;

  select * into v_p from public.pedidos where id = p_pedido for update;
  if not found then
    raise exception 'Pedido no encontrado.';
  end if;

  if p_estado = 'en_ruta' then
    if v_p.estado <> 'en_preparacion' then
      raise exception 'Solo un pedido "En preparación" puede pasar a "En camino" (estado actual: %).', v_p.estado;
    end if;
  elsif p_estado = 'entregado' then
    if v_p.estado <> 'en_ruta' then
      raise exception 'Solo un pedido "En camino" puede marcarse como entregado (estado actual: %).', v_p.estado;
    end if;
  else
    raise exception 'El chofer solo puede marcar "En camino" o "Entregado".';
  end if;

  -- El trigger trg_historial_pedido registra quién (auth.uid()) y cuándo
  update public.pedidos set estado = p_estado where id = p_pedido;

  -- Datos para el mensaje
  select string_agg('• ' || d.cantidad || ' × ' || concat_ws(' ', pr.nombre, vp.nombre), chr(10) order by pr.nombre, vp.nombre)
    into v_items
    from public.detalle_pedido d
    join public.variantes_producto vp on vp.id = d.variante_id
    join public.productos pr on pr.id = vp.producto_id
   where d.pedido_id = p_pedido;

  select di.calle || ' ' || di.numero || coalesce(' depto ' || di.depto, '') || ', ' || di.comuna
    into v_dir
    from public.direcciones di where di.id = v_p.direccion_id;

  v_nom := coalesce(nullif(split_part(trim(coalesce(v_p.contacto_nombre, '')), ' ', 1), ''), 'cliente');

  if p_estado = 'en_ruta' then
    v_msg := '🚚 *Befine — Pedido #' || v_p.numero || ' en camino*' || chr(10)
          || 'Hola ' || v_nom || ', tu pedido ya va en camino a ' || coalesce(v_dir, 'tu dirección') || '.' || chr(10)
          || 'Te avisaremos cuando sea entregado. 💧';
  else
    v_msg := '✅ *Befine — Pedido #' || v_p.numero || ' entregado*' || chr(10)
          || 'Hola ' || v_nom || ', tu pedido fue entregado el '
          || to_char(v_hora at time zone 'America/Santiago', 'DD/MM/YYYY "a las" HH24:MI') || '.' || chr(10)
          || coalesce(v_items, '') || chr(10)
          || 'Dirección: ' || coalesce(v_dir, '-') || chr(10)
          || 'Total pagado: $' || replace(to_char(v_p.total, 'FM999,999,999'), ',', '.') || chr(10)
          || '¡Gracias por preferir Befine! 💧';
  end if;

  return jsonb_build_object(
    'pedido_id', v_p.id,
    'numero',    v_p.numero,
    'estado',    p_estado,
    'hora',      v_hora,
    'telefono',  v_p.contacto_telefono,     -- formato 569XXXXXXXX
    'mensaje',   v_msg);
end;
$$;

revoke execute on function public.marcar_reparto(uuid, public.estado_pedido) from public, anon;
grant  execute on function public.marcar_reparto(uuid, public.estado_pedido) to authenticated;
