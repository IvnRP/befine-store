-- =====================================================================
-- Migración 21: pedidos fuera de la página (WhatsApp, llamada, presencial)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  Requerimiento del dueño 25-nov-2026. Los clientes que aún piden por WhatsApp o llamada,
--            o que pagan en efectivo, con tarjeta presencial o por transferencia, se registran en el
--            panel (chofer o admin) y entran a la MISMA ruta de reparto que los pedidos de la web.
-- Requiere:  01 a 20 aplicadas.
-- Reversa:   20261125_21_pedidos_fuera_pagina_reversa.sql
-- Prueba:    20261125_21_prueba_en_seco.sql (21 + prueba; T01..T14)
--
-- Decisiones del dueño:
--   * Productos del catálogo con su precio vigente y despacho por comuna (lo calcula el servidor);
--     se puede aplicar un descuento con motivo, que queda registrado.
--   * Cobro: medio (efectivo, tarjeta, transferencia) y si ya está pagado o se cobra al entregar.
--   * Cuentan en Ventas del mes y en Boletas por subir. NO suman puntos del Club ni se vinculan a la
--     ficha de un cliente (no tienen perfil: perfil_id = null).
--   * El chofer los registra, cambia su estado y registra el cobro; solo el admin anula o corrige montos.
--
-- Qué hace:
--   1. Permiso nuevo pedidos.registrar (admin y chofer).
--   2. pedidos: canal, medio y estado del cobro, descuento con motivo, quién lo registró. perfil_id
--      pasa a ser opcional SOLO para pedidos fuera de la página (la web siempre exige perfil).
--   3. direcciones.perfil_id opcional: la dirección de un pedido fuera de la página no pertenece a
--      ninguna cuenta; solo la ve el equipo por la política direcciones_reparto.
--   4. opciones_pedido_manual(): catálogo con precios, comunas con costo de despacho y umbral gratis.
--   5. registrar_pedido_manual(): crea el pedido "En preparación", descuenta stock y deja el historial.
--   6. cobrar_pedido(): registra el cobro al entregar (chofer o admin).
--   7. ajustar_pedido_manual(): el admin corrige el descuento (con motivo y auditoría).
--   8. reparto_del_dia() y el aviso por WhatsApp muestran canal, medio y si falta cobrar.
-- =====================================================================

-- 1. Permiso para registrar pedidos fuera de la página
insert into public.permisos (codigo, modulo, descripcion)
values ('pedidos.registrar', 'Pedidos', 'Registrar pedidos fuera de la página (WhatsApp, llamada, presencial) y su cobro')
on conflict (codigo) do update set descripcion = excluded.descripcion;
insert into public.rol_permisos (rol_id, permiso) values ('chofer', 'pedidos.registrar')
on conflict do nothing;

-- 2. Columnas del pedido
alter table public.pedidos
  add column if not exists canal            text not null default 'web',
  add column if not exists metodo_pago      text,
  add column if not exists cobro_estado     text,
  add column if not exists cobrado_at       timestamptz,
  add column if not exists cobrado_por      uuid references public.perfiles(id) on delete set null,
  add column if not exists descuento_manual integer not null default 0,
  add column if not exists descuento_motivo text,
  add column if not exists creado_por       uuid references public.perfiles(id) on delete set null;

alter table public.pedidos alter column perfil_id drop not null;

