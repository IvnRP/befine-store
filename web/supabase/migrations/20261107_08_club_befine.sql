-- =====================================================================
-- Migración 08: Club Befine — programa de puntos (pendiente de aplicar)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-19 (puntos) · RF-11 (fidelización)
-- Requiere:  01, 01b, 04, 03, 05, 06 y 07 aplicadas.
-- Aplicar:   cuando quieras; la tienda actual sigue funcionando (el canje y la vista del
--            Club aparecen con la versión nueva de "Mi cuenta" y del checkout).
-- Reversa:   20261107_08_club_befine_reversa.sql
-- Prueba:    20261107_08_prueba_en_seco.sql (08 + prueba; T01..T14)
--
-- Reglas (decisión del dueño, 06/07-nov-2026):
--   - 1 punto por cada $1.000 PAGADOS en recargas con envase Befine (variantes con suma_puntos).
--     Recargas con envase de otra marca, bidones, packs y dispensadores NO suman.
--   - Bono +2 puntos si el pedido lleva 6 o más de esas recargas.
--   - Premios: 30 pts = $1.000 de descuento (compra mínima $2.000) · 80 pts = envase Befine +
--     recarga (Bidón + Recarga 20 L gratis) · 150 pts = 50% de descuento en recargas (tope $7.500,
--     equivalente a 6 recargas). El canje genera un cupón personal de 1 uso que vence en 30 días;
--     solo 1 premio activo a la vez; solo cuentas registradas.
--   - La parte del pedido pagada con un premio no suma puntos; un pedido de $0 no suma puntos.
--   - Pedido cancelado después de pagado: se descuentan sus puntos.
--   - Trae un amigo: 10 puntos a cada uno cuando el amigo paga su primer pedido.
--   - Los puntos vencen tras 12 meses sin sumar puntos.
--   Todo es configurable en parametros y recompensas (sin tocar código).
--
-- Qué cambia:
--   1. variantes_producto.suma_puntos, cupones.descuento_maximo y cupones.recompensa_id,
--      recompensas (codigo, compra_minima, cupon_tope, solo_recargas, orden), pedidos.es_canje.
--   2. Parámetros del Club, los 3 premios y la nueva versión de los Términos (2026-11-07, sección 12).
--      Se retira el cupón LEGACY2000 y la recarga con
--      envase de otra marca pasa a $2.990.
--   3. _evaluar_cupon(): igual a la 04 + tope del descuento.
--   4. crear_pedido(): igual a la 06 + puntos del Club + confirmación directa del pedido de $0.
--   5. Tablas codigos_referido y referidos (solo lectura propia; se escriben por funciones).
--   6. Funciones: club_estado(), canjear_recompensa(), registrar_referido(),
--      vencer_puntos_inactivos() y los disparadores de pago (vencimiento + Trae un amigo)
--      y de cancelación (descuento de puntos).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Columnas nuevas
-- ---------------------------------------------------------------------
alter table public.variantes_producto add column if not exists suma_puntos boolean not null default false;
comment on column public.variantes_producto.suma_puntos is
  'Club Befine: true si la variante suma puntos (recargas con envase Befine).';

alter table public.cupones
  add column if not exists descuento_maximo integer check (descuento_maximo is null or descuento_maximo > 0),
  add column if not exists recompensa_id    uuid references public.recompensas(id);
comment on column public.cupones.descuento_maximo is 'Tope en CLP del descuento (ej. 50% hasta $7.500).';
comment on column public.cupones.recompensa_id    is 'Si el cupón nació de un canje del Club Befine.';

alter table public.recompensas
  add column if not exists codigo        text unique,
  add column if not exists compra_minima integer not null default 0 check (compra_minima >= 0),
  add column if not exists cupon_tope    integer check (cupon_tope is null or cupon_tope > 0),
  add column if not exists solo_recargas boolean not null default true,
  add column if not exists orden         smallint not null default 0;

alter table public.pedidos add column if not exists es_canje boolean not null default false;
comment on column public.pedidos.es_canje is 'Pedido de $0 cubierto por un premio del Club Befine.';

