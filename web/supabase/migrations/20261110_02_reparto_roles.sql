-- =====================================================================
-- Migración 02: reparto del chofer, avisos por WhatsApp y asignación de roles
--               (pendiente de aplicar)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historias: HU-16 (vista del chofer) · HU-17 (avisos por WhatsApp) · HU-31 (roles)
--            RF-16, RF-09, RF-02 · RNF-09 (auditoría)
-- Requiere:  01, 01b, 04, 03, 05, 06, 07 y 08 aplicadas.
-- Aplicar:   junto con la versión del panel que trae las secciones "Reparto" y
--            "Equipo y roles". Se escribió el 09-oct como "pendientes/02"; se
--            revisó y amplió el 10-nov (privacidad del chofer y roles).
-- Reversa:   20261110_02_reparto_roles_reversa.sql
-- Prueba:    20261110_02_prueba_en_seco.sql (02 + prueba; T01..T13)
--
-- Flujo del reparto:
--   en_preparacion ──(chofer: "En camino")──► en_ruta   → WhatsApp "va en camino"
--   en_ruta        ──(chofer: "Entregado")──► entregado → WhatsApp con resumen; fin del ciclo
--
-- Qué cambia:
--   1. Privacidad (Ley 21.719, minimización): el chofer deja de tener pedidos.ver (veía TODOS
--      los pedidos, también los no pagados) y recibe solo pedidos.repartir. Ve el reparto a
--      través de reparto_del_dia(): pedidos PAGADOS de una fecha y solo los datos para entregar.
--   2. marcar_reparto(): cambia el estado (queda en historial_pedido con el chofer y la hora)
--      y devuelve el teléfono y el mensaje listo para https://wa.me/<tel>?text=<mensaje>.
--      aviso_reparto(): vuelve a generar el mensaje sin cambiar el estado (reenviar).
--      Pasar a la API de WhatsApp Business = cambiar solo ese paso por una Edge Function.
--   3. Roles (HU-31): equipo(), buscar_usuario() y asignar_rol() solo para el administrador.
--      Nadie cambia su propio rol, nunca queda la tienda sin administrador y cada cambio se
--      registra en cambios_rol (quién, a quién, de qué rol a cuál y cuándo).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Permisos del chofer
-- ---------------------------------------------------------------------
insert into public.permisos (codigo, modulo, descripcion) values
  ('pedidos.repartir', 'Pedidos', 'Ver el reparto del día, marcar "En camino" y "Entregado" y avisar al cliente')
on conflict (codigo) do nothing;

insert into public.rol_permisos (rol_id, permiso) values ('chofer', 'pedidos.repartir') on conflict do nothing;
delete from public.rol_permisos where rol_id = 'chofer' and permiso = 'pedidos.ver';
update public.roles set descripcion = 'Reparte: ve los pedidos pagados del día y marca En camino / Entregado'
 where id = 'chofer';

-- La dirección de un pedido también la necesita quien reparte (por si se lee desde la API)
drop policy if exists direcciones_reparto on public.direcciones;
create policy direcciones_reparto on public.direcciones for select to authenticated
  using ((public.tiene_permiso('pedidos.ver') or public.tiene_permiso('pedidos.repartir'))
         and exists (select 1 from public.pedidos p where p.direccion_id = direcciones.id));

-- ---------------------------------------------------------------------
-- 2. Reparto
-- ---------------------------------------------------------------------
-- Mensaje de WhatsApp según el estado del pedido (en_ruta o entregado)
create or replace function public._mensaje_reparto(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p public.pedidos%rowtype; v_items text; v_dir text; v_nom text; v_msg text; v_hora timestamptz;
begin
  select * into v_p from public.pedidos where id = p_pedido;
  if not found then raise exception 'Pedido no encontrado.'; end if;

  select string_agg('• ' || d.cantidad || ' × ' || pr.nombre ||
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

  if v_p.estado = 'en_ruta' then
    v_msg := '🚚 *Befine — Pedido #' || v_p.numero || ' en camino*' || chr(10)
          || 'Hola ' || v_nom || ', tu pedido ya va en camino a ' || coalesce(v_dir, 'tu dirección') || '.' || chr(10)
          || 'Te avisaremos cuando sea entregado. 💧';
  elsif v_p.estado = 'entregado' then
    select max(h.created_at) into v_hora from public.historial_pedido h
     where h.pedido_id = p_pedido and h.estado_nuevo = 'entregado';
    v_msg := '✅ *Befine — Pedido #' || v_p.numero || ' entregado*' || chr(10)
          || 'Hola ' || v_nom || ', tu pedido fue entregado el '
          || to_char(coalesce(v_hora, now()) at time zone 'America/Santiago', 'DD/MM/YYYY "a las" HH24:MI') || '.' || chr(10)
          || coalesce(v_items, '') || chr(10)
          || 'Dirección: ' || coalesce(v_dir, '-') || chr(10)
          || case when v_p.es_canje then 'Premio Club Befine canjeado' || chr(10)
                  else 'Total pagado: $' || replace(to_char(v_p.total, 'FM999,999,999'), ',', '.') || chr(10) end
          || '¡Gracias por preferir Befine! 💧';
  else
    raise exception 'El aviso es solo para pedidos "En camino" o "Entregado".';
  end if;

  return jsonb_build_object('pedido_id', v_p.id, 'numero', v_p.numero, 'estado', v_p.estado,
                            'telefono', v_p.contacto_telefono,   -- 569XXXXXXXX
                            'mensaje', v_msg);
end;
$$;

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
             'atrasado', p.fecha_entrega < v_fecha,
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
  ) q;
  return v_res;
end;
$$;

-- El chofer marca "En camino" o "Entregado" → devuelve teléfono + mensaje para WhatsApp
create or replace function public.marcar_reparto(p_pedido uuid, p_estado public.estado_pedido)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_p public.pedidos%rowtype;
begin
  if not public.tiene_permiso('pedidos.repartir') then
    raise exception 'No tienes permiso para actualizar repartos.' using errcode = '42501';
  end if;
  select * into v_p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido no encontrado.'; end if;

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
  update public.historial_pedido
     set nota = case p_estado when 'en_ruta' then 'Reparto: en camino' else 'Reparto: entregado' end
   where pedido_id = p_pedido and estado_nuevo = p_estado and nota is null;

  return public._mensaje_reparto(p_pedido);
end;
$$;

-- Reenviar el aviso (no cambia el estado)
create or replace function public.aviso_reparto(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.tiene_permiso('pedidos.repartir') then
    raise exception 'No tienes permiso para avisar repartos.' using errcode = '42501';
  end if;
  return public._mensaje_reparto(p_pedido);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Roles: equipo, búsqueda por correo y asignación auditada (solo administrador)
-- ---------------------------------------------------------------------
create table if not exists public.cambios_rol (
  id           uuid primary key default gen_random_uuid(),
  perfil_id    uuid not null references public.perfiles(id) on delete cascade,
  rol_anterior text,
  rol_nuevo    text not null,
  cambiado_por uuid references public.perfiles(id),
  created_at   timestamptz not null default now()
);
alter table public.cambios_rol enable row level security;
drop policy if exists cambios_rol_admin on public.cambios_rol;
create policy cambios_rol_admin on public.cambios_rol for select to authenticated using (public.es_admin());

-- Personas con un rol distinto de cliente
create or replace function public.equipo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'Solo el administrador gestiona el equipo.' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', pf.id, 'nombre', pf.nombre, 'email', u.email,
                                                       'rol', pf.rol, 'activo', pf.activo) order by pf.rol, pf.nombre), '[]'::jsonb)
            from public.perfiles pf join auth.users u on u.id = pf.id
           where pf.rol <> 'cliente');