do $chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'pedidos_canal_check') then
    alter table public.pedidos add constraint pedidos_canal_check
      check (canal in ('web', 'whatsapp', 'llamada', 'presencial', 'otro'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pedidos_metodo_pago_check') then
    alter table public.pedidos add constraint pedidos_metodo_pago_check
      check (metodo_pago is null or metodo_pago in ('mercado_pago', 'efectivo', 'tarjeta', 'transferencia'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pedidos_cobro_estado_check') then
    alter table public.pedidos add constraint pedidos_cobro_estado_check
      check (cobro_estado is null or cobro_estado in ('pagado', 'por_cobrar'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pedidos_descuento_manual_check') then
    alter table public.pedidos add constraint pedidos_descuento_manual_check
      check (descuento_manual >= 0 and (descuento_manual = 0 or length(coalesce(descuento_motivo, '')) between 3 and 200));
  end if;
  -- La web siempre tiene perfil; un pedido fuera de la página siempre tiene medio y estado de cobro
  if not exists (select 1 from pg_constraint where conname = 'pedidos_perfil_o_fuera_pagina') then
    alter table public.pedidos add constraint pedidos_perfil_o_fuera_pagina
      check (perfil_id is not null or canal <> 'web');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pedidos_cobro_fuera_pagina') then
    alter table public.pedidos add constraint pedidos_cobro_fuera_pagina
      check (canal = 'web' or (metodo_pago in ('efectivo', 'tarjeta', 'transferencia') and cobro_estado is not null));
  end if;
end;
$chk$;

create index if not exists idx_pedidos_fuera_pagina on public.pedidos (fecha_entrega) where canal <> 'web';

comment on column public.pedidos.canal is 'Origen del pedido: web (tienda) o fuera de la página: whatsapp, llamada, presencial, otro (migración 21).';
comment on column public.pedidos.metodo_pago is 'Pedidos fuera de la página: efectivo, tarjeta (presencial) o transferencia. En la web es Mercado Pago.';
comment on column public.pedidos.cobro_estado is 'Pedidos fuera de la página: pagado o por_cobrar (se cobra al entregar).';
comment on column public.pedidos.descuento_manual is 'Descuento aplicado en el panel a un pedido fuera de la página (con motivo).';

-- 3. Dirección sin cuenta (solo pedidos fuera de la página; la inserta registrar_pedido_manual)
alter table public.direcciones alter column perfil_id drop not null;

-- 4. Opciones para el formulario: catálogo con precio vigente y comunas con despacho
create or replace function public.opciones_pedido_manual()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.tiene_permiso('pedidos.registrar') then
    raise exception 'No tienes permiso para registrar pedidos.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'productos', (select coalesce(jsonb_agg(jsonb_build_object(
                     'variante_id', vp.id, 'producto', pr.nombre,
                     'variante', nullif(vp.nombre, 'Estándar'), 'precio', pv.precio)
                   order by pr.nombre, vp.nombre), '[]'::jsonb)
                    from public.variantes_producto vp
                    join public.productos pr on pr.id = vp.producto_id
                    join public.precios_variante pv on pv.variante_id = vp.id and pv.nivel_precio_id = 1
                   where vp.activo and pr.activo),
    'comunas', (select coalesce(jsonb_agg(jsonb_build_object('comuna', c.comuna, 'costo_despacho', z.costo_despacho)
                  order by c.comuna), '[]'::jsonb)
                  from public.comunas_cobertura c join public.zonas_despacho z on z.id = c.zona_id
                 where c.activo and z.activo),
    'envio_gratis_minimo', (select nullif(valor, '')::int from public.parametros where clave = 'envio_gratis_minimo'));
end;
$$;

-- 5. Registrar un pedido fuera de la página
--   p_cliente   { canal, nombre, telefono, email? }
--   p_direccion { calle, numero?, depto?, comuna, referencia? }
--   p_entrega   { fecha? }  (hoy por defecto; de hoy a 45 días)
--   p_items     [ { variante_id, cantidad } ]
--   p_pago      { metodo: efectivo|tarjeta|transferencia, estado: pagado|por_cobrar }
--   p_ajuste    { descuento?, motivo? }
--   p_documento { tipo: boleta|factura, rut?, razon_social?, giro? }
create or replace function public.registrar_pedido_manual(
  p_cliente jsonb, p_direccion jsonb, p_items jsonb, p_pago jsonb,
  p_entrega jsonb default null, p_ajuste jsonb default null, p_documento jsonb default null, p_notas text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_hoy date := (now() at time zone 'America/Santiago')::date;
  v_canal text; v_nombre text; v_tel text; v_email text; v_fecha date;
  v_metodo text; v_cobro text; v_desc integer := 0; v_motivo text;
  v_tipo_doc public.tipo_dte := 'boleta'; v_rut text; v_razon text; v_giro text;
  v_comuna text; v_zona public.zonas_despacho%rowtype; v_dir_id uuid;
  v_pedido_id uuid; v_numero bigint; v_subtotal integer := 0; v_despacho integer; v_gratis integer; v_total integer;
  v_sobreventa boolean := false;
  r record; v record;
begin
  if not public.tiene_permiso('pedidos.registrar') then
    raise exception 'No tienes permiso para registrar pedidos.' using errcode = '42501';
  end if;

  -- Canal y cliente
  v_canal := lower(coalesce(p_cliente->>'canal', ''));
  if v_canal not in ('whatsapp', 'llamada', 'presencial', 'otro') then
    raise exception 'Indica cómo llegó el pedido (WhatsApp, llamada, presencial u otro).';
  end if;
  v_nombre := left(nullif(trim(p_cliente->>'nombre'), ''), 80);
  v_tel    := public.normalizar_telefono_cl(p_cliente->>'telefono');
  v_email  := lower(left(nullif(trim(p_cliente->>'email'), ''), 120));
  if v_nombre is null then raise exception 'Ingresa el nombre del cliente.'; end if;
  if v_tel is null then raise exception 'Ingresa un celular válido del cliente (ej: 9 1234 5678).'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'El correo del cliente no es válido (puedes dejarlo vacío).';
  end if;

  -- Fecha de entrega: desde hoy y hasta 45 días (el chofer decide el día)
  if nullif(p_entrega->>'fecha', '') is not null then
    begin v_fecha := (p_entrega->>'fecha')::date;
    exception when others then raise exception 'La fecha de entrega no es válida.'; end;
    if v_fecha < v_hoy or v_fecha > v_hoy + 45 then
      raise exception 'La fecha de entrega debe ser desde hoy y hasta 45 días.';
    end if;
  else
    v_fecha := v_hoy;
  end if;

  -- Cobro
  v_metodo := lower(coalesce(p_pago->>'metodo', ''));
  v_cobro  := lower(coalesce(p_pago->>'estado', ''));
  if v_metodo not in ('efectivo', 'tarjeta', 'transferencia') then
    raise exception 'Indica el medio de pago: efectivo, tarjeta o transferencia.';
  end if;
  if v_cobro not in ('pagado', 'por_cobrar') then
    raise exception 'Indica si el pedido ya está pagado o se cobra al entregar.';
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

  -- Ítems
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto.';
  end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Demasiados productos en un solo pedido.'; end if;

  -- Dirección y zona (solo comunas con cobertura)
  select c.comuna into v_comuna
    from public.comunas_cobertura c join public.zonas_despacho z on z.id = c.zona_id
   where lower(c.comuna) = lower(trim(coalesce(p_direccion->>'comuna', ''))) and c.activo and z.activo;
  if v_comuna is null then raise exception 'Elige una comuna con despacho.'; end if;
  select z.* into v_zona from public.comunas_cobertura c join public.zonas_despacho z on z.id = c.zona_id
   where c.comuna = v_comuna;
  if coalesce(trim(p_direccion->>'calle'), '') = '' then raise exception 'Falta la calle de la dirección.'; end if;

  insert into public.direcciones (perfil_id, zona_id, calle, numero, depto, comuna, referencia)
  values (null, v_zona.id,
          left(trim(p_direccion->>'calle'), 120),
          left(nullif(trim(p_direccion->>'numero'), ''), 20),
          left(nullif(trim(p_direccion->>'depto'), ''), 40),
          v_comuna,
          left(nullif(trim(p_direccion->>'referencia'), ''), 200))
  returning id into v_dir_id;

  -- Pedido: nace "En preparación" (no pasa por Mercado Pago ni por el Club)
  insert into public.pedidos (perfil_id, direccion_id, zona_id, nivel_precio_id, estado, notas,
                              contacto_nombre, contacto_telefono, contacto_email, fecha_entrega,
                              tipo_documento, doc_rut, doc_razon_social, doc_giro,
                              canal, metodo_pago, cobro_estado, cobrado_at, cobrado_por, creado_por)
  values (null, v_dir_id, v_zona.id, 1, 'en_preparacion', left(nullif(trim(p_notas), ''), 500),
          v_nombre, v_tel, v_email, v_fecha,
          v_tipo_doc, v_rut, v_razon, v_giro,
          v_canal, v_metodo, v_cobro,
          case when v_cobro = 'pagado' then now() end, case when v_cobro = 'pagado' then v_uid end, v_uid)
  returning id, numero into v_pedido_id, v_numero;

  -- Detalle con el precio SIEMPRE desde la base (precio de venta vigente)
  for r in
    select (e->>'variante_id')::uuid as variante_id, sum((e->>'cantidad')::int) as cantidad
      from jsonb_array_elements(p_items) e group by 1
  loop
    if r.variante_id is null or r.cantidad is null or r.cantidad < 1 or r.cantidad > 200 then
      raise exception 'Cantidad inválida en un producto.';
    end if;
    select vp.id, vp.nombre, vp.controla_stock, vp.stock, pv.precio into v
      from public.variantes_producto vp
      join public.productos p on p.id = vp.producto_id
      left join public.precios_variante pv on pv.variante_id = vp.id and pv.nivel_precio_id = 1
     where vp.id = r.variante_id and vp.activo and p.activo
       for update of vp;
    if not found then raise exception 'Un producto ya no está disponible.'; end if;
    if v.precio is null then raise exception 'El producto % no tiene precio configurado.', v.nombre; end if;
    if v.controla_stock and v.stock < r.cantidad then v_sobreventa := true; end if;
    insert into public.detalle_pedido (pedido_id, variante_id, cantidad, precio_unitario, subtotal)
    values (v_pedido_id, v.id, r.cantidad, v.precio, v.precio * r.cantidad);
    v_subtotal := v_subtotal + v.precio * r.cantidad;
  end loop;

  -- Despacho (mismas reglas que la web: gratis desde el mínimo)
  v_despacho := v_zona.costo_despacho;
  select nullif(valor, '')::int into v_gratis from public.parametros where clave = 'envio_gratis_minimo';
  if v_despacho > 0 and v_gratis is not null and v_subtotal >= v_gratis then v_despacho := 0; end if;

  -- Descuento manual (con motivo)
  if nullif(p_ajuste->>'descuento', '') is not null then
    begin v_desc := (p_ajuste->>'descuento')::int;
    exception when others then raise exception 'El descuento no es válido.'; end;
  end if;
  v_motivo := left(nullif(trim(p_ajuste->>'motivo'), ''), 200);
  if v_desc < 0 or v_desc > v_subtotal + v_despacho then
    raise exception 'El descuento no puede ser negativo ni mayor que el total.';
  end if;
  if v_desc > 0 and length(coalesce(v_motivo, '')) < 3 then
    raise exception 'Indica el motivo del descuento.';
  end if;
  if v_desc = 0 then v_motivo := null; end if;
  v_total := v_subtotal + v_despacho - v_desc;

  update public.pedidos
     set subtotal = v_subtotal, costo_despacho = v_despacho, descuento_manual = v_desc,
         descuento_motivo = v_motivo, total = v_total, sobreventa = v_sobreventa
   where id = v_pedido_id;

  -- Stock: se descuenta al registrarlo (como un pedido web al confirmarse el pago); nunca frena la venta
  update public.variantes_producto vp
     set stock = greatest(vp.stock - d.cantidad, 0)
    from public.detalle_pedido d
   where d.pedido_id = v_pedido_id and vp.id = d.variante_id and vp.controla_stock;

  update public.historial_pedido
     set nota = 'Pedido fuera de la página (' || v_canal || '), ' ||
                case v_cobro when 'pagado' then 'pagado con ' || v_metodo else 'por cobrar en ' || v_metodo end
   where pedido_id = v_pedido_id and nota is null;

  return jsonb_build_object('ok', true, 'id', v_pedido_id, 'numero', v_numero, 'estado', 'en_preparacion',
                            'subtotal', v_subtotal, 'costo_despacho', v_despacho, 'descuento', v_desc,
                            'total', v_total, 'fecha_entrega', v_fecha, 'sobreventa', v_sobreventa);
end;
$$;

-- 6. Registrar el cobro de un pedido fuera de la página (al entregar)
create or replace function public.cobrar_pedido(p_pedido uuid, p_metodo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_p public.pedidos%rowtype; v_metodo text;
begin
  if not (public.tiene_permiso('pedidos.registrar') or public.tiene_permiso('pedidos.repartir')) then
    raise exception 'No tienes permiso para registrar cobros.' using errcode = '42501';
  end if;
  select * into v_p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido no encontrado.'; end if;
  if v_p.canal = 'web' then raise exception 'Los pedidos de la web se pagan con Mercado Pago.'; end if;
  if v_p.estado = 'cancelado' then raise exception 'El pedido está cancelado.'; end if;
  if v_p.cobro_estado = 'pagado' then
    return jsonb_build_object('ok', true, 'ya_cobrado', true, 'numero', v_p.numero, 'metodo', v_p.metodo_pago);
  end if;
  v_metodo := lower(coalesce(nullif(p_metodo, ''), v_p.metodo_pago));
  if v_metodo not in ('efectivo', 'tarjeta', 'transferencia') then
    raise exception 'Medio de pago no válido.';
  end if;
  update public.pedidos
     set cobro_estado = 'pagado', metodo_pago = v_metodo, cobrado_at = now(), cobrado_por = auth.uid()
   where id = p_pedido;
  return jsonb_build_object('ok', true, 'ya_cobrado', false, 'numero', v_p.numero, 'metodo', v_metodo, 'total', v_p.total);
end;
$$;

-- 7. Corregir el descuento (solo admin: pedidos.gestionar), con auditoría en el historial
create or replace function public.ajustar_pedido_manual(p_pedido uuid, p_descuento integer, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_p public.pedidos%rowtype; v_motivo text := left(nullif(trim(p_motivo), ''), 200); v_total integer;
begin
  if not public.tiene_permiso('pedidos.gestionar') then
    raise exception 'Solo el administrador puede corregir montos.' using errcode = '42501';
  end if;
  select * into v_p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido no encontrado.'; end if;
  if v_p.canal = 'web' then raise exception 'Los montos de un pedido web no se corrigen (se pagó con Mercado Pago).'; end if;
  if v_p.estado = 'cancelado' then raise exception 'El pedido está cancelado.'; end if;
  if exists (select 1 from public.documentos_tributarios where pedido_id = p_pedido and estado = 'emitido') then
    raise exception 'El pedido ya tiene boleta o factura: corrige el documento en Haulmer primero (nota de crédito).';
  end if;
  if p_descuento is null or p_descuento < 0 or p_descuento > v_p.subtotal + v_p.costo_despacho then
    raise exception 'El descuento no puede ser negativo ni mayor que el total.';
  end if;
  if length(coalesce(v_motivo, '')) < 3 then raise exception 'Indica el motivo de la corrección.'; end if;
  v_total := v_p.subtotal + v_p.costo_despacho - p_descuento;
  update public.pedidos
     set descuento_manual = p_descuento, descuento_motivo = case when p_descuento > 0 then v_motivo end, total = v_total
   where id = p_pedido;
  insert into public.historial_pedido (pedido_id, estado_anterior, estado_nuevo, cambiado_por, nota)
  values (p_pedido, v_p.estado, v_p.estado, auth.uid(),
          'Monto corregido: total $' || v_p.total || ' → $' || v_total || ' (' || v_motivo || ')');
  return jsonb_build_object('ok', true, 'numero', v_p.numero, 'total_anterior', v_p.total, 'total', v_total);
end;
$$;

-- 8a. Reparto del día: agrega canal, total, medio y estado del cobro (el resto igual que la migración 09)
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
             'atrasado', p.fecha_entrega < v_fecha and p.estado <> 'entregado',
             'nombre', p.contacto_nombre, 'telefono', p.contacto_telefono,
             'calle', d.calle, 'numero', d.numero, 'depto', d.depto, 'comuna', d.comuna, 'referencia', d.referencia,
             'notas', p.notas, 'es_canje', p.es_canje,
             'canal', p.canal, 'total', p.total,
             'metodo_pago', case when p.canal = 'web' then 'mercado_pago' else p.metodo_pago end,
             'cobro_estado', case when p.canal = 'web' then 'pagado' else p.cobro_estado end,
             'cobrado_at', p.cobrado_at,
             'entregado_at', (select max(h.created_at) from public.historial_pedido h
                               where h.pedido_id = p.id and h.estado_nuevo = 'entregado'),
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
        or (v_fecha = v_hoy and p.estado = 'entregado' and exists (
              select 1 from public.historial_pedido h
               where h.pedido_id = p.id and h.estado_nuevo = 'entregado'
                 and (h.created_at at time zone 'America/Santiago')::date = v_hoy))
  ) q;
  return v_res;
end;
$$;

-- 8b. Aviso por WhatsApp: en un pedido por cobrar dice "Total a pagar" y el medio (el resto igual que la 10)
create or replace function public._mensaje_reparto(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p public.pedidos%rowtype; v_items text; v_dir text; v_nom text; v_msg text; v_hora timestamptz; v_total text; v_medio text;
begin
  select * into v_p from public.pedidos where id = p_pedido;
  if not found then raise exception 'Pedido no encontrado.'; end if;

  select string_agg('- ' || d.cantidad || ' x ' || pr.nombre ||
                    case when vp.nombre is null or vp.nombre = 'Estándar' then '' else ' (' || vp.nombre || ')' end,
                    chr(10) order by pr.nombre, vp.nombre)
    into v_items
    from public.detalle_pedido d
    join public.variantes_producto vp on vp.id = d.variante_id
    join public.productos pr on pr.id = vp.producto_id
   where d.pedido_id = p_pedido;

  select di.calle || coalesce(' ' || nullif(di.numero, ''), '') || coalesce(', depto ' || nullif(di.depto, ''), '') || ', ' || di.comuna
    into v_dir from public.direcciones di where di.id = v_p.direccion_id;

  v_nom   := coalesce(nullif(split_part(trim(coalesce(v_p.contacto_nombre, '')), ' ', 1), ''), 'cliente');
  v_total := '$' || replace(to_char(v_p.total, 'FM999,999,999'), ',', '.');
  v_medio := case v_p.metodo_pago when 'efectivo' then 'efectivo' when 'tarjeta' then 'tarjeta'
                                  when 'transferencia' then 'transferencia' else null end;

  if v_p.estado = 'en_ruta' then
    v_msg := '*Befine: tu pedido #' || v_p.numero || ' va en camino*' || chr(10)
          || 'Hola, ' || v_nom || '. Tu pedido va en camino a ' || coalesce(v_dir, 'tu dirección') || '.' || chr(10)
          || case when v_p.canal <> 'web' and v_p.cobro_estado = 'por_cobrar'
                  then 'Total a pagar: ' || v_total || coalesce(' (' || v_medio || ')', '') || '.' || chr(10) else '' end
          || 'Te avisaremos cuando sea entregado.';
  elsif v_p.estado = 'entregado' then
    select max(h.created_at) into v_hora from public.historial_pedido h
     where h.pedido_id = p_pedido and h.estado_nuevo = 'entregado';
    v_msg := '*Befine: tu pedido #' || v_p.numero || ' fue entregado*' || chr(10)
          || 'Hola, ' || v_nom || '. Tu pedido fue entregado el '
          || to_char(coalesce(v_hora, now()) at time zone 'America/Santiago', 'DD/MM/YYYY "a las" HH24:MI') || ' h.' || chr(10)
          || 'Productos:' || chr(10)
          || coalesce(v_items, '') || chr(10)
          || 'Dirección: ' || coalesce(v_dir, '-') || chr(10)
          || case when v_p.es_canje then 'Premio del Club Befine canjeado.' || chr(10)
                  when v_p.canal <> 'web' and v_p.cobro_estado = 'por_cobrar'
                    then 'Total a pagar: ' || v_total || coalesce(' (' || v_medio || ')', '') || chr(10)
                  else 'Total pagado: ' || v_total || coalesce(' (' || v_medio || ')', '') || chr(10) end
          || '¡Gracias por preferir Befine!';
  else
    raise exception 'El aviso es solo para pedidos "En camino" o "Entregado".';
  end if;

  return jsonb_build_object('pedido_id', v_p.id, 'numero', v_p.numero, 'estado', v_p.estado,
                            'telefono', v_p.contacto_telefono,   -- 569XXXXXXXX
                            'mensaje', v_msg);
end;
$$;

-- Permisos de ejecución
revoke execute on function public.opciones_pedido_manual() from public, anon;
revoke execute on function public.registrar_pedido_manual(jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, text) from public, anon;
revoke execute on function public.cobrar_pedido(uuid, text) from public, anon;
revoke execute on function public.ajustar_pedido_manual(uuid, integer, text) from public, anon;
grant execute on function public.opciones_pedido_manual() to authenticated;
grant execute on function public.registrar_pedido_manual(jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, text) to authenticated;
grant execute on function public.cobrar_pedido(uuid, text) to authenticated;
grant execute on function public.ajustar_pedido_manual(uuid, integer, text) to authenticated;
revoke execute on function public._mensaje_reparto(uuid) from public, anon, authenticated;

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261125000021', '21_pedidos_fuera_pagina') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
