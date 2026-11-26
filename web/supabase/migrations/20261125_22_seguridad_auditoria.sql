-- =====================================================================
-- Migración 22: correcciones de la auditoría de seguridad (25-nov-2026, Carlos e Iván)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Requiere:  01 a 21 aplicadas.
-- Reversa:   20261125_22_seguridad_auditoria_reversa.sql
-- Prueba:    20261125_22_prueba_en_seco.sql (22 + prueba; T01..T14 y T10b)
--
-- Hallazgos que resuelve:
--   #2 (alta)  Cupones gastados por pedidos sin pagar: el uso se cuenta al confirmarse el pago y solo se
--              devuelve si el pedido cancelado lo había contado. Corrige el contador de los pendientes de hoy.
--              El tope suma además los pedidos sin pagar del MISMO cliente (no lo usa dos veces) y un premio
--              del Club ya puesto en un pedido sin pagar cuenta como usado al canjear el siguiente.
--   #3 (alta)  Bots con cuentas de invitado (parte de base de datos): máximo 5 pedidos sin pagar en 24 h por
--              cuenta, y los pedidos sin pago se vencen solos a las 48 h (pg_cron, cada hora). Si después llega
--              el pago de un pedido vencido, se reabre y se confirma: nunca se pierde una venta pagada.
--              (El CAPTCHA de Supabase Auth se activa en el panel: no es SQL.)
--   #5 (media) Un empleado con clientes.gestionar ya no puede cambiar su PROPIO nivel de precio, estado ni
--              marca de empresa (solo el admin).
--   #7 (media) El repartidor ya no puede listar direcciones de la tabla: recibe solo las de sus entregas
--              activas por reparto_del_dia(). Quien tiene pedidos.ver (admin) mantiene el historial.
--   #8 (baja)  Se mantiene revisar_cupon para visitantes sin sesión: la tienda la usa para mostrar el descuento
--              ANTES de crear la sesión de invitado; quitarla rompería los cupones de quien compra sin cuenta.
--              No expone datos (solo dice si un código es válido).
-- No incluye #1 (firma del webhook: Edge Function mp-webhook), #4 (contraseñas filtradas: panel de Auth)
-- ni #6 (borrar respaldo_pre_golive: se hace aparte, con un respaldo descargado antes).
-- =====================================================================

-- #3 Vencimiento automático de pedidos sin pago
alter table public.pedidos add column if not exists vencido_at timestamptz;
comment on column public.pedidos.vencido_at is
  'Cuándo se canceló solo por no pagarse en 48 h (migración 22). Si después llega el pago, confirmar_pago lo reabre.';

-- #2 Cupones: correción del contador para los pedidos pendientes que ya lo habían sumado al crearse
update public.cupones c
   set usos_actuales = greatest(c.usos_actuales - x.n, 0)
  from (select cupon_id, count(*)::int as n from public.pedidos
         where estado = 'pendiente_pago' and cupon_id is not null group by cupon_id) x
 where c.id = x.cupon_id;

-- #2 Al cancelar, se devuelve el uso SOLO si ese pedido lo había contado (es decir, si estaba pagado)
create or replace function public.devolver_uso_cupon()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'cancelado' and old.estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado')
     and new.cupon_id is not null then
    update public.cupones set usos_actuales = greatest(usos_actuales - 1, 0) where id = new.cupon_id;
  end if;
  return new;
end;
$$;