end;
$$;

-- Busca una cuenta registrada por su correo (para agregarla al equipo)
create or replace function public.buscar_usuario(p_email text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.es_admin() then raise exception 'Solo el administrador gestiona el equipo.' using errcode = '42501'; end if;
  select jsonb_build_object('id', pf.id, 'nombre', pf.nombre, 'email', u.email, 'rol', pf.rol, 'activo', pf.activo)
    into v
    from auth.users u join public.perfiles pf on pf.id = u.id
   where lower(u.email) = lower(trim(p_email)) and not coalesce(u.is_anonymous, false);
  return v;   -- null si no existe
end;
$$;

create or replace function public.asignar_rol(p_perfil uuid, p_rol text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_yo uuid := auth.uid(); v_actual text; v_admins integer;
begin
  if not public.es_admin() then raise exception 'Solo el administrador asigna roles.' using errcode = '42501'; end if;
  if p_perfil = v_yo then raise exception 'No puedes cambiar tu propio rol.'; end if;
  if not exists (select 1 from public.roles where id = p_rol) then raise exception 'El rol no existe.'; end if;
  if coalesce((select is_anonymous from auth.users where id = p_perfil), true) then
    raise exception 'La persona debe tener una cuenta registrada.';
  end if;

  select rol into v_actual from public.perfiles where id = p_perfil for update;
  if not found then raise exception 'La persona no existe.'; end if;
  if v_actual = p_rol then return jsonb_build_object('ok', true, 'rol', p_rol, 'sin_cambios', true); end if;

  -- Nunca dejar la tienda sin un administrador activo
  if v_actual = 'admin' then
    select count(*) into v_admins from public.perfiles where rol = 'admin' and activo and id <> p_perfil;
    if v_admins = 0 then raise exception 'Debe quedar al menos un administrador.'; end if;
  end if;

  update public.perfiles set rol = p_rol where id = p_perfil;
  insert into public.cambios_rol (perfil_id, rol_anterior, rol_nuevo, cambiado_por) values (p_perfil, v_actual, p_rol, v_yo);
  return jsonb_build_object('ok', true, 'rol', p_rol, 'rol_anterior', v_actual);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Permisos de ejecución
-- ---------------------------------------------------------------------
revoke execute on function public._mensaje_reparto(uuid)                         from public, anon, authenticated;
revoke execute on function public.reparto_del_dia(date)                          from public, anon;
revoke execute on function public.marcar_reparto(uuid, public.estado_pedido)     from public, anon;
revoke execute on function public.aviso_reparto(uuid)                            from public, anon;
revoke execute on function public.equipo()                                       from public, anon;
revoke execute on function public.buscar_usuario(text)                           from public, anon;
revoke execute on function public.asignar_rol(uuid, text)                        from public, anon;
grant  execute on function public.reparto_del_dia(date)                          to authenticated;
grant  execute on function public.marcar_reparto(uuid, public.estado_pedido)     to authenticated;
grant  execute on function public.aviso_reparto(uuid)                            to authenticated;
grant  execute on function public.equipo()                                       to authenticated;
grant  execute on function public.buscar_usuario(text)                           to authenticated;
grant  execute on function public.asignar_rol(uuid, text)                        to authenticated;

-- ---------------------------------------------------------------------
-- 5. Registro en el historial de migraciones de Supabase
-- ---------------------------------------------------------------------
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261110000002', '02_reparto_roles') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
