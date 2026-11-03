-- PRUEBA EN SECO de las migraciones 01 + 02 + 03 (Befine Store)
-- Pegar completo en Supabase > SQL Editor > Run.
-- Termina SIEMPRE con un error intencional: todo se deshace. El texto del error
-- muestra los resultados T01..T37. Busca la palabra FALLA: no debería aparecer.

do $do$ declare u1 uuid; u2 uuid; u3 uuid; p1 uuid; p3 uuid; vr uuid; ct jsonb; j jsonb; t text; n int; res text := $r$RESULTADOS$r$; begin
create table public.roles (
  id          text primary key check (id ~ '^[a-z][a-z0-9_]{1,30}$'),
  nombre      text not null,
  descripcion text,
  es_sistema  boolean not null default false,   -- cliente/admin/chofer: no se borran ni renombran
  created_at  timestamptz not null default now()
);
create table public.permisos (
  codigo      text primary key,
  modulo      text not null,
  descripcion text not null
);
create table public.rol_permisos (
  rol_id  text not null references public.roles(id) on update cascade on delete cascade,
  permiso text not null references public.permisos(codigo) on delete cascade,
  primary key (rol_id, permiso)
);
insert into public.roles (id, nombre, descripcion, es_sistema) values
  ('cliente', 'Cliente',       'Compra en la tienda',                       true),
  ('admin',   'Administrador', 'Dueño: acceso total, gestiona roles',        true),
  ('chofer',  'Chofer',        'Ve los pedidos y datos de entrega',          true);
insert into public.permisos (codigo, modulo, descripcion) values
  ('pedidos.ver',           'Pedidos',     'Ver pedidos, su detalle y datos de entrega'),
  ('pedidos.gestionar',     'Pedidos',     'Crear, editar y cambiar el estado de pedidos'),
  ('catalogo.gestionar',    'Catálogo',    'Crear y editar categorías, productos y variantes'),
  ('precios.gestionar',     'Catálogo',    'Editar precios y niveles de precio'),
  ('promociones.gestionar', 'Promociones', 'Crear y editar cupones y recompensas'),
  ('despacho.gestionar',    'Despacho',    'Editar zonas y comunas de despacho'),
  ('clientes.ver',          'Clientes',    'Ver datos de clientes'),
  ('clientes.gestionar',    'Clientes',    'Editar clientes (nivel de precio, activo)'),
  ('pagos.gestionar',       'Pagos',       'Ver y gestionar pagos'),
  ('documentos.gestionar',  'Pagos',       'Gestionar boletas y facturas'),
  ('puntos.gestionar',      'Fidelización','Ajustar puntos de clientes'),
  ('config.gestionar',      'Sistema',     'Editar parámetros del sistema');
insert into public.rol_permisos (rol_id, permiso) values ('chofer', 'pedidos.ver');
alter table public.perfiles alter column rol drop default;
alter table public.perfiles alter column rol type text
  using (case rol::text when 'repartidor' then 'chofer' when 'operador' then 'chofer' else rol::text end);
alter table public.perfiles alter column rol set default 'cliente';
alter table public.perfiles add constraint perfiles_rol_fkey
  foreign key (rol) references public.roles(id) on update cascade;
drop type public.app_rol;
create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles
                  where id = auth.uid() and rol = 'admin' and activo);
$$;
create or replace function public.tiene_permiso(p_permiso text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.perfiles pf
     where pf.id = auth.uid() and pf.activo
       and (pf.rol = 'admin'
            or exists (select 1 from public.rol_permisos rp
                        where rp.rol_id = pf.rol and rp.permiso = p_permiso)));
$$;
alter table public.roles        enable row level security;
alter table public.permisos     enable row level security;
alter table public.rol_permisos enable row level security;
create policy roles_lectura on public.roles for select to authenticated using (true);
create policy roles_insert  on public.roles for insert to authenticated with check (public.es_admin() and not es_sistema);
create policy roles_update  on public.roles for update to authenticated
  using (public.es_admin() and not es_sistema) with check (public.es_admin() and not es_sistema);
create policy roles_delete  on public.roles for delete to authenticated using (public.es_admin() and not es_sistema);
create policy permisos_lectura on public.permisos for select to authenticated using (true);
create policy rol_permisos_lectura on public.rol_permisos for select to authenticated using (true);
create policy rol_permisos_insert  on public.rol_permisos for insert to authenticated
  with check (public.es_admin() and rol_id not in ('admin', 'cliente'));
create policy rol_permisos_delete  on public.rol_permisos for delete to authenticated
  using (public.es_admin() and rol_id not in ('admin', 'cliente'));