-- ---------------------------------------------------------------------
-- 2. Configuración del Club y datos del dueño
-- ---------------------------------------------------------------------
insert into public.parametros (clave, valor, descripcion) values
  ('clp_por_punto',          '1000', 'Club Befine: CLP pagados en recargas Befine por cada punto'),
  ('club_bono_min_recargas', '6',    'Club Befine: recargas Befine en un pedido para ganar el bono'),
  ('club_bono_puntos',       '2',    'Club Befine: puntos extra por pedido grande'),
  ('club_referido_puntos',   '10',   'Club Befine: puntos para cada uno en Trae un amigo'),
  ('club_vencimiento_meses', '12',   'Club Befine: meses sin sumar puntos para que venzan'),
  ('club_cupon_dias',        '30',   'Club Befine: días de vigencia del cupón de un premio')
on conflict (clave) do update set valor = excluded.valor, descripcion = excluded.descripcion, updated_at = now();

update public.variantes_producto set suma_puntos = (sku in ('BEF-REC-20-BEFINE', 'BEF-REC-12'));

insert into public.recompensas (codigo, nombre, descripcion, puntos_costo, tipo, cupon_tipo, cupon_valor,
                                compra_minima, cupon_tope, solo_recargas, variante_id, orden, activo)
values
  ('menor', 'Descuento de $1.000', '$1.000 menos en tus recargas (compra mínima $2.000).',
   30, 'cupon', 'monto_fijo', 1000, 2000, null, true, null, 1, true),
  ('medio', 'Envase Befine + recarga', 'Un Bidón + Recarga 20 L de regalo: agrégalo a tu pedido.',
   80, 'producto', null, null, 0, null, false,
   (select id from public.variantes_producto where sku = 'BEF-BID-20'), 2, true),
  ('mayor', '50% de descuento', 'La mitad de tus recargas en un pedido (hasta 6 recargas, máximo $7.500).',
   150, 'cupon', 'porcentaje', 50, 0, 7500, true, null, 3, true)
on conflict (codigo) do update
  set nombre = excluded.nombre, descripcion = excluded.descripcion, puntos_costo = excluded.puntos_costo,
      tipo = excluded.tipo, cupon_tipo = excluded.cupon_tipo, cupon_valor = excluded.cupon_valor,
      compra_minima = excluded.compra_minima, cupon_tope = excluded.cupon_tope,
      solo_recargas = excluded.solo_recargas, variante_id = excluded.variante_id,
      orden = excluded.orden, activo = excluded.activo;

-- Términos actualizados con las condiciones del Club Befine (sección 12): nueva versión de los textos
update public.parametros set valor = '2026-11-07', updated_at = now() where clave = 'terminos_version';

-- Decisiones del dueño (07-nov-2026): fin del cupón LEGACY2000 y recarga con envase de otra marca a $2.990
update public.cupones set activo = false where codigo = 'LEGACY2000';
update public.precios_variante pv set precio = 2990
  from public.variantes_producto vp
 where vp.id = pv.variante_id and vp.sku = 'BEF-REC-20-OTRA' and pv.nivel_precio_id = 1;

