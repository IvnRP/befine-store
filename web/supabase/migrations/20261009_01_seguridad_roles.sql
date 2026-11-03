-- =====================================================================
-- Migración 01: 20261009_01_seguridad_roles
-- Proyecto:     Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Reversa:      20261009_01_seguridad_roles_reversa.sql
-- Siguientes:   pendientes/02_reparto_whatsapp.sql, pendientes/03_invitados_pago.sql
--
-- Qué hace:
--  1. Roles y permisos configurables (admin = todo, chofer = ver pedidos;
--     el admin puede crear nuevos roles y asignarles permisos).
--  2. Cierra la creación directa de pedidos/detalle desde el navegador.
--     Los pedidos se crean SOLO con crear_pedido(), que toma precios,
--     despacho y cupones desde la base (el cliente no decide montos).
--     El estado "pagado" lo marca solo el servidor (webhook Mercado Pago, mig. 03).
--  3. Pedido guarda contacto (para WhatsApp), fecha de entrega y boleta/factura.
--  4. Cupones: generales (perfil_id NULL, para todos) y personales
--     (perfil_id = cliente, solo para ese cliente). Se validan en el servidor.
--  5. Endurece perfiles (rol/nivel/puntos/activo), funciones SECURITY DEFINER
--     y search_path; el registro guarda también el teléfono.
-- No borra datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ROLES Y PERMISOS
-- ---------------------------------------------------------------------
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

-- perfiles.rol: de enum fijo a texto referenciado a roles (permite roles nuevos)
alter table public.perfiles alter column rol drop default;
alter table public.perfiles alter column rol type text
  using (case rol::text when 'repartidor' then 'chofer' when 'operador' then 'chofer' else rol::text end);
alter table public.perfiles alter column rol set default 'cliente';
alter table public.perfiles add constraint perfiles_rol_fkey
  foreign key (rol) references public.roles(id) on update cascade;
drop type public.app_rol;

-- Funciones de autorización (las usan las políticas RLS; devuelven false a visitantes)
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

-- RLS de las tablas de roles: todos los usuarios con sesión leen; solo admin escribe
alter table public.roles        enable row level security;
alter table public.permisos     enable row level security;
alter table public.rol_permisos enable row level security;

create policy roles_lectura on public.roles for select to authenticated using (true);
create policy roles_insert  on public.roles for insert to authenticated with check (public.es_admin() and not es_sistema);
create policy roles_update  on public.roles for update to authenticated
  using (public.es_admin() and not es_sistema) with check (public.es_admin() and not es_sistema);
create policy roles_delete  on public.roles for delete to authenticated using (public.es_admin() and not es_sistema);

create policy permisos_lectura on public.permisos for select to authenticated using (true);
-- (el catálogo de permisos se amplía solo por migración: cada permiso necesita sus políticas)

create policy rol_permisos_lectura on public.rol_permisos for select to authenticated using (true);
create policy rol_permisos_insert  on public.rol_permisos for insert to authenticated
  with check (public.es_admin() and rol_id not in ('admin', 'cliente'));
create policy rol_permisos_delete  on public.rol_permisos for delete to authenticated
  using (public.es_admin() and rol_id not in ('admin', 'cliente'));

-- ---------------------------------------------------------------------
-- 2. POLÍTICAS: es_admin() → permiso específico (admin sigue pudiendo todo)
-- ---------------------------------------------------------------------
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

-- Lecturas: catálogo inactivo solo para quien gestiona
alter policy productos_lectura   on public.productos          using ((activo = true) or public.tiene_permiso('catalogo.gestionar'));
alter policy variantes_lectura   on public.variantes_producto using ((activo = true) or public.tiene_permiso('catalogo.gestionar'));
alter policy recompensas_lectura on public.recompensas        using ((activo = true) or public.tiene_permiso('promociones.gestionar'));

-- Cupones: el cliente ve los generales activos y los personales suyos
alter policy cupones_lectura on public.cupones
  using (((activo = true) and (perfil_id is null)) or ((activo = true) and (perfil_id = auth.uid())) or public.tiene_permiso('promociones.gestionar'));