alter policy categorias_admin     on public.categorias          using (public.tiene_permiso('catalogo.gestionar'))    with check (public.tiene_permiso('catalogo.gestionar'));
alter policy productos_admin      on public.productos           using (public.tiene_permiso('catalogo.gestionar'))    with check (public.tiene_permiso('catalogo.gestionar'));
alter policy variantes_admin      on public.variantes_producto  using (public.tiene_permiso('catalogo.gestionar'))    with check (public.tiene_permiso('catalogo.gestionar'));
alter policy precios_var_admin    on public.precios_variante    using (public.tiene_permiso('precios.gestionar'))     with check (public.tiene_permiso('precios.gestionar'));
alter policy niveles_admin        on public.niveles_precio      using (public.tiene_permiso('precios.gestionar'))     with check (public.tiene_permiso('precios.gestionar'));
alter policy cupones_admin        on public.cupones             using (public.tiene_permiso('promociones.gestionar')) with check (public.tiene_permiso('promociones.gestionar'));
alter policy cupon_var_admin      on public.cupon_variantes     using (public.tiene_permiso('promociones.gestionar')) with check (public.tiene_permiso('promociones.gestionar'));
alter policy recompensas_admin    on public.recompensas         using (public.tiene_permiso('promociones.gestionar')) with check (public.tiene_permiso('promociones.gestionar'));
alter policy zonas_admin          on public.zonas_despacho      using (public.tiene_permiso('despacho.gestionar'))    with check (public.tiene_permiso('despacho.gestionar'));
alter policy comunas_admin        on public.comunas_cobertura   using (public.tiene_permiso('despacho.gestionar'))    with check (public.tiene_permiso('despacho.gestionar'));
alter policy parametros_admin     on public.parametros          using (public.tiene_permiso('config.gestionar'))      with check (public.tiene_permiso('config.gestionar'));
alter policy pedidos_admin        on public.pedidos             using (public.tiene_permiso('pedidos.gestionar'))     with check (public.tiene_permiso('pedidos.gestionar'));
alter policy detalle_admin        on public.detalle_pedido      using (public.tiene_permiso('pedidos.gestionar'))     with check (public.tiene_permiso('pedidos.gestionar'));
alter policy historial_admin      on public.historial_pedido    using (public.tiene_permiso('pedidos.gestionar'))     with check (public.tiene_permiso('pedidos.gestionar'));
alter policy pagos_admin          on public.pagos               using (public.tiene_permiso('pagos.gestionar'))       with check (public.tiene_permiso('pagos.gestionar'));
alter policy dte_admin            on public.documentos_tributarios using (public.tiene_permiso('documentos.gestionar')) with check (public.tiene_permiso('documentos.gestionar'));
alter policy mov_puntos_admin     on public.movimientos_puntos  using (public.tiene_permiso('puntos.gestionar'))      with check (public.tiene_permiso('puntos.gestionar'));
alter policy productos_lectura   on public.productos          using ((activo = true) or public.tiene_permiso('catalogo.gestionar'));
alter policy variantes_lectura   on public.variantes_producto using ((activo = true) or public.tiene_permiso('catalogo.gestionar'));
alter policy recompensas_lectura on public.recompensas        using ((activo = true) or public.tiene_permiso('promociones.gestionar'));
alter policy cupones_lectura on public.cupones
  using (((activo = true) and (perfil_id is null)) or ((activo = true) and (perfil_id = auth.uid())) or public.tiene_permiso('promociones.gestionar'));
alter policy pedidos_select   on public.pedidos          using ((perfil_id = auth.uid()) or public.tiene_permiso('pedidos.ver'));
alter policy detalle_select   on public.detalle_pedido   using (exists (select 1 from public.pedidos p where p.id = detalle_pedido.pedido_id   and ((p.perfil_id = auth.uid()) or public.tiene_permiso('pedidos.ver'))));
alter policy historial_select on public.historial_pedido using (exists (select 1 from public.pedidos p where p.id = historial_pedido.pedido_id and ((p.perfil_id = auth.uid()) or public.tiene_permiso('pedidos.ver'))));
alter policy pagos_select     on public.pagos            using (exists (select 1 from public.pedidos p where p.id = pagos.pedido_id            and ((p.perfil_id = auth.uid()) or public.tiene_permiso('pagos.gestionar'))));
alter policy dte_select       on public.documentos_tributarios using (exists (select 1 from public.pedidos p where p.id = documentos_tributarios.pedido_id and ((p.perfil_id = auth.uid()) or public.tiene_permiso('documentos.gestionar'))));
alter policy mov_puntos_select on public.movimientos_puntos using ((perfil_id = auth.uid()) or public.tiene_permiso('puntos.gestionar'));
create policy direcciones_reparto on public.direcciones for select to authenticated
  using (public.tiene_permiso('pedidos.ver')
         and exists (select 1 from public.pedidos p where p.direccion_id = direcciones.id));
alter policy perfiles_select on public.perfiles
  using ((id = auth.uid()) or public.tiene_permiso('clientes.ver'));
create policy perfiles_staff_update on public.perfiles for update to authenticated
  using (public.tiene_permiso('clientes.gestionar')) with check (public.tiene_permiso('clientes.gestionar'));
drop policy pedidos_insert on public.pedidos;
drop policy detalle_insert on public.detalle_pedido;
create or replace function public.proteger_campos_perfil()
returns trigger language plpgsql security invoker set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;                                   -- cambio interno del servidor
  end if;
  if not public.es_admin() then
    new.rol := old.rol;                           -- roles: solo admin
    if not public.tiene_permiso('clientes.gestionar') then
      new.nivel_precio_id := old.nivel_precio_id;
      new.activo          := old.activo;
    end if;
    new.puntos_saldo := old.puntos_saldo;         -- puntos: solo vía movimientos_puntos
  end if;
  return new;
end;
$$;
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (id, nombre, telefono)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'nombre'), ''),
                  nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
                  nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
                  'Invitado'), 80),
    left(nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'telefono', ''), '[^0-9+]', '', 'g'), ''), 20)
  );
  return new;
