-- =====================================================================
-- Migración 06: aceptación obligatoria de Términos y Privacidad (aplicada el 06-nov-2026)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-25 (CA3, CA4) · Ley 21.719 (protección de datos personales)
-- Requiere:  01, 01b, 04, 03 y 05 aplicadas.
-- Aplicar:   DESPUÉS de publicar la tienda que envía la aceptación (checkout con
--            la casilla); si se aplica antes, la tienda antigua no podría comprar.
-- Reversa:   20261106_06_aceptacion_terminos_reversa.sql
-- Prueba:    20261106_06_prueba_en_seco.sql (06 + prueba; T01..T05 OK el 06-nov-2026)
--
-- Qué cambia:
--   1. pedidos.terminos_aceptados_at / terminos_version: prueba de la aceptación,
--      con la hora del servidor (no la del navegador) y la versión de los textos.
--   2. parametros.terminos_version: versión vigente de los textos legales
--      (se cambia cuando el dueño publica una versión nueva).
--   3. crear_pedido(): igual a la versión 05 + exige p_contacto.acepta_terminos = true
--      y guarda la aceptación. Los clientes no pueden modificar estas columnas
--      (solo el panel con pedidos.gestionar, por RLS).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Registro de la aceptación en el pedido
-- ---------------------------------------------------------------------
alter table public.pedidos
  add column if not exists terminos_aceptados_at timestamptz,
  add column if not exists terminos_version      text;
comment on column public.pedidos.terminos_aceptados_at is
  'Fecha y hora (servidor) en que el cliente aceptó Términos y Política de privacidad (Ley 21.719, HU-25).';
comment on column public.pedidos.terminos_version is
  'Versión de los textos legales aceptados (parametros.terminos_version).';

-- ---------------------------------------------------------------------
-- 2. Versión vigente de los textos legales
-- ---------------------------------------------------------------------
insert into public.parametros (clave, valor, descripcion)
values ('terminos_version', '2026-11', 'Versión vigente de Términos y Política de privacidad (Ley 21.719)')
on conflict (clave) do nothing;

-- ---------------------------------------------------------------------
-- 3. crear_pedido() con aceptación obligatoria
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

    select vp.id, vp.nombre, pv.precio into v
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

revoke execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Registro en el historial de migraciones de Supabase
-- ---------------------------------------------------------------------
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261106000006', '06_aceptacion_terminos') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