-- Pedidos: dueño del pedido, o staff con pedidos.ver (chofer)
alter policy pedidos_select   on public.pedidos          using ((perfil_id = auth.uid()) or public.tiene_permiso('pedidos.ver'));
alter policy detalle_select   on public.detalle_pedido   using (exists (select 1 from public.pedidos p where p.id = detalle_pedido.pedido_id   and ((p.perfil_id = auth.uid()) or public.tiene_permiso('pedidos.ver'))));
alter policy historial_select on public.historial_pedido using (exists (select 1 from public.pedidos p where p.id = historial_pedido.pedido_id and ((p.perfil_id = auth.uid()) or public.tiene_permiso('pedidos.ver'))));
alter policy pagos_select     on public.pagos            using (exists (select 1 from public.pedidos p where p.id = pagos.pedido_id            and ((p.perfil_id = auth.uid()) or public.tiene_permiso('pagos.gestionar'))));
alter policy dte_select       on public.documentos_tributarios using (exists (select 1 from public.pedidos p where p.id = documentos_tributarios.pedido_id and ((p.perfil_id = auth.uid()) or public.tiene_permiso('documentos.gestionar'))));
alter policy mov_puntos_select on public.movimientos_puntos using ((perfil_id = auth.uid()) or public.tiene_permiso('puntos.gestionar'));

-- Chofer: ve la dirección de los pedidos (el contacto viene en el propio pedido,
-- así que no necesita acceso a la tabla de clientes)
create policy direcciones_reparto on public.direcciones for select to authenticated
  using (public.tiene_permiso('pedidos.ver')
         and exists (select 1 from public.pedidos p where p.direccion_id = direcciones.id));

alter policy perfiles_select on public.perfiles
  using ((id = auth.uid()) or public.tiene_permiso('clientes.ver'));

create policy perfiles_staff_update on public.perfiles for update to authenticated
  using (public.tiene_permiso('clientes.gestionar')) with check (public.tiene_permiso('clientes.gestionar'));

-- El navegador ya NO inserta pedidos ni detalle directamente
drop policy pedidos_insert on public.pedidos;
drop policy detalle_insert on public.detalle_pedido;

-- ---------------------------------------------------------------------
-- 3. PERFILES: campos protegidos
--    Cambios hechos desde la API (navegador) por usuarios sin permiso se
--    ignoran. Los cambios internos del servidor (p. ej. sumar puntos) pasan.
-- ---------------------------------------------------------------------
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

-- Registro: guarda nombre y teléfono; soporta Google (full_name) e invitados sin correo
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

-- Precio para el usuario actual (ya no recibe el id de otro perfil)
drop function public.precio_efectivo(uuid, uuid);
create function public.precio_efectivo(p_variante uuid)
returns integer language sql stable security invoker set search_path = public as $$
  select pv.precio
    from public.precios_variante pv
   where pv.variante_id = p_variante
     and pv.nivel_precio_id = coalesce((select nivel_precio_id from public.perfiles where id = auth.uid()), 1);
$$;


-- ---------------------------------------------------------------------
-- 4. DATOS DEL PEDIDO: contacto, entrega y documento tributario
-- ---------------------------------------------------------------------
alter table public.pedidos
  add column contacto_nombre   text,
  add column contacto_telefono text,          -- formato 569XXXXXXXX (para WhatsApp)
  add column contacto_email    text,
  add column fecha_entrega     date,
  add column tipo_documento    public.tipo_dte not null default 'boleta',
  add column doc_rut           text,
  add column doc_razon_social  text,
  add column doc_giro          text;

-- Teléfono chileno → '569XXXXXXXX' (null si no es válido)
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

-- RUT chileno (módulo 11)
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