end;
$$;
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end;
$$;
drop function public.precio_efectivo(uuid, uuid);
create function public.precio_efectivo(p_variante uuid)
returns integer language sql stable security invoker set search_path = public as $$
  select pv.precio
    from public.precios_variante pv
   where pv.variante_id = p_variante
     and pv.nivel_precio_id = coalesce((select nivel_precio_id from public.perfiles where id = auth.uid()), 1);
$$;
alter table public.pedidos
  add column contacto_nombre   text,
  add column contacto_telefono text,          -- formato 569XXXXXXXX (para WhatsApp)
  add column contacto_email    text,
  add column fecha_entrega     date,
  add column tipo_documento    public.tipo_dte not null default 'boleta',
  add column doc_rut           text,
  add column doc_razon_social  text,
  add column doc_giro          text;
create or replace function public.normalizar_telefono_cl(p text)
returns text language sql immutable set search_path = '' as $$
  select case
           when d ~ '^569[0-9]{8}$' then d
           when d ~ '^9[0-9]{8}$'   then '56' || d
           when d ~ '^[0-9]{8}$'    then '569' || d
           else null
         end
    from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x;
$$;
create or replace function public.es_rut_valido(p_rut text)
returns boolean language plpgsql immutable set search_path = '' as $$
declare
  r        text := upper(regexp_replace(coalesce(p_rut, ''), '[^0-9kK]', '', 'g'));
  cuerpo   text;
  suma     int := 0;
  mult     int := 2;
  resto    int;
  i        int;
begin
  if length(r) < 2 then return false; end if;
  cuerpo := left(r, length(r) - 1);
  if cuerpo !~ '^[0-9]+$' then return false; end if;
  for i in reverse length(cuerpo)..1 loop
    suma := suma + substr(cuerpo, i, 1)::int * mult;
    mult := case when mult = 7 then 2 else mult + 1 end;
  end loop;
  resto := 11 - (suma % 11);
  return right(r, 1) = case resto when 11 then '0' when 10 then 'K' else resto::text end;
