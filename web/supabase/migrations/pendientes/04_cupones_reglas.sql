-- =====================================================================
-- Migración 04 (PENDIENTE): reglas de cupones — campañas y bienvenida
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Requiere:  01_seguridad_roles aplicada. Independiente de 02 y 03.
-- Aplicar:   junto con la sección Cupones del panel y el cupón del checkout.
-- Reversa:   04_cupones_reglas_reversa.sql
-- Control de cambios: cambio menor CM-01 (RF-20), aprobado por el líder de sprint (Plan 11, §5).
--
-- Qué agrega:
--  1. Cupones con nuevas reglas, todas validadas en el servidor:
--       requiere_cuenta     → no lo puede usar un invitado (sesión anónima)
--       solo_primera_compra → solo si la cuenta, el correo y el teléfono no
--                             tienen compras pagadas (cupón de bienvenida)
--       usos_por_cliente    → límite por cliente (cuenta, correo o teléfono)
--       descripcion         → nota interna (ej: "Campaña Cyber 2026")
--  2. _evaluar_cupon(): ÚNICA lógica de cupones (vigencia, usos, compra mínima,
--     productos a los que aplica y las reglas nuevas). La usan crear_pedido()
--     y revisar_cupon(); no se expone por la API.
--  3. revisar_cupon(): el checkout muestra el descuento (o por qué no aplica)
--     ANTES de pagar. Solo lee; no gasta usos.
--  4. crear_pedido(): misma función de la 01, con el bloque de cupón
--     reemplazado por _evaluar_cupon().
--  5. Al cancelar un pedido con cupón se devuelve su uso (pendiente de la 01).
--
-- "Compra pagada" = pedido en pagado, en_preparacion, en_ruta o entregado.
-- Un pedido pendiente de pago con el mismo cupón también cuenta como uso
-- (evita crear dos pedidos con el cupón de bienvenida y pagar ambos).
--
-- ANTES DE APLICAR: crear_pedido() se reemplaza completa. Confirmar que la
-- versión en producción es la de la migración 01 (ver LEEME.md).
-- No borra datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Nuevas reglas en cupones
-- ---------------------------------------------------------------------
alter table public.cupones
  add column requiere_cuenta     boolean not null default false,
  add column solo_primera_compra boolean not null default false,
  add column usos_por_cliente    integer check (usos_por_cliente is null or usos_por_cliente > 0),
  add column descripcion         text    check (descripcion is null or length(descripcion) <= 200);

-- El cupón de bienvenida siempre exige cuenta: así cada uso queda asociado a un cliente real
alter table public.cupones
  add constraint cupones_bienvenida_con_cuenta check (not solo_primera_compra or requiere_cuenta);

-- Búsqueda de usos por cliente
create index if not exists idx_pedidos_cupon on public.pedidos(cupon_id) where cupon_id is not null;