-- ---------------------------------------------------------------------
-- 3. _evaluar_cupon(): versión 04 + tope del descuento
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
  -- Tope del descuento (migración 08: ej. premio 50% hasta 6 recargas)
  if v_c.descuento_maximo is not null then
    v_desc := least(v_desc, v_c.descuento_maximo);
  end if;

  return jsonb_build_object('cupon_id', v_c.id, 'codigo', v_c.codigo, 'tipo', v_c.tipo,
                            'valor', v_c.valor, 'descuento', v_desc);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. crear_pedido(): versión 06 + Club Befine
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
  v_terminos   text;
  v_sub_pts    integer := 0;   -- subtotal de productos que suman puntos (recargas con envase Befine)
  v_cant_pts   integer := 0;   -- unidades de esos productos (para el bono por pedido grande)
  v_cup_base   integer;
  v_cup_pts    integer;
  v_desc_pts   integer := 0;
  v_bono_min   integer;
  v_bono       integer;
  v_es_canje   boolean := false;
  v_estado     text := 'pendiente_pago';
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

  -- Aceptación de los Términos y la Política de privacidad (Ley 21.719, HU-25): obligatoria.
  -- Se registra en el pedido con la hora del SERVIDOR y la versión vigente de los textos.
  if lower(coalesce(p_contacto->>'acepta_terminos', '')) <> 'true' then
    raise exception 'Debes aceptar los Términos y la Política de privacidad para comprar.';
  end if;
  select nullif(trim(valor), '') into v_terminos from public.parametros where clave = 'terminos_version';
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
                              tipo_documento, doc_rut, doc_razon_social, doc_giro,
                              terminos_aceptados_at, terminos_version)
  values (v_uid, v_dir_id, v_zona.id, v_perfil.nivel_precio_id, left(nullif(trim(p_notas), ''), 500),
          v_nombre, v_tel, v_email, v_fecha,
          v_tipo_doc, v_rut, v_razon, v_giro,
          now(), coalesce(v_terminos, 'sin-version'))
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

    select vp.id, vp.nombre, vp.suma_puntos, pv.precio into v
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
    -- Stock: ya NO se valida aquí. El stock nunca frena una venta (decisión del dueño, HU-22);
    -- se descuenta y se controla al confirmarse el pago (confirmar_pago, marca de sobreventa).

    insert into public.detalle_pedido (pedido_id, variante_id, cantidad, precio_unitario, subtotal)
    values (v_pedido_id, v.id, r.cantidad, v.precio, v.precio * r.cantidad);
    v_subtotal := v_subtotal + v.precio * r.cantidad;
    if v.suma_puntos then
      v_sub_pts  := v_sub_pts + v.precio * r.cantidad;
      v_cant_pts := v_cant_pts + r.cantidad;
    end if;
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

  -- Club Befine (migración 08): puntos SOLO por productos con suma_puntos (recargas con envase Befine),
  -- sobre lo PAGADO: se descuenta la parte del cupón que cae en esos productos (proporcional).
  -- Bono por pedido grande: +club_bono_puntos si lleva club_bono_min_recargas o más de esas recargas.
  -- Se suman recién cuando se confirma el pago (confirmar_pago).
  if v_cupon_id is not null and v_desc > 0 and v_sub_pts > 0 then
    if exists (select 1 from public.cupon_variantes where cupon_id = v_cupon_id) then
      select coalesce(sum(d.subtotal), 0),
             coalesce(sum(d.subtotal) filter (where vp.suma_puntos), 0)
        into v_cup_base, v_cup_pts
        from public.detalle_pedido d
        join public.variantes_producto vp on vp.id = d.variante_id
        join public.cupon_variantes cv on cv.cupon_id = v_cupon_id and cv.variante_id = d.variante_id
       where d.pedido_id = v_pedido_id;
    else
      v_cup_base := v_subtotal;
      v_cup_pts  := v_sub_pts;
    end if;
    if v_cup_base > 0 then
      v_desc_pts := round(v_desc::numeric * v_cup_pts / v_cup_base)::int;
    end if;
  end if;

  v_es_canje := (v_total = 0);   -- pedido cubierto entero por un premio: no suma puntos
  select nullif(valor, '')::int into v_clp_punto from public.parametros where clave = 'clp_por_punto';
  if coalesce(v_clp_punto, 0) > 0 and not v_es_canje then
    v_puntos := greatest(v_sub_pts - v_desc_pts, 0) / v_clp_punto;
    select nullif(valor, '')::int into v_bono_min from public.parametros where clave = 'club_bono_min_recargas';
    select nullif(valor, '')::int into v_bono     from public.parametros where clave = 'club_bono_puntos';
    if coalesce(v_bono_min, 0) > 0 and v_cant_pts >= v_bono_min then
      v_puntos := v_puntos + coalesce(v_bono, 0);
    end if;
  end if;

  update public.pedidos
     set subtotal        = v_subtotal,
         costo_despacho  = v_despacho,
         descuento_cupon = v_desc,
         cupon_id        = v_cupon_id,
         total           = v_total,
         puntos_ganados  = v_puntos,
         es_canje        = v_es_canje
   where id = v_pedido_id;

  -- Pedido de $0 (premio que cubre todo): Mercado Pago no cobra $0, así que se confirma aquí
  -- con la MISMA función del webhook (historial, stock, sobreventa), con un id de pago interno.
  if v_es_canje then
    perform public.confirmar_pago(v_pedido_id, 'CANJE-' || v_numero, 0, '{"origen":"canje_club"}'::jsonb, null);
    v_estado := 'en_preparacion';
  end if;

  return jsonb_build_object(
    'id', v_pedido_id, 'numero', v_numero, 'estado', v_estado, 'es_canje', v_es_canje,
    'subtotal', v_subtotal, 'costo_despacho', v_despacho,
    'descuento_cupon', v_desc, 'total', v_total,
    'puntos_ganados', v_puntos, 'fecha_entrega', v_fecha);
