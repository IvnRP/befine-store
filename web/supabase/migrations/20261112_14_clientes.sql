-- =====================================================================
-- Migración 14: clientes en el panel de administración
--               (aplicada el 13-nov-2026; prueba en seco T01..T14 OK)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-23 · RF-19 "Gestión de clientes y segmentos" (ajustado por CM-03)
--            RNF-09 (auditoría) · Ley 21.719 (acceso solo con permiso)
-- Requiere:  01, 01b, 02, 03, 04, 05, 06, 07, 08, 09, 10 y 11 aplicadas.
-- Aplicar:   junto con la versión del panel que trae la sección "Clientes".
-- Reversa:   20261112_14_clientes_reversa.sql
-- Prueba:    20261112_14_prueba_en_seco.sql (14 + prueba; T01..T14)
--
-- Qué hace:
--   1. clientes_resumen(): lista de clientes con contacto, comuna, n° de pedidos pagados,
--      total gastado, último pedido y puntos. Requiere clientes.ver. El correo se lee de
--      Auth en el servidor (el navegador no tiene acceso a auth.users).
--      Entran las cuentas registradas y los invitados que hicieron al menos un pedido.
--   2. cliente_detalle(id): ficha con direcciones, últimos pedidos, movimientos de puntos,
--      código "Trae un amigo" y los últimos cambios hechos por el negocio.
--   3. editar_cliente(id, datos): nombre, apellido, celular, datos de empresa (RUT validado
--      con módulo 11, razón social, giro) y Bloquear/Activar. Requiere clientes.gestionar.
--      Un cliente bloqueado no puede comprar (crear_pedido ya revisa perfiles.activo).
--      Cada cambio queda en cambios_cliente (quién, cuándo, valor anterior y nuevo).
--
-- Ajustes al RF-19 (CM-03):
--   - "Eliminar" se reemplaza por "Bloquear": los pedidos se conservan por obligación
--     tributaria (SII) y la base no permite borrar un perfil con pedidos. Una solicitud de
--     supresión (Ley 21.719) se atenderá con una anonimización (mejora posterior).
--   - "Crear cliente" queda fuera: la cuenta la crea el propio cliente al comprar o
--     registrarse (crearla desde el panel exige la clave de servicio en una Edge Function).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Auditoría de los cambios que el negocio hace a un cliente
-- ---------------------------------------------------------------------
create table if not exists public.cambios_cliente (
  id           uuid primary key default gen_random_uuid(),
  perfil_id    uuid not null references public.perfiles(id) on delete cascade,
  cambiado_por uuid references public.perfiles(id) on delete set null,
  antes        jsonb not null,
  despues      jsonb not null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_cambios_cliente_perfil on public.cambios_cliente (perfil_id, created_at desc);
alter table public.cambios_cliente enable row level security;
drop policy if exists cambios_cliente_ver on public.cambios_cliente;
create policy cambios_cliente_ver on public.cambios_cliente for select to authenticated
  using (public.tiene_permiso('clientes.ver'));
-- Sin políticas de escritura: solo editar_cliente() (security definer) inserta.

-- ---------------------------------------------------------------------
-- 2. Lista de clientes (sección Clientes del panel)
-- ---------------------------------------------------------------------
create or replace function public.clientes_resumen()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.tiene_permiso('clientes.ver') then
    raise exception 'No tienes permiso para ver los clientes.' using errcode = '42501';
  end if;

  return coalesce((
    with pagados as (            -- solo pedidos pagados (no pendientes ni cancelados)
      select p.perfil_id, count(*)::int as pedidos, sum(p.total)::bigint as gastado,
             max(p.created_at) as ultimo, min(p.created_at) as primero
        from public.pedidos p
       where p.estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado')
       group by p.perfil_id
    ), ultimo as (               -- contacto y comuna del pedido más reciente (cualquier estado)
      select distinct on (p.perfil_id) p.perfil_id, p.contacto_nombre, p.contacto_telefono,
             p.contacto_email, d.comuna
        from public.pedidos p
        left join public.direcciones d on d.id = p.direccion_id
       order by p.perfil_id, p.created_at desc
    )
    select jsonb_agg(jsonb_build_object(
             'id',            pf.id,
             'nombre',        case when coalesce(au.is_anonymous, false)
                                   then coalesce(nullif(trim(u.contacto_nombre), ''), 'Invitado')
                                   else trim(concat_ws(' ', pf.nombre, pf.apellido)) end,
             'email',         case when coalesce(au.is_anonymous, false) then u.contacto_email
                                   else coalesce(au.email, u.contacto_email) end,
             'telefono',      coalesce(public.normalizar_telefono_cl(pf.telefono), u.contacto_telefono),
             'comuna',        coalesce(u.comuna, (select d.comuna from public.direcciones d
                                                   where d.perfil_id = pf.id
                                                   order by d.es_principal desc, d.created_at desc limit 1)),
             'invitado',      coalesce(au.is_anonymous, false),
             'empresa',       pf.es_empresa,
             'rol',           pf.rol,
             'activo',        pf.activo,
             'puntos',        pf.puntos_saldo,
             'pedidos',       coalesce(pg.pedidos, 0),
             'gastado',       coalesce(pg.gastado, 0),
             'ultimo_pedido', pg.ultimo,
             'primer_pedido', pg.primero,
             'creado',        pf.created_at)
           order by pg.ultimo desc nulls last, pf.created_at desc)
      from public.perfiles pf
      join auth.users au on au.id = pf.id
      left join pagados pg on pg.perfil_id = pf.id
      left join ultimo  u  on u.perfil_id  = pf.id
     where not coalesce(au.is_anonymous, false)   -- cuentas registradas
        or u.perfil_id is not null                -- invitados con al menos un pedido
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Ficha de un cliente
-- ---------------------------------------------------------------------
create or replace function public.cliente_detalle(p_perfil uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.tiene_permiso('clientes.ver') then
    raise exception 'No tienes permiso para ver los clientes.' using errcode = '42501';
  end if;

  select jsonb_build_object(
           'id', pf.id, 'nombre', pf.nombre, 'apellido', pf.apellido,
           'email', case when coalesce(au.is_anonymous, false) then null else au.email end,
           'telefono', public.normalizar_telefono_cl(pf.telefono), 'telefono_raw', pf.telefono,
           'rut', pf.rut, 'razon_social', pf.razon_social, 'giro', pf.giro,
           'empresa', pf.es_empresa, 'activo', pf.activo, 'rol', pf.rol,
           'invitado', coalesce(au.is_anonymous, false), 'puntos', pf.puntos_saldo, 'creado', pf.created_at)
    into v
    from public.perfiles pf join auth.users au on au.id = pf.id
   where pf.id = p_perfil;
  if v is null then raise exception 'El cliente no existe.'; end if;

  return v || jsonb_build_object(
    'resumen', (select jsonb_build_object('pedidos', count(*), 'gastado', coalesce(sum(p.total), 0),
                                          'ultimo_pedido', max(p.created_at), 'primer_pedido', min(p.created_at))
                  from public.pedidos p
                 where p.perfil_id = p_perfil and p.estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado')),
    'contacto', (select jsonb_build_object('nombre', p.contacto_nombre, 'telefono', p.contacto_telefono, 'email', p.contacto_email)
                   from public.pedidos p where p.perfil_id = p_perfil order by p.created_at desc limit 1),
    'direcciones', (select coalesce(jsonb_agg(jsonb_build_object('calle', d.calle, 'numero', d.numero, 'depto', d.depto,
                                                                 'comuna', d.comuna, 'referencia', d.referencia,
                                                                 'principal', d.es_principal)
                                          order by d.es_principal desc, d.created_at desc), '[]'::jsonb)
                      from (select * from public.direcciones where perfil_id = p_perfil
                             order by es_principal desc, created_at desc limit 5) d),
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'numero', p.numero, 'estado', p.estado,
                                                             'total', p.total, 'created_at', p.created_at,
                                                             'fecha_entrega', p.fecha_entrega)
                                      order by p.created_at desc), '[]'::jsonb)
                  from (select * from public.pedidos where perfil_id = p_perfil
                         order by created_at desc limit 20) p),
    'movimientos', (select coalesce(jsonb_agg(jsonb_build_object('tipo', m.tipo, 'puntos', m.puntos,
                                                                 'descripcion', m.descripcion, 'created_at', m.created_at)
                                          order by m.created_at desc), '[]'::jsonb)
                      from (select * from public.movimientos_puntos where perfil_id = p_perfil
                             order by created_at desc limit 15) m),
    'codigo_referido', (select c.codigo from public.codigos_referido c where c.perfil_id = p_perfil),
    'referidos', (select count(*) from public.referidos r where r.referente_id = p_perfil),
    'cambios', (select coalesce(jsonb_agg(jsonb_build_object('antes', c.antes, 'despues', c.despues,
                                                             'por', c.por, 'created_at', c.created_at)
                                      order by c.created_at desc), '[]'::jsonb)
                  from (select cc.*, pf.nombre as por from public.cambios_cliente cc
                          left join public.perfiles pf on pf.id = cc.cambiado_por
                         where cc.perfil_id = p_perfil order by cc.created_at desc limit 10) c)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Editar un cliente (datos, empresa y Bloquear/Activar), con auditoría
--    p_datos = {"nombre","apellido","telefono","es_empresa","rut","razon_social","giro","activo"}
--    Solo se cambian las claves enviadas.
-- ---------------------------------------------------------------------
create or replace function public.editar_cliente(p_perfil uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_yo uuid := auth.uid();
  o public.perfiles%rowtype;
  v_nombre text; v_apellido text; v_tel text; v_emp boolean;
  v_rut text; v_razon text; v_giro text; v_activo boolean;
  v_antes jsonb; v_despues jsonb; v_a jsonb; v_d jsonb;
begin
  if not public.tiene_permiso('clientes.gestionar') then
    raise exception 'No tienes permiso para editar clientes.' using errcode = '42501';
  end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then raise exception 'Datos no válidos.'; end if;

  select * into o from public.perfiles where id = p_perfil for update;
  if not found then raise exception 'El cliente no existe.'; end if;
  if coalesce((select is_anonymous from auth.users where id = p_perfil), true) then
    raise exception 'Los invitados no tienen cuenta: sus datos vienen de cada pedido.';
  end if;

  -- Nombre y apellido
  v_nombre := case when p_datos ? 'nombre' then left(trim(coalesce(p_datos->>'nombre', '')), 80) else o.nombre end;
  if length(coalesce(v_nombre, '')) < 2 then raise exception 'El nombre debe tener al menos 2 letras.'; end if;
  v_apellido := case when p_datos ? 'apellido' then nullif(left(trim(coalesce(p_datos->>'apellido', '')), 80), '') else o.apellido end;

  -- Celular (se guarda como 569XXXXXXXX; vacío = sin celular)
  if p_datos ? 'telefono' then
    if nullif(trim(coalesce(p_datos->>'telefono', '')), '') is null then v_tel := null;
    else
      v_tel := public.normalizar_telefono_cl(p_datos->>'telefono');
      if v_tel is null then raise exception 'El celular no es válido (ej.: 9 1234 5678).'; end if;
    end if;
  else v_tel := o.telefono; end if;

  -- Empresa: RUT (formato 12345678-K, módulo 11), razón social y giro
  if p_datos ? 'rut' then
    v_rut := nullif(upper(regexp_replace(coalesce(p_datos->>'rut', ''), '[^0-9kK]', '', 'g')), '');
    if v_rut is not null then
      if not public.es_rut_valido(v_rut) then raise exception 'El RUT no es válido.'; end if;
      v_rut := left(v_rut, length(v_rut) - 1) || '-' || right(v_rut, 1);
    end if;
  else v_rut := o.rut; end if;
  v_razon := case when p_datos ? 'razon_social' then nullif(left(trim(coalesce(p_datos->>'razon_social', '')), 120), '') else o.razon_social end;
  v_giro  := case when p_datos ? 'giro'         then nullif(left(trim(coalesce(p_datos->>'giro', '')), 120), '')         else o.giro end;
  begin
    v_emp    := case when p_datos ? 'es_empresa' then (p_datos->>'es_empresa')::boolean else o.es_empresa end;
    v_activo := case when p_datos ? 'activo'     then (p_datos->>'activo')::boolean     else o.activo end;
  exception when others then raise exception 'Datos no válidos.';
  end;
  v_emp := coalesce(v_emp, false); v_activo := coalesce(v_activo, true);
  if v_emp and (v_rut is null or v_razon is null or v_giro is null) then
    raise exception 'Para marcarlo como empresa completa RUT, razón social y giro.';
  end if;
  if v_rut is not null and exists (select 1 from public.perfiles where rut = v_rut and id <> p_perfil) then
    raise exception 'Ese RUT ya está registrado en otro cliente.';
  end if;

  -- Bloquear: nunca a uno mismo ni a alguien del equipo (eso se gestiona en Equipo y roles)
  if o.activo and not v_activo then
    if p_perfil = v_yo then raise exception 'No puedes bloquear tu propia cuenta.'; end if;
    if o.rol <> 'cliente' then
      raise exception 'Esta persona es parte del equipo: primero cámbiale el rol a Cliente en "Equipo y roles".';
    end if;
  end if;

  v_antes   := jsonb_build_object('nombre', o.nombre, 'apellido', o.apellido, 'telefono', o.telefono,
                                  'es_empresa', o.es_empresa, 'rut', o.rut, 'razon_social', o.razon_social,
                                  'giro', o.giro, 'activo', o.activo);
  v_despues := jsonb_build_object('nombre', v_nombre, 'apellido', v_apellido, 'telefono', v_tel,
                                  'es_empresa', v_emp, 'rut', v_rut, 'razon_social', v_razon,
                                  'giro', v_giro, 'activo', v_activo);
  select jsonb_object_agg(d.key, v_antes -> d.key), jsonb_object_agg(d.key, d.value)
    into v_a, v_d
    from jsonb_each(v_despues) d
   where d.value is distinct from (v_antes -> d.key);
  if v_d is null then return jsonb_build_object('ok', true, 'sin_cambios', true); end if;

  update public.perfiles
     set nombre = v_nombre, apellido = v_apellido, telefono = v_tel, es_empresa = v_emp,
         rut = v_rut, razon_social = v_razon, giro = v_giro, activo = v_activo
   where id = p_perfil;
  insert into public.cambios_cliente (perfil_id, cambiado_por, antes, despues) values (p_perfil, v_yo, v_a, v_d);
  return jsonb_build_object('ok', true, 'cambios', v_d);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Permisos de ejecución
-- ---------------------------------------------------------------------
revoke execute on function public.clientes_resumen()             from public, anon;
revoke execute on function public.cliente_detalle(uuid)          from public, anon;
revoke execute on function public.editar_cliente(uuid, jsonb)    from public, anon;
grant  execute on function public.clientes_resumen()             to authenticated;
grant  execute on function public.cliente_detalle(uuid)          to authenticated;
grant  execute on function public.editar_cliente(uuid, jsonb)    to authenticated;

-- ---------------------------------------------------------------------
-- 6. Registro en el historial de migraciones de Supabase (si existe)
-- ---------------------------------------------------------------------
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261112000014', '14_clientes') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