-- #2 y #3: crear_pedido (sin sumar el cupón; tope de pedidos sin pagar) y confirmar_pago (suma el cupón;
-- reabre un pedido vencido si llega su pago). El resto de ambas funciones queda igual.
CREATE OR REPLACE FUNCTION public.crear_pedido(p_items jsonb, p_direccion jsonb, p_contacto jsonb, p_entrega jsonb DEFAULT NULL::jsonb, p_documento jsonb DEFAULT NULL::jsonb, p_cupon_codigo text DEFAULT NULL::text, p_notas text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Auditoría 25-nov-2026 (#3): freno a bots. Como máximo 5 pedidos sin pagar en 24 h por cuenta o invitado
  -- (la tienda ya reutiliza el pendiente cuando el carrito no cambia, así que un cliente real no llega a este tope).
  if (select count(*) from public.pedidos
       where perfil_id = v_uid and estado = 'pendiente_pago' and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'Tienes varios pedidos sin pagar. Paga uno de ellos o espera un rato antes de crear otro.';
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
    -- Auditoría #2: el uso del cupón se cuenta al CONFIRMARSE el pago (confirmar_pago), no aquí:
    -- así un bot no puede agotar un cupón creando pedidos que nunca paga.
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
$function$

;

CREATE OR REPLACE FUNCTION public.confirmar_pago(p_pedido uuid, p_mp_payment_id text, p_monto integer, p_raw jsonb DEFAULT NULL::jsonb, p_mp_preference_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p          public.pedidos%rowtype;
  v_saldo      integer;
  v_sobreventa boolean := false;
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

  -- Auditoría #3: un pedido vencido automáticamente (48 h sin pago) que Mercado Pago confirma después
  -- (ej. pago en efectivo que tarda) se reabre y se confirma normalmente: nunca se pierde una venta pagada.
  if v_p.estado = 'cancelado' and v_p.vencido_at is not null then
    update public.pedidos set estado = 'pendiente_pago', vencido_at = null where id = p_pedido;
    update public.historial_pedido set nota = 'Reabierto: llegó el pago de un pedido vencido'
     where pedido_id = p_pedido and estado_nuevo = 'pendiente_pago' and nota is null;
    v_p.estado := 'pendiente_pago';
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
  -- Auditoría #2: el uso del cupón se cuenta recién ahora, con el pago confirmado
  if v_p.cupon_id is not null then
    update public.cupones set usos_actuales = usos_actuales + 1 where id = v_p.cupon_id;
  end if;
  update public.pedidos set estado = 'en_preparacion' where id = p_pedido;
  update public.historial_pedido
     set nota = case estado_nuevo when 'pagado' then 'Pago confirmado por Mercado Pago (' || p_mp_payment_id || ')'
                                  else 'Automático al confirmar el pago' end
   where pedido_id = p_pedido and estado_nuevo in ('pagado', 'en_preparacion') and nota is null;

  -- Sobreventa (HU-22): el pago ya está hecho, así que el pedido se confirma igual.
  -- Se bloquean las variantes del pedido (dos pagos simultáneos no se pisan) y, si alguna
  -- con control de stock no alcanza, el pedido queda marcado para la alerta del panel.
  perform 1 from public.variantes_producto vp
    join public.detalle_pedido d on d.variante_id = vp.id
   where d.pedido_id = p_pedido
     for update of vp;
  select exists (
    select 1 from public.detalle_pedido d
      join public.variantes_producto vp on vp.id = d.variante_id
     where d.pedido_id = p_pedido and vp.controla_stock and vp.stock < d.cantidad
  ) into v_sobreventa;
  if v_sobreventa then
    update public.pedidos set sobreventa = true where id = p_pedido;
  end if;

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
                            'numero', v_p.numero, 'puntos_sumados', v_p.puntos_ganados,
                            'sobreventa', v_sobreventa);
end;
$function$

;

-- #2 Tope de usos del cupón: usos pagados + pedidos sin pagar del mismo cliente
CREATE OR REPLACE FUNCTION public._evaluar_cupon(p_codigo text, p_uid uuid, p_email text, p_tel text, p_lineas jsonb, p_bloquear boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- Auditoría #2: los usos se cuentan al PAGAR; para el tope se suman además los pedidos sin pagar de ESTE
  -- cliente (así nadie usa dos veces un cupón de 1 uso dejando pedidos pendientes, y un bot no bloquea a otros).
  if v_c.usos_maximos is not null and v_c.usos_actuales + (
       select count(*) from public.pedidos p
        where p.cupon_id = v_c.id and p.estado = 'pendiente_pago'
          and (p.perfil_id = p_uid
               or (v_email is not null and lower(p.contacto_email) = v_email)
               or (v_tel is not null and p.contacto_telefono = v_tel))) >= v_c.usos_maximos then
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
$function$

;

-- #2 Un premio del Club que ya está en un pedido (sin pagar) cuenta como usado al canjear otro
CREATE OR REPLACE FUNCTION public.canjear_recompensa(p_codigo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
     -- Auditoría #2: un premio que ya está en un pedido (aunque aún no se pague) no cuenta como "sin usar"
     and not exists (select 1 from public.pedidos p where p.cupon_id = c.id and p.estado <> 'cancelado')
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
$function$

;

-- #3 Vencer pedidos sin pago (la llama pg_cron; nadie desde la API)
create or replace function public.vencer_pedidos_pendientes(p_horas integer default 48)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  with v as (
    update public.pedidos set estado = 'cancelado', vencido_at = now()
     where estado = 'pendiente_pago' and created_at < now() - make_interval(hours => greatest(p_horas, 24))
     returning id)
  select count(*) into v_n from v;
  update public.historial_pedido h
     set nota = 'Vencido: ' || greatest(p_horas, 24) || ' h sin pago (automático)'
   where h.estado_nuevo = 'cancelado' and h.nota is null
     and exists (select 1 from public.pedidos p where p.id = h.pedido_id and p.vencido_at is not null);
  return v_n;
end;
$$;
revoke execute on function public.vencer_pedidos_pendientes(integer) from public, anon, authenticated;

-- Programación cada hora con pg_cron (si la extensión está disponible; si no, se avisa y no falla)
do $cron$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.unschedule(jobid) from cron.job where jobname = 'befine-vencer-pendientes';
    perform cron.schedule('befine-vencer-pendientes', '17 * * * *', 'select public.vencer_pedidos_pendientes(48)');
  else
    raise notice 'pg_cron no está disponible: los pedidos sin pago no se vencerán solos.';
  end if;
exception when others then
  raise notice 'No se pudo programar pg_cron (%): actívalo en Database → Extensions y vuelve a aplicar esta sección.', sqlerrm;
end;
$cron$;

-- #5 Un empleado no puede cambiar su propio nivel de precio, estado ni marca de empresa
create or replace function public.proteger_campos_perfil()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;                                   -- cambio interno del servidor
  end if;
  if not public.es_admin() then
    new.rol := old.rol;                           -- roles: solo admin
    if not public.tiene_permiso('clientes.gestionar') or new.id = auth.uid() then
      -- un cliente nunca, y un empleado tampoco sobre SU propio perfil (auditoría #5)
      new.nivel_precio_id := old.nivel_precio_id;
      new.activo          := old.activo;
      new.es_empresa      := old.es_empresa;      -- cliente B2B: lo define el negocio
    end if;
    new.puntos_saldo := old.puntos_saldo;         -- puntos: solo vía movimientos_puntos
  end if;
  return new;
end;
$$;

-- #5 (también desde el panel): editar_cliente() no deja que un empleado se marque como empresa ni cambie su estado
CREATE OR REPLACE FUNCTION public.editar_cliente(p_perfil uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Auditoría #5: un empleado no cambia su PROPIA condición de empresa ni su estado (solo el admin)
  if p_perfil = v_yo and not public.es_admin()
     and (v_emp is distinct from o.es_empresa or v_activo is distinct from o.activo) then
    raise exception 'No puedes cambiar tu propia condición de empresa ni tu estado: pídeselo al administrador.' using errcode = '42501';
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
$function$

;

-- #7 Direcciones: solo quien tiene pedidos.ver lee la tabla (con el historial). El chofer (pedidos.repartir)
-- ya no la lee directamente: recibe las direcciones de SUS entregas activas por reparto_del_dia().
drop policy if exists direcciones_reparto on public.direcciones;
create policy direcciones_reparto on public.direcciones for select to authenticated
  using (public.tiene_permiso('pedidos.ver')
         and exists (select 1 from public.pedidos p where p.direccion_id = direcciones.id));

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261125000022', '22_seguridad_auditoria') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