end;
$$;

revoke execute on function public._evaluar_cupon(text, uuid, text, text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Trae un amigo: código propio y quién invitó a quién
-- ---------------------------------------------------------------------
create table if not exists public.codigos_referido (
  perfil_id  uuid primary key references public.perfiles(id) on delete cascade,
  codigo     text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.referidos (
  referido_id  uuid primary key references public.perfiles(id) on delete cascade,  -- el amigo
  referente_id uuid not null references public.perfiles(id) on delete cascade,     -- quien invitó
  created_at   timestamptz not null default now(),
  premiado_at  timestamptz,
  check (referido_id <> referente_id)
);
alter table public.codigos_referido enable row level security;
alter table public.referidos        enable row level security;
drop policy if exists codigos_referido_propio on public.codigos_referido;
create policy codigos_referido_propio on public.codigos_referido for select to authenticated
  using (perfil_id = auth.uid() or public.tiene_permiso('puntos.gestionar'));
drop policy if exists referidos_propios on public.referidos;
create policy referidos_propios on public.referidos for select to authenticated
  using (referido_id = auth.uid() or referente_id = auth.uid() or public.tiene_permiso('puntos.gestionar'));

-- ---------------------------------------------------------------------
-- 6. Funciones internas
-- ---------------------------------------------------------------------
create or replace function public._param_int(p_clave text, p_defecto integer)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(trim(valor), '')::int from public.parametros where clave = p_clave), p_defecto);
$$;