end;
$$;
create or replace function public.crear_pedido(
  p_items        jsonb,
  p_direccion    jsonb,
  p_contacto     jsonb,
  p_entrega      jsonb default null,
  p_documento    jsonb default null,
  p_cupon_codigo text  default null,
  p_notas        text  default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid        uuid := auth.uid();
  v_hoy        date := (now() at time zone 'America/Santiago')::date;
  v_perfil     public.perfiles%rowtype;
  v_zona       public.zonas_despacho%rowtype;
  v_comuna     text;
  v_dir_id     uuid;
  v_nombre     text;
  v_tel        text;
  v_email      text;
  v_fecha      date;
  v_tipo_doc   public.tipo_dte := 'boleta';
  v_rut        text;
  v_razon      text;
  v_giro       text;
  v_pedido_id  uuid;
  v_numero     bigint;
  v_subtotal   integer := 0;
  v_despacho   integer;
  v_gratis     integer;
  v_cupon      public.cupones%rowtype;
  v_base       integer;
  v_desc       integer := 0;
  v_total      integer;
  v_clp_punto  integer;
  v_puntos     integer := 0;
  r            record;
  v            record;
begin
  if v_uid is null then
    raise exception 'Debes iniciar sesión o continuar como invitado para comprar.' using errcode = '28000';
  end if;
  select * into v_perfil from public.perfiles where id = v_uid;
  if not found or not v_perfil.activo then
    raise exception 'Tu cuenta no está habilitada para comprar.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El carrito está vacío.';
  end if;
  if jsonb_array_length(p_items) > 50 then
    raise exception 'Demasiados productos en un solo pedido.';
  end if;
  v_nombre := left(nullif(trim(p_contacto->>'nombre'), ''), 80);
  v_tel    := public.normalizar_telefono_cl(p_contacto->>'telefono');
  v_email  := lower(left(nullif(trim(p_contacto->>'email'), ''), 120));
  if v_nombre is null then raise exception 'Ingresa tu nombre.'; end if;
  if v_tel is null then raise exception 'Ingresa un celular válido (ej: 9 1234 5678).'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Ingresa un correo válido.';
  end if;
  if nullif(p_entrega->>'fecha', '') is not null then
    begin
      v_fecha := (p_entrega->>'fecha')::date;
    exception when others then
      raise exception 'La fecha de entrega no es válida.';
    end;
    if v_fecha <= v_hoy or v_fecha > v_hoy + 45 or extract(isodow from v_fecha) > 5 then
      raise exception 'La fecha de entrega debe ser un día hábil a partir de mañana.';
    end if;
  else
    v_fecha := v_hoy + 1;
    while extract(isodow from v_fecha) > 5 loop v_fecha := v_fecha + 1; end loop;
  end if;
  if lower(coalesce(p_documento->>'tipo', 'boleta')) = 'factura' then
    v_tipo_doc := 'factura';
    v_rut   := upper(regexp_replace(coalesce(p_documento->>'rut', ''), '[^0-9kK]', '', 'g'));
    v_razon := left(nullif(trim(p_documento->>'razon_social'), ''), 120);
    v_giro  := left(nullif(trim(p_documento->>'giro'), ''), 120);
    if not public.es_rut_valido(v_rut) then raise exception 'El RUT para la factura no es válido.'; end if;
    if v_razon is null or v_giro is null then raise exception 'Para factura indica razón social y giro.'; end if;
    v_rut := left(v_rut, length(v_rut) - 1) || '-' || right(v_rut, 1);
  end if;
  select c.comuna into v_comuna
    from public.comunas_cobertura c
    join public.zonas_despacho z on z.id = c.zona_id
   where lower(c.comuna) = lower(trim(p_direccion->>'comuna')) and c.activo and z.activo;
  if v_comuna is null then
    raise exception 'No tenemos despacho a la comuna indicada.';
  end if;
  select z.* into v_zona
    from public.comunas_cobertura c
    join public.zonas_despacho z on z.id = c.zona_id
   where c.comuna = v_comuna;
  if coalesce(trim(p_direccion->>'calle'), '') = '' or coalesce(trim(p_direccion->>'numero'), '') = '' then
    raise exception 'Falta la calle o el número de la dirección.';
  end if;
  select id into v_dir_id from public.direcciones
   where perfil_id = v_uid
     and lower(calle) = lower(trim(p_direccion->>'calle'))
     and numero = trim(p_direccion->>'numero')
     and coalesce(depto, '') = coalesce(nullif(trim(p_direccion->>'depto'), ''), '')
     and comuna = v_comuna
   limit 1;
  if v_dir_id is null then
    insert into public.direcciones (perfil_id, zona_id, calle, numero, depto, comuna, referencia)
    values (v_uid, v_zona.id,
            left(trim(p_direccion->>'calle'), 120),
            left(trim(p_direccion->>'numero'), 20),
            left(nullif(trim(p_direccion->>'depto'), ''), 40),
            v_comuna,
            left(nullif(trim(p_direccion->>'referencia'), ''), 200))
    returning id into v_dir_id;
  end if;
  update public.perfiles
     set telefono = coalesce(telefono, v_tel),
         nombre   = case when nombre = 'Invitado' then v_nombre else nombre end
   where id = v_uid;
  insert into public.pedidos (perfil_id, direccion_id, zona_id, nivel_precio_id, notas,
                              contacto_nombre, contacto_telefono, contacto_email, fecha_entrega,
                              tipo_documento, doc_rut, doc_razon_social, doc_giro)
  values (v_uid, v_dir_id, v_zona.id, v_perfil.nivel_precio_id, left(nullif(trim(p_notas), ''), 500),
          v_nombre, v_tel, v_email, v_fecha,
          v_tipo_doc, v_rut, v_razon, v_giro)
  returning id, numero into v_pedido_id, v_numero;
  for r in
    select (e->>'variante_id')::uuid as variante_id, sum((e->>'cantidad')::int) as cantidad
      from jsonb_array_elements(p_items) e
     group by 1
  loop
    if r.cantidad is null or r.cantidad < 1 or r.cantidad > 200 then
      raise exception 'Cantidad inválida en el carrito.';
    end if;
    select vp.id, vp.nombre, vp.stock, vp.controla_stock, pv.precio into v
      from public.variantes_producto vp
      join public.productos p on p.id = vp.producto_id
      left join public.precios_variante pv
             on pv.variante_id = vp.id and pv.nivel_precio_id = v_perfil.nivel_precio_id
     where vp.id = r.variante_id and vp.activo and p.activo
       for update of vp;
    if not found then
      raise exception 'Un producto del carrito ya no está disponible.';
    end if;
    if v.precio is null then
      raise exception 'El producto % no tiene precio configurado.', v.nombre;
    end if;
    if v.controla_stock and v.stock < r.cantidad then
      raise exception 'No hay stock suficiente de %.', v.nombre;
    end if;
    insert into public.detalle_pedido (pedido_id, variante_id, cantidad, precio_unitario, subtotal)
    values (v_pedido_id, v.id, r.cantidad, v.precio, v.precio * r.cantidad);
    v_subtotal := v_subtotal + v.precio * r.cantidad;
  end loop;
  if nullif(trim(p_cupon_codigo), '') is not null then
    select * into v_cupon from public.cupones
     where upper(codigo) = upper(trim(p_cupon_codigo))
       and activo
       and (perfil_id is null or perfil_id = v_uid)
       and (vigente_desde is null or vigente_desde <= v_hoy)
       and (vigente_hasta is null or vigente_hasta >= v_hoy)
       for update;
    if not found then
      raise exception 'El cupón no es válido o ya venció.';
    end if;
    if v_cupon.usos_maximos is not null and v_cupon.usos_actuales >= v_cupon.usos_maximos then
      raise exception 'El cupón ya alcanzó su límite de usos.';
    end if;
    if v_subtotal < v_cupon.compra_minima then
      raise exception 'El cupón requiere una compra mínima de $%.', v_cupon.compra_minima;
    end if;
    if exists (select 1 from public.cupon_variantes where cupon_id = v_cupon.id) then
      select coalesce(sum(d.subtotal), 0) into v_base
        from public.detalle_pedido d
        join public.cupon_variantes cv on cv.variante_id = d.variante_id and cv.cupon_id = v_cupon.id
       where d.pedido_id = v_pedido_id;
    else
      v_base := v_subtotal;
    end if;
    v_desc := case v_cupon.tipo
                when 'porcentaje' then round(v_base * least(v_cupon.valor, 100) / 100.0)::int
                else least(v_cupon.valor, v_base)
              end;
    update public.cupones set usos_actuales = usos_actuales + 1 where id = v_cupon.id;
  end if;
  v_despacho := v_zona.costo_despacho;
  select nullif(valor, '')::int into v_gratis from public.parametros where clave = 'envio_gratis_minimo';
  if v_despacho > 0 and v_gratis is not null and v_subtotal >= v_gratis then
    v_despacho := 0;
  end if;
  v_total := greatest(v_subtotal - v_desc, 0) + v_despacho;
  select nullif(valor, '')::int into v_clp_punto from public.parametros where clave = 'clp_por_punto';
  if coalesce(v_clp_punto, 0) > 0 then
    v_puntos := greatest(v_subtotal - v_desc, 0) / v_clp_punto;
  end if;
  update public.pedidos
     set subtotal        = v_subtotal,
         costo_despacho  = v_despacho,
         descuento_cupon = v_desc,
         cupon_id        = v_cupon.id,
         total           = v_total,
         puntos_ganados  = v_puntos
   where id = v_pedido_id;
  return jsonb_build_object(
    'id', v_pedido_id, 'numero', v_numero, 'estado', 'pendiente_pago',
    'subtotal', v_subtotal, 'costo_despacho', v_despacho,
    'descuento_cupon', v_desc, 'total', v_total,
    'puntos_ganados', v_puntos, 'fecha_entrega', v_fecha);
end;
$$;
revoke execute on function public.handle_new_user()                 from public, anon, authenticated;
revoke execute on function public.proteger_campos_perfil()          from public, anon, authenticated;
revoke execute on function public.aplicar_movimiento_puntos()       from public, anon, authenticated;
revoke execute on function public.registrar_cambio_estado_pedido()  from public, anon, authenticated;
revoke execute on function public.set_updated_at()                  from public, anon, authenticated;
revoke execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) to authenticated;
grant execute on function public.es_admin()                    to anon, authenticated;
grant execute on function public.tiene_permiso(text)           to anon, authenticated;
grant execute on function public.precio_efectivo(uuid)         to anon, authenticated;
grant execute on function public.normalizar_telefono_cl(text)  to anon, authenticated;
grant execute on function public.es_rut_valido(text)           to anon, authenticated;
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
  update public.pedidos set estado = p_estado where id = p_pedido;
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
  update public.pedidos set estado = 'pagado'         where id = p_pedido;
  update public.pedidos set estado = 'en_preparacion' where id = p_pedido;
  update public.historial_pedido
     set nota = case estado_nuevo when 'pagado' then 'Pago confirmado por Mercado Pago (' || p_mp_payment_id || ')'
                                  else 'Automático al confirmar el pago' end
   where pedido_id = p_pedido and estado_nuevo in ('pagado', 'en_preparacion') and nota is null;
  update public.variantes_producto vp
     set stock = greatest(vp.stock - d.cantidad, 0)
    from public.detalle_pedido d
   where d.pedido_id = p_pedido and vp.id = d.variante_id and vp.controla_stock;
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
revoke execute on function public.confirmar_pago(uuid, text, integer, jsonb, text) from public, anon, authenticated;
grant  execute on function public.confirmar_pago(uuid, text, integer, jsonb, text) to service_role;
  vr := '026259d7-1a7a-4529-9369-609f6a8e573b';
  u1 := '28b0e13c-ef07-4762-88b3-f5fba63fbc8b';
  u2 := gen_random_uuid(); u3 := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data) values (u2, 'chofer.prueba@ejemplo.cl', '{"nombre":"Chofer Prueba","telefono":"+56 9 1234 5678"}');
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values (u3, null, '{}', true);
  select nombre||' tel='||coalesce(telefono,'-') into t from perfiles where id=u2; res := res || chr(10) || 'T01 registro guarda telefono: ' || coalesce(t,'NULL');
  select nombre into t from perfiles where id=u3; res := res || chr(10) || 'T02 invitado anonimo: ' || coalesce(t,'NULL');
  update perfiles set rol='chofer' where id=u2;
  insert into cupones (codigo, tipo, valor, perfil_id) values ('PERS10','monto_fijo',1000,u1);
  select stock into n from variantes_producto where id=vr; res := res || chr(10) || 'stock inicial=' || coalesce(n::text,'NULL');
  ct := '{"nombre":"Camila Fuentes","telefono":"9 8765 4321","email":"camila@ejemplo.cl"}';
  perform set_config('request.jwt.claims', json_build_object('sub',u1,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',2), jsonb_build_object('variante_id',vr,'cantidad',1)),
                    '{"calle":"Av. Prueba","numero":"123","comuna":"huechuraba"}', ct, null, null, 'legacy2000', 'nota');
  p1 := (j->>'id')::uuid;
  res := res || chr(10) || 'T03 pedido con cupon general 20%: ' || coalesce(j::text,'NULL');
  j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',1)), '{"calle":"Av. Prueba","numero":"123","comuna":"Huechuraba"}', ct,
                    '{"tipo":"agendada","fecha":"2026-10-14"}', '{"tipo":"factura","rut":"11.111.111-1","razon_social":"Empresa SpA","giro":"Comercio"}', 'PERS10');
  res := res || chr(10) || 'T04 cupon personal propio + factura + fecha agendada: ' || coalesce(j::text,'NULL');
  begin j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',1)), '{"calle":"A","numero":"1","comuna":"Quilicura"}', ct, null, '{"tipo":"factura","rut":"11.111.111-2","razon_social":"X","giro":"Y"}');
    res := res || chr(10) || 'T05 FALLA rut invalido aceptado';
  exception when others then res := res || chr(10) || 'T05 rut invalido: ' || sqlerrm; end;
  begin j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',1)), '{"calle":"A","numero":"1","comuna":"Quilicura"}', ct, '{"fecha":"2026-10-10"}');
    res := res || chr(10) || 'T06 FALLA sabado aceptado';
  exception when others then res := res || chr(10) || 'T06 entrega sabado: ' || sqlerrm; end;
  begin j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',1)), '{"calle":"A","numero":"1","comuna":"Quilicura"}', '{"nombre":"X","telefono":"123","email":"x@y.cl"}');
    res := res || chr(10) || 'T07 FALLA telefono invalido';
  exception when others then res := res || chr(10) || 'T07 telefono invalido: ' || sqlerrm; end;
  begin j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',1)), '{"calle":"X","numero":"1","comuna":"Santiago"}', ct);
    res := res || chr(10) || 'T08 FALLA comuna sin cobertura';
  exception when others then res := res || chr(10) || 'T08 comuna sin cobertura: ' || sqlerrm; end;
  begin insert into pedidos (perfil_id, nivel_precio_id, total, estado) values (u1, 1, 1, 'pagado');
    res := res || chr(10) || 'T09 FALLA insert directo';
  exception when others then res := res || chr(10) || 'T09 insert directo pedido: ' || sqlerrm; end;
  begin insert into detalle_pedido (pedido_id, variante_id, cantidad, precio_unitario, subtotal) values (p1, vr, 5, 1, 5);
    res := res || chr(10) || 'T10 FALLA detalle directo';
  exception when others then res := res || chr(10) || 'T10 insert directo detalle: ' || sqlerrm; end;
  update pedidos set estado='pagado' where perfil_id=u1; get diagnostics n = row_count; res := res || chr(10) || 'T11 cliente marca pagado, filas=' || n;
  update perfiles set rol='admin', puntos_saldo=99999, nombre='Nombre editado' where id=u1;
  begin perform confirmar_pago(p1, 'x', 1);
    res := res || chr(10) || 'T12 FALLA cliente confirma pago';
  exception when others then res := res || chr(10) || 'T12 cliente llama confirmar_pago: ' || sqlerrm; end;
  begin perform marcar_reparto(p1, 'en_ruta');
    res := res || chr(10) || 'T13 FALLA cliente marca reparto';
  exception when others then res := res || chr(10) || 'T13 cliente llama marcar_reparto: ' || sqlerrm; end;
  perform set_config('role','none', true);
  select rol||' puntos='||puntos_saldo||' nombre='||nombre into t from perfiles where id=u1; res := res || chr(10) || 'T14 perfil tras intento de escalar: ' || coalesce(t,'NULL');
  select usos_actuales::text into t from cupones where codigo='LEGACY2000'; res := res || chr(10) || 'T15 usos LEGACY2000=' || coalesce(t,'NULL');
  perform set_config('request.jwt.claims', json_build_object('sub',u3,'role','authenticated','is_anonymous',true)::text, true);
  perform set_config('role','authenticated', true);
  j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',1)), '{"calle":"Los Aromos","numero":"55","comuna":"Quilicura"}',
                    '{"nombre":"Pedro Soto","telefono":"+56 9 5555 4444","email":"pedro@ejemplo.cl"}');
  p3 := (j->>'id')::uuid;
  res := res || chr(10) || 'T16 invitado compra: ' || coalesce(j::text,'NULL');
  begin j := crear_pedido(jsonb_build_array(jsonb_build_object('variante_id',vr,'cantidad',1)), '{"calle":"Y","numero":"2","comuna":"Quilicura"}', ct, null, null, 'PERS10');
    res := res || chr(10) || 'T17 FALLA cupon personal ajeno';
  exception when others then res := res || chr(10) || 'T17 cupon personal ajeno: ' || sqlerrm; end;
  perform set_config('role','none', true);
  select nombre||' tel='||coalesce(telefono,'-') into t from perfiles where id=u3; res := res || chr(10) || 'T18 perfil invitado tras compra: ' || coalesce(t,'NULL');
  update auth.users set is_anonymous=false, email='pedro@ejemplo.cl', raw_user_meta_data='{"nombre":"Pedro Soto R."}' where id=u3;
  select nombre into t from perfiles where id=u3; res := res || chr(10) || 'T19 invitado crea cuenta, nombre=' || coalesce(t,'NULL');
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role','anon', true);
  select count(*) into n from productos; res := res || chr(10) || 'T20 visitante ve productos=' || n;
  begin perform crear_pedido('[]','{}','{}'); res := res || chr(10) || 'T21 FALLA anon crea pedido';
  exception when others then res := res || chr(10) || 'T21 visitante crear_pedido: ' || sqlerrm; end;
  perform set_config('role','none', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('role','service_role', true);
  select total into n from pedidos where id=p1;
  j := confirmar_pago(p1, 'MP-1', n - 1); res := res || chr(10) || 'T22 pago monto incorrecto: ' || j::text;
  j := confirmar_pago(p1, 'MP-2', n);     res := res || chr(10) || 'T23 pago correcto: ' || j::text;
  j := confirmar_pago(p1, 'MP-2', n);     res := res || chr(10) || 'T24 webhook repetido: ' || j::text;
  select total into n from pedidos where id=p3;
  j := confirmar_pago(p3, 'MP-3', n);     res := res || chr(10) || 'T25 pago invitado: ' || j::text;
  perform set_config('role','none', true);
  select string_agg(coalesce(estado_anterior::text,'-')||'>'||estado_nuevo||coalesce(' ('||nota||')',''), ' | ' order by created_at, estado_nuevo) into t from historial_pedido where pedido_id=p1;
  res := res || chr(10) || 'T26 historial p1: ' || coalesce(t,'NULL');
  select puntos_saldo::text into t from perfiles where id=u1; res := res || chr(10) || 'T27 puntos u1 tras pago=' || coalesce(t,'NULL');
  select puntos_saldo::text into t from perfiles where id=u3; res := res || chr(10) || ' puntos invitado convertido=' || coalesce(t,'NULL');
  select stock into n from variantes_producto where id=vr; res := res || chr(10) || 'T28 stock tras 2 pagos=' || coalesce(n::text,'NULL');
  perform set_config('request.jwt.claims', json_build_object('sub',u2,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  select count(*) into n from pedidos; res := res || chr(10) || 'T29 chofer ve pedidos=' || n;
  select count(*) into n from direcciones; res := res || ' direcciones=' || n;
  select count(*) into n from perfiles; res := res || ' perfiles(solo el suyo)=' || n;
  update pedidos set estado='entregado'; get diagnostics n = row_count; res := res || chr(10) || 'T30 chofer update directo estado, filas=' || n;
  update productos set nombre='hack'; get diagnostics n = row_count; res := res || ' / edita productos, filas=' || n;
  begin perform marcar_reparto(p1, 'entregado'); res := res || chr(10) || 'T31 FALLA entregado sin pasar por en camino';
  exception when others then res := res || chr(10) || 'T31 saltarse En camino: ' || sqlerrm; end;
  j := marcar_reparto(p1, 'en_ruta');   res := res || chr(10) || 'T32 EN CAMINO: tel=' || (j->>'telefono') || chr(10) || (j->>'mensaje');
  j := marcar_reparto(p1, 'entregado'); res := res || chr(10) || 'T33 ENTREGADO: tel=' || (j->>'telefono') || chr(10) || (j->>'mensaje');
  begin perform marcar_reparto(p1, 'cancelado'); res := res || chr(10) || 'T34 FALLA chofer cancela';
  exception when others then res := res || chr(10) || 'T34 chofer otro estado: ' || sqlerrm; end;
  begin insert into rol_permisos values ('chofer','pedidos.gestionar'); res := res || chr(10) || 'T35 FALLA chofer se da permisos';
  exception when others then res := res || chr(10) || 'T35 chofer se autoasigna permiso: ' || sqlerrm; end;
  update perfiles set rol='admin' where id=u2;
  perform set_config('role','none', true);
  select rol into t from perfiles where id=u2; res := res || chr(10) || 'T36 rol chofer tras intento=' || coalesce(t,'NULL');
  select string_agg(estado_nuevo::text, '>' order by created_at, estado_nuevo) into t from historial_pedido where pedido_id=p1 and cambiado_por=u2;
  res := res || chr(10) || 'T37 historial registra al chofer: ' || coalesce(t,'NULL');
drop trigger  if exists on_auth_user_upgraded on auth.users;
drop function if exists public.handle_user_upgrade();
drop function if exists public.confirmar_pago(uuid, text, integer, jsonb, text);
drop function if exists public.marcar_reparto(uuid, public.estado_pedido);
delete from public.rol_permisos where permiso = 'pedidos.repartir';
delete from public.permisos     where codigo  = 'pedidos.repartir';
drop function if exists public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text);
drop function if exists public.normalizar_telefono_cl(text);
drop function if exists public.es_rut_valido(text);
alter table public.pedidos
  drop column if exists contacto_nombre,
  drop column if exists contacto_telefono,
  drop column if exists contacto_email,
  drop column if exists fecha_entrega,
  drop column if exists tipo_documento,
  drop column if exists doc_rut,
  drop column if exists doc_razon_social,
  drop column if exists doc_giro;
drop function if exists public.precio_efectivo(uuid);
create function public.precio_efectivo(p_perfil uuid, p_variante uuid)
returns integer language sql stable security definer set search_path to 'public' as $$
  select pv.precio
    from public.precios_variante pv
    join public.perfiles pf on pf.id = p_perfil
   where pv.variante_id = p_variante and pv.nivel_precio_id = pf.nivel_precio_id;
$$;
alter policy categorias_admin  on public.categorias          using (public.es_admin()) with check (public.es_admin());
alter policy productos_admin   on public.productos           using (public.es_admin()) with check (public.es_admin());
alter policy variantes_admin   on public.variantes_producto  using (public.es_admin()) with check (public.es_admin());
alter policy precios_var_admin on public.precios_variante    using (public.es_admin()) with check (public.es_admin());
alter policy niveles_admin     on public.niveles_precio      using (public.es_admin()) with check (public.es_admin());
alter policy cupones_admin     on public.cupones             using (public.es_admin()) with check (public.es_admin());
alter policy cupon_var_admin   on public.cupon_variantes     using (public.es_admin()) with check (public.es_admin());
alter policy recompensas_admin on public.recompensas         using (public.es_admin()) with check (public.es_admin());
alter policy zonas_admin       on public.zonas_despacho      using (public.es_admin()) with check (public.es_admin());
alter policy comunas_admin     on public.comunas_cobertura   using (public.es_admin()) with check (public.es_admin());
alter policy parametros_admin  on public.parametros          using (public.es_admin()) with check (public.es_admin());
alter policy pedidos_admin     on public.pedidos             using (public.es_admin()) with check (public.es_admin());
alter policy detalle_admin     on public.detalle_pedido      using (public.es_admin()) with check (public.es_admin());
alter policy historial_admin   on public.historial_pedido    using (public.es_admin()) with check (public.es_admin());
alter policy pagos_admin       on public.pagos               using (public.es_admin()) with check (public.es_admin());
alter policy dte_admin         on public.documentos_tributarios using (public.es_admin()) with check (public.es_admin());
alter policy mov_puntos_admin  on public.movimientos_puntos  using (public.es_admin()) with check (public.es_admin());
alter policy productos_lectura   on public.productos          using ((activo = true) or public.es_admin());
alter policy variantes_lectura   on public.variantes_producto using ((activo = true) or public.es_admin());
alter policy recompensas_lectura on public.recompensas        using ((activo = true) or public.es_admin());
alter policy cupones_lectura     on public.cupones
  using (((activo = true) and (perfil_id is null)) or (perfil_id = auth.uid()) or public.es_admin());
alter policy pedidos_select   on public.pedidos          using ((perfil_id = auth.uid()) or public.es_admin());
alter policy detalle_select   on public.detalle_pedido   using (exists (select 1 from public.pedidos p where p.id = detalle_pedido.pedido_id   and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy historial_select on public.historial_pedido using (exists (select 1 from public.pedidos p where p.id = historial_pedido.pedido_id and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy pagos_select     on public.pagos            using (exists (select 1 from public.pedidos p where p.id = pagos.pedido_id            and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy dte_select       on public.documentos_tributarios using (exists (select 1 from public.pedidos p where p.id = documentos_tributarios.pedido_id and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy mov_puntos_select on public.movimientos_puntos using ((perfil_id = auth.uid()) or public.es_admin());
alter policy perfiles_select   on public.perfiles           using ((id = auth.uid()) or public.es_admin());
drop policy if exists direcciones_reparto   on public.direcciones;
drop policy if exists perfiles_staff_update on public.perfiles;
create policy pedidos_insert on public.pedidos for insert to authenticated
  with check (perfil_id = auth.uid());
create policy detalle_insert on public.detalle_pedido for insert to authenticated
  with check (exists (select 1 from public.pedidos p
                       where p.id = detalle_pedido.pedido_id and p.perfil_id = auth.uid()
                         and p.estado = 'pendiente_pago'::estado_pedido));
create type public.app_rol as enum ('cliente', 'operador', 'admin', 'repartidor');
alter table public.perfiles drop constraint if exists perfiles_rol_fkey;
alter table public.perfiles alter column rol drop default;
alter table public.perfiles alter column rol type public.app_rol
  using (case rol when 'chofer' then 'repartidor'
                  when 'cliente' then 'cliente' when 'admin' then 'admin'
                  when 'operador' then 'operador' when 'repartidor' then 'repartidor'
                  else 'cliente' end)::public.app_rol;
alter table public.perfiles alter column rol set default 'cliente'::public.app_rol;
create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfiles
                  where id = auth.uid() and rol in ('admin','operador'));
$$;
create or replace function public.proteger_campos_perfil()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.es_admin() then
    new.rol             := old.rol;
    new.nivel_precio_id := old.nivel_precio_id;
    new.puntos_saldo    := old.puntos_saldo;
  end if;
  return new;
end;
$$;
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.perfiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)));
  return new;
end;
$$;
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;
drop function if exists public.tiene_permiso(text);
drop table if exists public.rol_permisos;
drop table if exists public.permisos;
drop table if exists public.roles;
grant execute on function public.handle_new_user()                to public, anon, authenticated;
grant execute on function public.proteger_campos_perfil()         to public, anon, authenticated;
grant execute on function public.aplicar_movimiento_puntos()      to public, anon, authenticated;
grant execute on function public.registrar_cambio_estado_pedido() to public, anon, authenticated;
grant execute on function public.set_updated_at()                 to public, anon, authenticated;
grant execute on function public.precio_efectivo(uuid, uuid)      to public, anon, authenticated;
  select count(*) into n from pg_proc where proname in ('crear_pedido','tiene_permiso','marcar_reparto','confirmar_pago','handle_user_upgrade','es_rut_valido'); res := res || chr(10) || 'REVERSAS: funciones nuevas restantes=' || n;
  select format_type(atttypid, null) into t from pg_attribute where attrelid='public.perfiles'::regclass and attname='rol'; res := res || ', tipo perfiles.rol=' || t;
  select count(*) into n from information_schema.columns where table_schema='public' and table_name='pedidos' and column_name='contacto_telefono'; res := res || ', columnas contacto=' || n;
  select count(*) into n from pg_policies where tablename='pedidos' and policyname='pedidos_insert'; res := res || ', politica original pedidos_insert=' || n;
  raise exception 'PRUEBA EN SECO (todo se deshace): %', res;
end $do$;