-- ---------------------------------------------------------------------
-- 5. CREAR PEDIDO (única vía para clientes)
--    p_items     = [{"variante_id": "...", "cantidad": 2}, ...]
--    p_direccion = {"calle","numero","depto","comuna","referencia"}
--    p_contacto  = {"nombre","telefono","email"}            (obligatorio)
--    p_entrega   = {"tipo":"estandar"|"agendada","fecha":"AAAA-MM-DD"} (opcional)
--    p_documento = {"tipo":"boleta"|"factura","rut","razon_social","giro"} (opcional)
--    Devuelve {id, numero, estado, subtotal, costo_despacho, descuento_cupon,
--    total, puntos_ganados, fecha_entrega}. El pedido nace en 'pendiente_pago'.
-- ---------------------------------------------------------------------
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
  -- Usuario (registrado o invitado con sesión anónima)
  if v_uid is null then
    raise exception 'Debes iniciar sesión o continuar como invitado para comprar.' using errcode = '28000';
  end if;
  select * into v_perfil from public.perfiles where id = v_uid;
  if not found or not v_perfil.activo then
    raise exception 'Tu cuenta no está habilitada para comprar.';
  end if;

  -- Ítems
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El carrito está vacío.';
  end if;
  if jsonb_array_length(p_items) > 50 then
    raise exception 'Demasiados productos en un solo pedido.';
  end if;

  -- Contacto (obligatorio: el teléfono se usa para avisos por WhatsApp)
  v_nombre := left(nullif(trim(p_contacto->>'nombre'), ''), 80);
  v_tel    := public.normalizar_telefono_cl(p_contacto->>'telefono');
  v_email  := lower(left(nullif(trim(p_contacto->>'email'), ''), 120));
  if v_nombre is null then raise exception 'Ingresa tu nombre.'; end if;
  if v_tel is null then raise exception 'Ingresa un celular válido (ej: 9 1234 5678).'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Ingresa un correo válido.';
  end if;

  -- Fecha de entrega: día hábil (lun-vie), desde mañana y hasta 45 días
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

  -- Documento tributario
  if lower(coalesce(p_documento->>'tipo', 'boleta')) = 'factura' then
    v_tipo_doc := 'factura';
    v_rut   := upper(regexp_replace(coalesce(p_documento->>'rut', ''), '[^0-9kK]', '', 'g'));
    v_razon := left(nullif(trim(p_documento->>'razon_social'), ''), 120);
    v_giro  := left(nullif(trim(p_documento->>'giro'), ''), 120);
    if not public.es_rut_valido(v_rut) then raise exception 'El RUT para la factura no es válido.'; end if;
    if v_razon is null or v_giro is null then raise exception 'Para factura indica razón social y giro.'; end if;
    v_rut := left(v_rut, length(v_rut) - 1) || '-' || right(v_rut, 1);
  end if;

  -- Dirección y zona de despacho (según comuna con cobertura)
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

  -- Completa el perfil si le faltan datos (invitados / registro sin teléfono)
  update public.perfiles
     set telefono = coalesce(telefono, v_tel),
         nombre   = case when nombre = 'Invitado' then v_nombre else nombre end
   where id = v_uid;

  -- Pedido (montos se completan abajo)
  insert into public.pedidos (perfil_id, direccion_id, zona_id, nivel_precio_id, notas,
                              contacto_nombre, contacto_telefono, contacto_email, fecha_entrega,
                              tipo_documento, doc_rut, doc_razon_social, doc_giro)
  values (v_uid, v_dir_id, v_zona.id, v_perfil.nivel_precio_id, left(nullif(trim(p_notas), ''), 500),
          v_nombre, v_tel, v_email, v_fecha,
          v_tipo_doc, v_rut, v_razon, v_giro)
  returning id, numero into v_pedido_id, v_numero;

  -- Detalle: precio SIEMPRE desde la base, según el nivel del cliente
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

  -- Cupón: generales (perfil_id NULL) para todos; personales solo para su cliente
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
    if v_base <= 0 then
      raise exception 'El cupón no aplica a los productos de tu carrito.';
    end if;

    v_desc := case v_cupon.tipo
                when 'porcentaje' then round(v_base * least(v_cupon.valor, 100) / 100.0)::int
                else least(v_cupon.valor, v_base)
              end;
    update public.cupones set usos_actuales = usos_actuales + 1 where id = v_cupon.id;
  end if;

  -- Despacho (gratis sobre el mínimo en zonas con costo)
  v_despacho := v_zona.costo_despacho;
  select nullif(valor, '')::int into v_gratis from public.parametros where clave = 'envio_gratis_minimo';
  if v_despacho > 0 and v_gratis is not null and v_subtotal >= v_gratis then
    v_despacho := 0;
  end if;

  v_total := greatest(v_subtotal - v_desc, 0) + v_despacho;

  -- Puntos que ganará (se suman recién cuando se confirma el pago)
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

-- ---------------------------------------------------------------------
-- 6. PERMISOS DE EJECUCIÓN DE FUNCIONES
-- ---------------------------------------------------------------------
-- Funciones de trigger: nadie las llama por la API
revoke execute on function public.handle_new_user()                 from public, anon, authenticated;
revoke execute on function public.proteger_campos_perfil()          from public, anon, authenticated;
revoke execute on function public.aplicar_movimiento_puntos()       from public, anon, authenticated;
revoke execute on function public.registrar_cambio_estado_pedido()  from public, anon, authenticated;
revoke execute on function public.set_updated_at()                  from public, anon, authenticated;

-- crear_pedido: solo con sesión (registrada o de invitado)
revoke execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) to authenticated;

-- es_admin / tiene_permiso: deben quedar ejecutables por anon y authenticated porque
-- las políticas RLS del catálogo público las evalúan (a un visitante le responden false).
grant execute on function public.es_admin()                    to anon, authenticated;
grant execute on function public.tiene_permiso(text)           to anon, authenticated;
grant execute on function public.precio_efectivo(uuid)         to anon, authenticated;
grant execute on function public.normalizar_telefono_cl(text)  to anon, authenticated;
grant execute on function public.es_rut_valido(text)           to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. REGISTRO EN EL HISTORIAL DE MIGRACIONES DE SUPABASE
--    (al ejecutarla desde el SQL Editor no queda registrada sola;
--     así aparece en Database > Migrations)
-- ---------------------------------------------------------------------
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261009000001', '01_seguridad_roles') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