-- Movimiento de puntos con el saldo posterior correcto (el trigger trg_mov_puntos actualiza el saldo)
create or replace function public._mover_puntos(p_perfil uuid, p_tipo public.tipo_mov_puntos, p_puntos integer,
                                                p_desc text, p_pedido uuid default null, p_recompensa uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_saldo integer;
begin
  if coalesce(p_puntos, 0) = 0 then return null; end if;
  select puntos_saldo into v_saldo from public.perfiles where id = p_perfil for update;
  insert into public.movimientos_puntos (perfil_id, pedido_id, recompensa_id, tipo, puntos, saldo_posterior, descripcion)
  values (p_perfil, p_pedido, p_recompensa, p_tipo, p_puntos, coalesce(v_saldo, 0) + p_puntos, left(p_desc, 200));
  return coalesce(v_saldo, 0) + p_puntos;
end;
$$;

-- Vencimiento: si el cliente no SUMA puntos hace club_vencimiento_meses, su saldo vence.
create or replace function public._vencer_puntos(p_perfil uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_saldo integer; v_ultimo timestamptz; v_meses integer := public._param_int('club_vencimiento_meses', 12);
begin
  select puntos_saldo into v_saldo from public.perfiles where id = p_perfil;
  if coalesce(v_saldo, 0) <= 0 then return 0; end if;
  select max(created_at) into v_ultimo from public.movimientos_puntos where perfil_id = p_perfil and puntos > 0;
  if v_ultimo is null or v_ultimo < now() - make_interval(months => v_meses) then
    perform public._mover_puntos(p_perfil, 'expiracion', -v_saldo,
                                 'Vencimiento: ' || v_meses || ' meses sin sumar puntos');
    return v_saldo;
  end if;
  return 0;
end;
$$;

-- Al pagarse un pedido: (1) vence lo antiguo ANTES de sumar lo nuevo; (2) Trae un amigo.
create or replace function public.club_al_pagar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ref public.referidos%rowtype; v_pts integer; v_tel text; v_mail text;
begin
  perform public._vencer_puntos(new.perfil_id);

  select * into v_ref from public.referidos where referido_id = new.perfil_id and premiado_at is null for update;
  if found then
    select pf.telefono, lower(u.email) into v_tel, v_mail
      from public.perfiles pf left join auth.users u on u.id = pf.id where pf.id = v_ref.referente_id;
    -- Evita invitarse a sí mismo con otra cuenta (mismo celular o correo que quien invitó)
    if (v_tel is null or new.contacto_telefono is distinct from v_tel)
       and (v_mail is null or lower(new.contacto_email) is distinct from v_mail) then
      v_pts := public._param_int('club_referido_puntos', 10);
      perform public._mover_puntos(v_ref.referente_id, 'ajuste', v_pts, 'Trae un amigo: tu invitado hizo su primera compra');
      perform public._mover_puntos(new.perfil_id,     'ajuste', v_pts, 'Trae un amigo: bienvenida al Club Befine');
    end if;
    update public.referidos set premiado_at = now() where referido_id = new.perfil_id;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_club_al_pagar on public.pedidos;
create trigger trg_club_al_pagar
  after update of estado on public.pedidos
  for each row when (new.estado = 'pagado' and old.estado = 'pendiente_pago')
  execute function public.club_al_pagar();

-- Pedido cancelado después de pagado: se descuentan los puntos que sumó (sin dejar saldo negativo)
create or replace function public.club_al_cancelar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pts integer; v_saldo integer;
begin
  select coalesce(sum(puntos), 0) into v_pts from public.movimientos_puntos
   where pedido_id = new.id and tipo in ('acumulacion', 'ajuste');
  if v_pts > 0 then
    select puntos_saldo into v_saldo from public.perfiles where id = new.perfil_id;
    perform public._mover_puntos(new.perfil_id, 'ajuste', -least(v_pts, greatest(coalesce(v_saldo, 0), 0)),
                                 'Pedido #' || new.numero || ' cancelado', new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_club_al_cancelar on public.pedidos;
create trigger trg_club_al_cancelar
  after update of estado on public.pedidos
  for each row when (new.estado = 'cancelado' and old.estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado'))
  execute function public.club_al_cancelar();

-- ---------------------------------------------------------------------
-- 7. Funciones para la tienda (cliente con sesión)
-- ---------------------------------------------------------------------
create or replace function public._es_invitado(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select u.is_anonymous from auth.users u where u.id = p_uid), true);
$$;

-- Estado del Club para "Mi cuenta": saldo, premios, cupón activo, código para invitar y movimientos
create or replace function public.club_estado()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_hoy date := (now() at time zone 'America/Santiago')::date;
  v_inv boolean; v_saldo integer; v_cod text; v_cupon jsonb; v_rec jsonb; v_mov jsonb; i int := 0;
begin
  if v_uid is null then raise exception 'Inicia sesión para ver tus puntos.' using errcode = '28000'; end if;
  v_inv := public._es_invitado(v_uid);
  perform public._vencer_puntos(v_uid);
  select puntos_saldo into v_saldo from public.perfiles where id = v_uid;

  if not v_inv then
    select codigo into v_cod from public.codigos_referido where perfil_id = v_uid;
    while v_cod is null and i < 5 loop
      i := i + 1;
      begin
        insert into public.codigos_referido (perfil_id, codigo)
        values (v_uid, 'BEF' || upper(substr(md5(v_uid::text || clock_timestamp()::text || random()::text), 1, 5)))
        returning codigo into v_cod;
      exception when unique_violation then v_cod := null;
      end;
    end loop;
  end if;

  select jsonb_build_object('codigo', c.codigo, 'nombre', r.nombre, 'descripcion', r.descripcion,
                            'vence', c.vigente_hasta, 'premio', r.codigo)
    into v_cupon
    from public.cupones c join public.recompensas r on r.id = c.recompensa_id
   where c.perfil_id = v_uid and c.activo and c.usos_actuales < coalesce(c.usos_maximos, 1)
     and (c.vigente_hasta is null or c.vigente_hasta >= v_hoy)
   order by c.created_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object('codigo', r.codigo, 'nombre', r.nombre, 'descripcion', r.descripcion,
                                               'puntos', r.puntos_costo) order by r.orden, r.puntos_costo), '[]'::jsonb)
    into v_rec from public.recompensas r where r.activo and r.codigo is not null;

  select coalesce(jsonb_agg(m order by m.fecha desc), '[]'::jsonb) into v_mov from (
    select created_at as fecha, puntos, tipo, descripcion from public.movimientos_puntos
     where perfil_id = v_uid order by created_at desc limit 8) m;

  return jsonb_build_object(
    'invitado', v_inv, 'saldo', coalesce(v_saldo, 0), 'codigo_referido', v_cod,
    'cupon_activo', v_cupon, 'recompensas', v_rec, 'movimientos', v_mov,
    'reglas', jsonb_build_object(
      'clp_por_punto',     public._param_int('clp_por_punto', 1000),
      'bono_min_recargas', public._param_int('club_bono_min_recargas', 6),
      'bono_puntos',       public._param_int('club_bono_puntos', 2),
      'referido_puntos',   public._param_int('club_referido_puntos', 10),
      'vencimiento_meses', public._param_int('club_vencimiento_meses', 12),
      'cupon_dias',        public._param_int('club_cupon_dias', 30)));
end;
$$;

-- Canje de un premio → cupón personal de 1 uso (los puntos se descuentan al canjear)
create or replace function public.canjear_recompensa(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_hoy date := (now() at time zone 'America/Santiago')::date;
  r public.recompensas%rowtype; v_saldo integer; v_activo text; v_codigo text; v_cupon uuid;
  v_tipo public.tipo_descuento; v_valor integer; v_vence date; i int := 0;
begin
  if v_uid is null or public._es_invitado(v_uid) then
    raise exception 'Crea tu cuenta gratis para canjear tus puntos.';
  end if;
  perform public._vencer_puntos(v_uid);

  select * into r from public.recompensas where codigo = lower(trim(p_codigo)) and activo;
  if not found then raise exception 'Ese premio no está disponible.'; end if;

  select puntos_saldo into v_saldo from public.perfiles where id = v_uid for update;   -- evita doble canje simultáneo
  select c.codigo into v_activo from public.cupones c
   where c.perfil_id = v_uid and c.recompensa_id is not null and c.activo
     and c.usos_actuales < coalesce(c.usos_maximos, 1) and (c.vigente_hasta is null or c.vigente_hasta >= v_hoy)
   limit 1;
  if v_activo is not null then
    raise exception 'Ya tienes un premio sin usar (cupón %). Úsalo antes de canjear otro.', v_activo;
  end if;
  if coalesce(v_saldo, 0) < r.puntos_costo then
    raise exception 'Te faltan % puntos para este premio.', r.puntos_costo - coalesce(v_saldo, 0);
  end if;

  if r.tipo = 'producto' then
    v_tipo := 'monto_fijo';
    select pv.precio into v_valor from public.precios_variante pv
      join public.perfiles pf on pf.id = v_uid and pf.nivel_precio_id = pv.nivel_precio_id
     where pv.variante_id = r.variante_id;
    if v_valor is null then raise exception 'Ese premio no está disponible.'; end if;
  else
    v_tipo := r.cupon_tipo; v_valor := r.cupon_valor;
  end if;
  v_vence := v_hoy + public._param_int('club_cupon_dias', 30);

  while v_cupon is null and i < 5 loop
    i := i + 1;
    v_codigo := 'CLUB-' || upper(substr(md5(v_uid::text || clock_timestamp()::text || random()::text), 1, 6));
    begin
      insert into public.cupones (codigo, tipo, valor, compra_minima, usos_maximos, combinable, perfil_id,
                                  vigente_desde, vigente_hasta, activo, requiere_cuenta, usos_por_cliente,
                                  descripcion, descuento_maximo, recompensa_id)
      values (v_codigo, v_tipo, v_valor, r.compra_minima, 1, false, v_uid,
              v_hoy, v_vence, true, true, 1,
              'Club Befine: ' || r.nombre, r.cupon_tope, r.id)
      returning id into v_cupon;
    exception when unique_violation then v_cupon := null;
    end;
  end loop;

  if r.tipo = 'producto' then
    insert into public.cupon_variantes (cupon_id, variante_id) values (v_cupon, r.variante_id);
  elsif r.solo_recargas then
    insert into public.cupon_variantes (cupon_id, variante_id)
    select v_cupon, vp.id from public.variantes_producto vp where vp.suma_puntos and vp.activo;
  end if;

  perform public._mover_puntos(v_uid, 'canje', -r.puntos_costo, 'Canje: ' || r.nombre, null, r.id);

  return jsonb_build_object('codigo', v_codigo, 'nombre', r.nombre, 'descripcion', r.descripcion,
                            'vence', v_vence, 'saldo', coalesce(v_saldo, 0) - r.puntos_costo);
end;
$$;

-- Trae un amigo: el invitado (cuenta registrada, sin compras pagadas) registra el código de quien lo invitó
create or replace function public.registrar_referido(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_ref uuid;
begin
  if v_uid is null or public._es_invitado(v_uid) then
    return jsonb_build_object('ok', false, 'mensaje', 'Crea tu cuenta para usar la invitación.');
  end if;
  select perfil_id into v_ref from public.codigos_referido where codigo = upper(trim(p_codigo));
  if v_ref is null then return jsonb_build_object('ok', false, 'mensaje', 'El código de invitación no existe.'); end if;
  if v_ref = v_uid then return jsonb_build_object('ok', false, 'mensaje', 'No puedes usar tu propio código.'); end if;
  if exists (select 1 from public.referidos where referido_id = v_uid) then
    return jsonb_build_object('ok', false, 'mensaje', 'Ya registraste una invitación.');
  end if;
  if exists (select 1 from public.pedidos where perfil_id = v_uid
              and estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado')) then
    return jsonb_build_object('ok', false, 'mensaje', 'La invitación es solo para clientes nuevos.');
  end if;
  insert into public.referidos (referido_id, referente_id) values (v_uid, v_ref);
  return jsonb_build_object('ok', true, 'mensaje', 'Invitación registrada: ganarás puntos con tu primera compra.');
end;
$$;

-- Vencimiento masivo (para programar una vez al día con pg_cron o correr a mano)
create or replace function public.vencer_puntos_inactivos()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; p record;
begin
  for p in select id from public.perfiles where puntos_saldo > 0 loop
    if public._vencer_puntos(p.id) > 0 then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

-- Permisos: las internas no se exponen; las del Club solo con sesión
revoke execute on function public._param_int(text, integer)  from public, anon, authenticated;
revoke execute on function public._mover_puntos(uuid, public.tipo_mov_puntos, integer, text, uuid, uuid) from public, anon, authenticated;
revoke execute on function public._vencer_puntos(uuid)       from public, anon, authenticated;
revoke execute on function public._es_invitado(uuid)         from public, anon, authenticated;
revoke execute on function public.club_al_pagar()            from public, anon, authenticated;
revoke execute on function public.club_al_cancelar()         from public, anon, authenticated;
revoke execute on function public.vencer_puntos_inactivos()  from public, anon, authenticated;
revoke execute on function public.club_estado()              from public, anon;
revoke execute on function public.canjear_recompensa(text)   from public, anon;
revoke execute on function public.registrar_referido(text)   from public, anon;
grant  execute on function public.club_estado()              to authenticated;
grant  execute on function public.canjear_recompensa(text)   to authenticated;
grant  execute on function public.registrar_referido(text)   to authenticated;

-- ---------------------------------------------------------------------
-- 8. Registro en el historial de migraciones de Supabase
-- ---------------------------------------------------------------------
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261107000008', '08_club_befine') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
