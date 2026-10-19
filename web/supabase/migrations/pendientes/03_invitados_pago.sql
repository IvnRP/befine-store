-- =====================================================================
-- Migración 03 (PENDIENTE): compra como invitado + confirmación de pago
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Requiere:  01_seguridad_roles aplicada.
-- Aplicar:   junto con la Edge Function del webhook de Mercado Pago.
-- Reversa:   03_invitados_pago_reversa.sql
--
-- Invitados:
--   El checkout inicia una sesión anónima de Supabase (signInAnonymously)
--   y compra con crear_pedido() como cualquier cliente. Si marca "Crear mi
--   cuenta", el frontend llama auth.updateUser({ email, password }): el
--   usuario conserva el MISMO id, así que sus pedidos y puntos quedan en
--   su nueva cuenta. Este trigger completa su perfil en ese momento.
--
-- Pago (solo servidor):
--   El webhook de Mercado Pago (Edge Function con service_role) llama a
--   confirmar_pago(). Solo así un pedido pasa a "pagado" y luego, de forma
--   automática, a "en_preparacion". En ese momento se descuenta stock y se
--   suman los puntos al cliente. Es idempotente: si Mercado Pago repite la
--   notificación, no se cobra/suma dos veces.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Invitado → cuenta registrada
-- ---------------------------------------------------------------------
create or replace function public.handle_user_upgrade()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(old.is_anonymous, false) and not coalesce(new.is_anonymous, false) then
    update public.perfiles
       set nombre = case
                      when nombre = 'Invitado' then
                        left(coalesce(nullif(trim(new.raw_user_meta_data->>'nombre'), ''),
                                      nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
                                      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
                                      nombre), 80)
                      else nombre
                    end,
           telefono = coalesce(telefono,
                        left(nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'telefono', ''), '[^0-9+]', '', 'g'), ''), 20))
     where id = new.id;
  end if;
  return new;
end;
$$;

create trigger on_auth_user_upgraded
  after update of is_anonymous on auth.users
  for each row execute function public.handle_user_upgrade();

revoke execute on function public.handle_user_upgrade() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Confirmación de pago (webhook Mercado Pago)
--    Devuelve {ok, estado, ...}. Casos:
--      ok=true  repetido=true            → notificación ya procesada (no hace nada)
--      ok=false motivo=monto_no_coincide → se registra el pago como rechazado
--      ok=false motivo=pedido_no_pendiente → se registra; revisar/reembolsar
-- ---------------------------------------------------------------------
create or replace function public.confirmar_pago(
  p_pedido           uuid,
  p_mp_payment_id    text,
  p_monto            integer,
  p_raw              jsonb default null,
  p_mp_preference_id text  default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_p      public.pedidos%rowtype;
  v_saldo  integer;
begin
  if nullif(trim(p_mp_payment_id), '') is null then
    raise exception 'Falta el id de pago de Mercado Pago.';
  end if;

  -- Idempotencia: Mercado Pago puede notificar el mismo pago varias veces
  if exists (select 1 from public.pagos where mp_payment_id = p_mp_payment_id) then
    return jsonb_build_object('ok', true, 'repetido', true);
  end if;

  select * into v_p from public.pedidos where id = p_pedido for update;
  if not found then
    raise exception 'Pedido no encontrado.';
  end if;

  if v_p.estado <> 'pendiente_pago' then
    insert into public.pagos (pedido_id, estado, monto, mp_payment_id, mp_preference_id, raw_response, fecha_pago)
    values (p_pedido, 'aprobado', p_monto, p_mp_payment_id, p_mp_preference_id, p_raw, now());
    return jsonb_build_object('ok', false, 'motivo', 'pedido_no_pendiente', 'estado', v_p.estado);
  end if;

  if p_monto is distinct from v_p.total then
    insert into public.pagos (pedido_id, estado, monto, mp_payment_id, mp_preference_id, raw_response, fecha_pago)
    values (p_pedido, 'rechazado', coalesce(p_monto, 0), p_mp_payment_id, p_mp_preference_id, p_raw, now());
    return jsonb_build_object('ok', false, 'motivo', 'monto_no_coincide', 'esperado', v_p.total, 'recibido', p_monto);
  end if;

  insert into public.pagos (pedido_id, estado, monto, mp_payment_id, mp_preference_id, raw_response, fecha_pago)
  values (p_pedido, 'aprobado', p_monto, p_mp_payment_id, p_mp_preference_id, p_raw, now());

  -- pagado → en_preparacion (ambos quedan en el historial)
  update public.pedidos set estado = 'pagado'         where id = p_pedido;
  update public.pedidos set estado = 'en_preparacion' where id = p_pedido;
  update public.historial_pedido
     set nota = case estado_nuevo when 'pagado' then 'Pago confirmado por Mercado Pago (' || p_mp_payment_id || ')'
                                  else 'Automático al confirmar el pago' end
   where pedido_id = p_pedido and estado_nuevo in ('pagado', 'en_preparacion') and nota is null;

  -- Descuenta stock (nunca bajo cero: el pago ya está hecho)
  update public.variantes_producto vp
     set stock = greatest(vp.stock - d.cantidad, 0)
    from public.detalle_pedido d
   where d.pedido_id = p_pedido and vp.id = d.variante_id and vp.controla_stock;

  -- Suma puntos (el trigger trg_mov_puntos actualiza el saldo del perfil)
  if v_p.puntos_ganados > 0 then
    select puntos_saldo into v_saldo from public.perfiles where id = v_p.perfil_id for update;
    insert into public.movimientos_puntos (perfil_id, pedido_id, tipo, puntos, saldo_posterior, descripcion)
    values (v_p.perfil_id, p_pedido, 'acumulacion', v_p.puntos_ganados,
            coalesce(v_saldo, 0) + v_p.puntos_ganados, 'Compra pedido #' || v_p.numero);
  end if;

  return jsonb_build_object('ok', true, 'estado', 'en_preparacion',
                            'numero', v_p.numero, 'puntos_sumados', v_p.puntos_ganados);
end;
$$;

-- Solo el servidor (service_role) puede confirmar pagos
revoke execute on function public.confirmar_pago(uuid, text, integer, jsonb, text) from public, anon, authenticated;
grant  execute on function public.confirmar_pago(uuid, text, integer, jsonb, text) to service_role;
