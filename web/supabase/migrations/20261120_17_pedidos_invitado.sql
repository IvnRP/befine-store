-- =====================================================================
-- Migración 17: compra como invitado desde OTRO navegador (vuelta de Mercado Pago)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  Incidente 19-nov-2026: una clienta pagó como invitada (abrió la tienda desde
--            WhatsApp, pagó en la app de Mercado Pago) y volvió a un navegador distinto, sin
--            su sesión de invitado. El pago quedó confirmado (webhook), pero la tienda mostró
--            "No pudimos revisar tu pedido" y no pudo crear su cuenta.
--            HU-08/HU-09 (pago), HU-03 (cuenta), RF-10 (historial).
-- Requiere:  01 a 16 aplicadas.
-- Reversa:   20261120_17_pedidos_invitado_reversa.sql
-- Prueba:    20261120_17_prueba_en_seco.sql (17 + prueba; T01..T12)
--
-- Qué hace:
--   1. pedido_vuelta(id): la página de vuelta de Mercado Pago muestra el resultado aunque
--      el navegador no tenga la sesión del invitado. Entrega SOLO número, estado, montos,
--      fecha y el correo enmascarado (ma•••@gmail.com); nada de dirección, teléfono ni nombre.
--      El id es un UUID aleatorio que solo viaja en el enlace de vuelta, y la consulta vale
--      7 días desde la compra.
--   2. reclamar_pedidos_invitado(): cuando un cliente entra con una cuenta cuyo correo ya
--      está CONFIRMADO, sus compras como invitado hechas con ese mismo correo pasan a su
--      cuenta (pedidos, direcciones y puntos). La tienda la llama sola al iniciar sesión.
--      Solo se toman perfiles de invitado (anónimos) en que TODOS sus pedidos usan ese correo
--      (un celular compartido con otro correo no se mezcla). Es idempotente y queda
--      registrado en cambios_cliente.
-- Sin cambios de RLS: los pedidos siguen visibles solo para su dueño.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Resultado del pago para la página de vuelta (sin datos personales)
-- ---------------------------------------------------------------------
create or replace function public.correo_mascara(p_correo text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_correo is null or position('@' in p_correo) < 2 then null
    else left(split_part(lower(trim(p_correo)), '@', 1),
              case when length(split_part(lower(trim(p_correo)), '@', 1)) <= 2 then 1 else 2 end)
         || '•••@' || split_part(lower(trim(p_correo)), '@', 2)
  end
$$;

create or replace function public.pedido_vuelta(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'id',              p.id,
           'numero',          p.numero,
           'estado',          p.estado,
           'total',           p.total,
           'descuento_cupon', p.descuento_cupon,
           'fecha_entrega',   p.fecha_entrega,
           'tipo_documento',  p.tipo_documento,
           'correo',          public.correo_mascara(p.contacto_email),
           'invitado',        coalesce(u.is_anonymous, true))
    from public.pedidos p
    left join auth.users u on u.id = p.perfil_id
   where p.id = p_pedido
     and p.created_at > now() - interval '7 days'
$$;

revoke execute on function public.pedido_vuelta(uuid) from public;
grant  execute on function public.pedido_vuelta(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Compras como invitado → cuenta con el mismo correo (confirmado)
-- ---------------------------------------------------------------------
create or replace function public.reclamar_pedidos_invitado()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_email text; v_confirmado timestamptz; v_anon boolean;
  v_src record; v_numeros bigint[]; v_todos bigint[] := '{}'; v_puntos integer := 0;
  v_tiene_principal boolean;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_sesion');
  end if;
  select lower(trim(u.email)), u.email_confirmed_at, coalesce(u.is_anonymous, false)
    into v_email, v_confirmado, v_anon
    from auth.users u where u.id = v_uid;
  if v_anon or coalesce(v_email, '') = '' or v_confirmado is null then
    return jsonb_build_object('ok', false, 'motivo', 'correo_sin_confirmar');
  end if;

  for v_src in
    select pf.id, pf.puntos_saldo, pf.telefono
      from public.perfiles pf
      join auth.users u on u.id = pf.id and u.is_anonymous
     where pf.id <> v_uid
       and exists (select 1 from public.pedidos p
                    where p.perfil_id = pf.id and lower(trim(p.contacto_email)) = v_email)
       and not exists (select 1 from public.pedidos p
                        where p.perfil_id = pf.id and lower(trim(coalesce(p.contacto_email, ''))) <> v_email)
     order by pf.created_at
     for update of pf
  loop
    select exists (select 1 from public.direcciones where perfil_id = v_uid and es_principal)
      into v_tiene_principal;
    update public.direcciones
       set perfil_id = v_uid, es_principal = es_principal and not v_tiene_principal
     where perfil_id = v_src.id;

    with m as (update public.pedidos set perfil_id = v_uid where perfil_id = v_src.id returning numero)
    select coalesce(array_agg(numero order by numero), '{}') into v_numeros from m;

    -- Puntos: se mueven sus movimientos y el saldo (el trigger de saldo solo actúa al insertar)
    update public.movimientos_puntos set perfil_id = v_uid where perfil_id = v_src.id;
    if coalesce(v_src.puntos_saldo, 0) > 0 then
      update public.perfiles set puntos_saldo = puntos_saldo + v_src.puntos_saldo where id = v_uid;
      update public.perfiles set puntos_saldo = 0 where id = v_src.id;
    end if;
    update public.perfiles set telefono = coalesce(telefono, v_src.telefono) where id = v_uid;

    insert into public.cambios_cliente (perfil_id, cambiado_por, antes, despues)
    values (v_uid, v_uid,
            jsonb_build_object('motivo', 'compra_como_invitado', 'invitado_id', v_src.id),
            jsonb_build_object('pedidos', to_jsonb(v_numeros), 'puntos', coalesce(v_src.puntos_saldo, 0)));

    v_todos := v_todos || v_numeros;
    v_puntos := v_puntos + coalesce(v_src.puntos_saldo, 0);
  end loop;

  return jsonb_build_object('ok', true, 'pedidos', cardinality(v_todos),
                            'numeros', to_jsonb(v_todos), 'puntos', v_puntos);
end;
$$;

revoke execute on function public.reclamar_pedidos_invitado() from public, anon;
grant  execute on function public.reclamar_pedidos_invitado() to authenticated;

comment on function public.pedido_vuelta(uuid) is
  'Vuelta de Mercado Pago sin sesión: número, estado y montos del pedido, correo enmascarado (migración 17).';
comment on function public.reclamar_pedidos_invitado() is
  'Pasa a la cuenta (correo confirmado) las compras como invitado hechas con ese correo (migración 17).';

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261120000017', '17_pedidos_invitado') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