-- ---------------------------------------------------------------------
-- 2. Lógica única de cupones
--    p_lineas = [{"variante_id": "...", "subtotal": 6000}, ...]  (precios del servidor)
--    Devuelve {cupon_id, codigo, tipo, valor, descuento} o lanza el motivo en español.
-- ---------------------------------------------------------------------
create or replace function public._evaluar_cupon(
  p_codigo   text,
  p_uid      uuid,
  p_email    text,
  p_tel      text,
  p_lineas   jsonb,
  p_bloquear boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_hoy    date := (now() at time zone 'America/Santiago')::date;
  v_c      public.cupones%rowtype;
  v_sub    integer;
  v_base   integer;
  v_desc   integer;
  v_anon   boolean;
  v_usos   integer;
  v_limite integer;
  v_email  text := lower(nullif(trim(p_email), ''));
  v_tel    text := public.normalizar_telefono_cl(p_tel);
begin
  select coalesce(sum((l->>'subtotal')::int), 0) into v_sub
    from jsonb_array_elements(coalesce(p_lineas, '[]'::jsonb)) l;

  if p_bloquear then
    select * into v_c from public.cupones
     where upper(codigo) = upper(trim(p_codigo)) and activo
       and (perfil_id is null or perfil_id = p_uid)
       and (vigente_desde is null or vigente_desde <= v_hoy)
       and (vigente_hasta is null or vigente_hasta >= v_hoy)
       for update;
  else
    select * into v_c from public.cupones
     where upper(codigo) = upper(trim(p_codigo)) and activo
       and (perfil_id is null or perfil_id = p_uid)
       and (vigente_desde is null or vigente_desde <= v_hoy)
       and (vigente_hasta is null or vigente_hasta >= v_hoy);
  end if;
  if not found then
    raise exception 'El cupón no es válido o ya venció.';
  end if;
  if v_c.usos_maximos is not null and v_c.usos_actuales >= v_c.usos_maximos then
    raise exception 'El cupón ya alcanzó su límite de usos.';
  end if;
  if v_sub < v_c.compra_minima then
    raise exception 'El cupón requiere una compra mínima de $%.', replace(to_char(v_c.compra_minima, 'FM999,999,999'), ',', '.');
  end if;

  -- Requiere cuenta registrada (no invitado)
  if v_c.requiere_cuenta then
    select u.is_anonymous into v_anon from auth.users u where u.id = p_uid;
    if p_uid is null or v_anon is distinct from false then
      raise exception 'Este cupón es para clientes con cuenta. Crea tu cuenta gratis para usarlo.';
    end if;
  end if;

  -- Solo primera compra: ni la cuenta, ni el correo, ni el teléfono tienen compras pagadas
  if v_c.solo_primera_compra and exists (
       select 1 from public.pedidos p
        where p.estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado')
          and (p.perfil_id = p_uid
               or (v_email is not null and lower(p.contacto_email) = v_email)
               or (v_tel is not null and p.contacto_telefono = v_tel))) then
    raise exception 'Este cupón es solo para tu primera compra.';
  end if;

  -- Usos por cliente (incluye pedidos pendientes de pago; los cancelados no cuentan)
  v_limite := case when v_c.solo_primera_compra then 1 else v_c.usos_por_cliente end;
  if v_limite is not null then
    select count(*) into v_usos from public.pedidos p
     where p.cupon_id = v_c.id and p.estado <> 'cancelado'
       and (p.perfil_id = p_uid
            or (v_email is not null and lower(p.contacto_email) = v_email)
            or (v_tel is not null and p.contacto_telefono = v_tel));
    if v_usos >= v_limite then
      if v_c.solo_primera_compra then
        raise exception 'Ya tienes un pedido con este cupón. Si no lo vas a pagar, cancélalo para usarlo de nuevo.';
      end if;
      raise exception 'Ya usaste este cupón el máximo de veces permitido.';
    end if;
  end if;

  -- Productos a los que aplica (si el cupón está limitado a algunas variantes)
  if exists (select 1 from public.cupon_variantes where cupon_id = v_c.id) then
    select coalesce(sum((l->>'subtotal')::int), 0) into v_base
      from jsonb_array_elements(p_lineas) l
      join public.cupon_variantes cv on cv.cupon_id = v_c.id and cv.variante_id = (l->>'variante_id')::uuid;
  else
    v_base := v_sub;
  end if;
  if v_base <= 0 then
    raise exception 'El cupón no aplica a los productos de tu carrito.';
  end if;

  v_desc := case v_c.tipo
              when 'porcentaje' then round(v_base * least(v_c.valor, 100) / 100.0)::int
              else least(v_c.valor, v_base)
            end;

  return jsonb_build_object('cupon_id', v_c.id, 'codigo', v_c.codigo, 'tipo', v_c.tipo,
                            'valor', v_c.valor, 'descuento', v_desc);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Revisar cupón desde el checkout (solo lectura, no gasta usos)
--    p_items = [{"variante_id": "...", "cantidad": 2}, ...]
--    Devuelve {valido:true, codigo, descuento, ...} o {valido:false, mensaje}.
--    Para no revelar datos de terceros, la regla de primera compra se revisa
--    aquí solo con la cuenta del propio usuario; crear_pedido() la revisa
--    además con el correo y el teléfono del pedido.
-- ---------------------------------------------------------------------
create or replace function public.revisar_cupon(p_codigo text, p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_nivel  smallint;
  v_email  text;
  v_tel    text;
  v_lineas jsonb;
begin
  if nullif(trim(p_codigo), '') is null then
    return jsonb_build_object('valido', false, 'mensaje', 'Escribe un código.');
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0
     or jsonb_array_length(p_items) > 50 then
    return jsonb_build_object('valido', false, 'mensaje', 'Tu carrito está vacío.');
  end if;

  select pf.nivel_precio_id, pf.telefono into v_nivel, v_tel from public.perfiles pf where pf.id = v_uid;
  select u.email into v_email from auth.users u where u.id = v_uid and not u.is_anonymous;

  select coalesce(jsonb_agg(jsonb_build_object('variante_id', vp.id, 'subtotal', pv.precio * x.cantidad)), '[]'::jsonb)
    into v_lineas
    from (select (e->>'variante_id')::uuid as variante_id, least(greatest(sum((e->>'cantidad')::int), 1), 200) as cantidad
            from jsonb_array_elements(p_items) e group by 1) x
    join public.variantes_producto vp on vp.id = x.variante_id and vp.activo
    join public.productos p on p.id = vp.producto_id and p.activo
    join public.precios_variante pv on pv.variante_id = vp.id and pv.nivel_precio_id = coalesce(v_nivel, 1);

  return jsonb_build_object('valido', true) || public._evaluar_cupon(p_codigo, v_uid, v_email, v_tel, v_lineas, false);
exception
  when raise_exception then
    return jsonb_build_object('valido', false, 'mensaje', sqlerrm);
  when invalid_text_representation then
    return jsonb_build_object('valido', false, 'mensaje', 'Tu carrito tiene un producto que ya no existe.');
end;
$$;

-- ---------------------------------------------------------------------
-- 4. crear_pedido(): versión 04 (igual a la 01 salvo el bloque de cupón)
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
  v_cupon_id   uuid;
  v_lineas     jsonb;
  v_res        jsonb;
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

  -- Cupón (migración 04): todas las reglas en _evaluar_cupon(), la misma función que
  -- usa revisar_cupon() para mostrar el descuento en el checkout antes de pagar.
  if nullif(trim(p_cupon_codigo), '') is not null then
    select coalesce(jsonb_agg(jsonb_build_object('variante_id', d.variante_id, 'subtotal', d.subtotal)), '[]'::jsonb)
      into v_lineas
      from public.detalle_pedido d
     where d.pedido_id = v_pedido_id;
    v_res      := public._evaluar_cupon(p_cupon_codigo, v_uid, v_email, v_tel, v_lineas, true);
    v_cupon_id := (v_res->>'cupon_id')::uuid;
    v_desc     := (v_res->>'descuento')::int;
    update public.cupones set usos_actuales = usos_actuales + 1 where id = v_cupon_id;
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
         cupon_id        = v_cupon_id,
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
-- 5. Pedido cancelado → se devuelve el uso del cupón
-- ---------------------------------------------------------------------
create or replace function public.devolver_uso_cupon()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'cancelado' and old.estado is distinct from 'cancelado' and new.cupon_id is not null then
    update public.cupones set usos_actuales = greatest(usos_actuales - 1, 0) where id = new.cupon_id;
  end if;
  return new;
end;
$$;

create trigger trg_pedido_cancelado_cupon
  after update of estado on public.pedidos
  for each row execute function public.devolver_uso_cupon();

-- ---------------------------------------------------------------------
-- 6. Permisos de ejecución
-- ---------------------------------------------------------------------
revoke execute on function public._evaluar_cupon(text, uuid, text, text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.devolver_uso_cupon() from public, anon, authenticated;
revoke execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) to authenticated;
revoke execute on function public.revisar_cupon(text, jsonb) from public;
grant  execute on function public.revisar_cupon(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Registro en el historial de migraciones de Supabase
-- ---------------------------------------------------------------------
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261019000004', '04_cupones_reglas') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
