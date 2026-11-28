-- =====================================================================
-- Migración 23: ventas del chofer (planilla del día) y caja del admin
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  Requerimiento del dueño 27-nov-2026. El formulario "Pedido fuera de la página" es lento para
--            el chofer en la calle. Se reemplaza, para el chofer, por una planilla rápida: anota cada venta
--            (productos, cantidad, medio de pago, dirección y celular) en pocos toques y sigue con su trabajo
--            (no se envía nada al cliente). El admin ve la
--            caja del día, la semana o el mes: lo anotado por el chofer + los pedidos entregados (web y
--            fuera de la página), por medio de pago y el efectivo que le debe rendir cada chofer.
-- Requiere:  01 a 22 aplicadas.
-- Reversa:   20261127_23_ventas_reparto_reversa.sql
-- Prueba:    20261127_23_prueba_en_seco.sql (23 + prueba; T01..T15)
--
-- Decisiones del dueño:
--   * Registro aparte: una venta anotada NO crea pedido, boleta ni entra a la ruta; SÍ descuenta stock
--     y suma en la caja junto con los pedidos entregados.
--   * Precio del catálogo vigente (lo pone el servidor). Descuento opcional, siempre registrado.
--   * El chofer anula solo sus ventas del mismo día (errores de tipeo); el admin anula cualquiera.
--     Anular devuelve el stock. Nada se borra.
--   * La venta anotada NO envía mensajes al cliente. Los avisos de reparto ("En camino", "Entregado")
--     pasan a tono cordial de "usted".
--
-- Qué hace:
--   1. Permiso nuevo caja.ver (solo admin por defecto).
--   2. Tablas ventas_reparto y ventas_reparto_items (RLS: el chofer ve las suyas; caja.ver, todas;
--      se escriben SOLO por las funciones).
--   3. _saludo(): "Buenas tardes, Juan" según la hora de Santiago (avisos de reparto).
--   4. registrar_venta_reparto(), anular_venta_reparto(), cliente_reparto() (autocompleta por celular),
--      mis_ventas_reparto() (planilla del día del chofer) y caja_resumen() (admin: día, semana, mes).
--   5. _mensaje_reparto(): avisos de "En camino" y "Entregado" con tono cordial.
-- =====================================================================

-- 1. Permiso para ver la caja (ventas y dinero de todo el equipo)
insert into public.permisos (codigo, modulo, descripcion)
values ('caja.ver', 'Pedidos', 'Ver la caja: ventas del día, semana y mes y el efectivo que rinde cada chofer')
on conflict (codigo) do update set descripcion = excluded.descripcion;

-- 2. Tablas
create table if not exists public.ventas_reparto (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity,
  fecha          date not null default ((now() at time zone 'America/Santiago')::date),
  chofer_id      uuid not null references public.perfiles(id),
  metodo_pago    text not null check (metodo_pago in ('efectivo', 'transferencia', 'tarjeta')),
  subtotal       integer not null check (subtotal >= 0),
  descuento      integer not null default 0 check (descuento >= 0),
  total          integer not null check (total >= 0),
  direccion      text not null check (length(direccion) between 3 and 160),
  telefono       text check (telefono ~ '^569[0-9]{8}$'),
  trato          text check (trato in ('don', 'sra', 'srta')),
  nombre         text check (length(nombre) <= 60),
  nota           text check (length(nota) <= 200),
  created_at     timestamptz not null default now(),
  anulada_at     timestamptz,
  anulada_por    uuid references public.perfiles(id),
  anulada_motivo text check (length(anulada_motivo) <= 200),
  constraint ventas_reparto_total_ok check (total = subtotal - descuento)
);
create index if not exists ventas_reparto_fecha_idx on public.ventas_reparto (fecha, chofer_id);
create index if not exists ventas_reparto_tel_idx on public.ventas_reparto (telefono, created_at desc) where telefono is not null;

create table if not exists public.ventas_reparto_items (
  venta_id        uuid not null references public.ventas_reparto(id) on delete cascade,
  variante_id     uuid not null references public.variantes_producto(id),
  producto        text not null,
  variante        text,
  cantidad        integer not null check (cantidad between 1 and 200),
  precio_unitario integer not null check (precio_unitario >= 0),
  subtotal        integer not null check (subtotal >= 0),
  primary key (venta_id, variante_id)
);

alter table public.ventas_reparto enable row level security;
alter table public.ventas_reparto_items enable row level security;
drop policy if exists ventas_reparto_lectura on public.ventas_reparto;
create policy ventas_reparto_lectura on public.ventas_reparto for select to authenticated
  using (chofer_id = auth.uid() or public.tiene_permiso('caja.ver'));
drop policy if exists ventas_reparto_items_lectura on public.ventas_reparto_items;
create policy ventas_reparto_items_lectura on public.ventas_reparto_items for select to authenticated
  using (exists (select 1 from public.ventas_reparto v where v.id = venta_id
                  and (v.chofer_id = auth.uid() or public.tiene_permiso('caja.ver'))));
revoke all on public.ventas_reparto, public.ventas_reparto_items from anon;
revoke insert, update, delete on public.ventas_reparto, public.ventas_reparto_items from authenticated;
grant select on public.ventas_reparto, public.ventas_reparto_items to authenticated;

-- 3. Saludo cordial según la hora de Santiago: "Buenas tardes, Don Juan"
create or replace function public._saludo(p_trato text default null, p_nombre text default null)
returns text language sql stable set search_path = public as $$
  select case when h < 12 then 'Buenos días' when h < 20 then 'Buenas tardes' else 'Buenas noches' end
      || coalesce(', ' || nullif(trim(
           case when nullif(trim(coalesce(p_nombre, '')), '') is null then ''
                else coalesce(case lower(p_trato) when 'don' then 'Don ' when 'sra' then 'Sra. ' when 'srta' then 'Srta. ' end, '')
                     || initcap(split_part(trim(p_nombre), ' ', 1)) end), ''), '')
    from (select extract(hour from now() at time zone 'America/Santiago')::int as h) x;
$$;

-- 4a. Anotar una venta (chofer o admin)
--   p_items [ { variante_id, cantidad } ] · p_pago efectivo|transferencia|tarjeta · p_direccion texto
--   p_telefono opcional (9 1234 5678) · p_trato don|sra|srta opcional · p_nombre opcional
--   p_descuento opcional (pesos) · p_nota opcional
create or replace function public.registrar_venta_reparto(
  p_items jsonb, p_pago text, p_direccion text, p_telefono text default null, p_trato text default null,
  p_nombre text default null, p_descuento integer default 0, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_hoy date := (now() at time zone 'America/Santiago')::date;
  v_pago text := lower(trim(coalesce(p_pago, '')));
  v_dir text := left(regexp_replace(trim(coalesce(p_direccion, '')), '\s+', ' ', 'g'), 160);
  v_tel text; v_trato text := nullif(lower(trim(coalesce(p_trato, ''))), '');
  v_desc integer := coalesce(p_descuento, 0);
  v_id uuid; v_numero bigint; v_sub integer := 0; v_total integer; v_unidades integer := 0;
  r record; v record;
begin
  if not public.tiene_permiso('pedidos.registrar') then
    raise exception 'No tienes permiso para anotar ventas.' using errcode = '42501';
  end if;
  if v_pago not in ('efectivo', 'transferencia', 'tarjeta') then
    raise exception 'Elige cómo pagó: efectivo, transferencia o tarjeta.';
  end if;
  if length(v_dir) < 3 then raise exception 'Anota la dirección de la entrega.'; end if;
  if nullif(trim(coalesce(p_telefono, '')), '') is not null then
    v_tel := public.normalizar_telefono_cl(p_telefono);
    if v_tel is null then raise exception 'El celular debe tener 8 dígitos después del +56 9.'; end if;
  end if;
  if v_trato is not null and v_trato not in ('don', 'sra', 'srta') then v_trato := null; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto.';
  end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Demasiados productos en una sola venta.'; end if;
  -- Freno a errores o abusos: máximo 300 ventas por chofer al día
  if (select count(*) from public.ventas_reparto where chofer_id = v_uid and fecha = v_hoy) >= 300 then
    raise exception 'Llegaste al máximo de ventas anotadas por día. Avisa al administrador.';
  end if;

  insert into public.ventas_reparto (fecha, chofer_id, metodo_pago, subtotal, descuento, total, direccion,
                                     telefono, trato, nombre, nota)
  values (v_hoy, v_uid, v_pago, 0, 0, 0, v_dir, v_tel, v_trato,
          left(nullif(trim(coalesce(p_nombre, '')), ''), 60), left(nullif(trim(coalesce(p_nota, '')), ''), 200))
  returning id, numero into v_id, v_numero;

  -- Precio SIEMPRE desde la base (precio de venta vigente)
  for r in
    select (e->>'variante_id')::uuid as variante_id, sum((e->>'cantidad')::int) as cantidad
      from jsonb_array_elements(p_items) e
     where coalesce((e->>'cantidad')::int, 0) > 0
     group by 1
  loop
    if r.variante_id is null or r.cantidad > 200 then raise exception 'Cantidad inválida en un producto.'; end if;
    select vp.id, vp.nombre, pr.nombre as producto, vp.controla_stock, pv.precio into v
      from public.variantes_producto vp
      join public.productos pr on pr.id = vp.producto_id
      left join public.precios_variante pv on pv.variante_id = vp.id and pv.nivel_precio_id = 1
     where vp.id = r.variante_id and vp.activo and pr.activo
       for update of vp;
    if not found then raise exception 'Un producto ya no está disponible.'; end if;
    if v.precio is null then raise exception 'El producto % no tiene precio configurado.', v.producto; end if;
    insert into public.ventas_reparto_items (venta_id, variante_id, producto, variante, cantidad, precio_unitario, subtotal)
    values (v_id, v.id, v.producto, nullif(v.nombre, 'Estándar'), r.cantidad, v.precio, v.precio * r.cantidad);
    v_sub := v_sub + v.precio * r.cantidad;
    v_unidades := v_unidades + r.cantidad;
    -- Stock: se descuenta al anotar (nunca frena la venta)
    if v.controla_stock then
      update public.variantes_producto set stock = greatest(stock - r.cantidad, 0) where id = v.id;
    end if;
  end loop;
  if v_unidades = 0 then raise exception 'Agrega al menos un producto.'; end if;

  if v_desc < 0 or v_desc > v_sub then raise exception 'El descuento no puede ser negativo ni mayor que la venta.'; end if;
  v_total := v_sub - v_desc;
  update public.ventas_reparto set subtotal = v_sub, descuento = v_desc, total = v_total where id = v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'numero', v_numero, 'subtotal', v_sub, 'descuento', v_desc,
                            'total', v_total, 'unidades', v_unidades, 'metodo_pago', v_pago);
end;
$$;

-- 4b. Anular una venta (devuelve el stock). Chofer: solo las suyas y del mismo día. Admin/caja: cualquiera.
create or replace function public.anular_venta_reparto(p_venta uuid, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.ventas_reparto%rowtype; v_hoy date := (now() at time zone 'America/Santiago')::date;
begin
  select * into v from public.ventas_reparto where id = p_venta for update;
  if not found then raise exception 'Venta no encontrada.'; end if;
  if not (public.es_admin() or public.tiene_permiso('caja.ver')) then
    if not public.tiene_permiso('pedidos.registrar') or v.chofer_id <> auth.uid() then
      raise exception 'No puedes anular esta venta.' using errcode = '42501';
    end if;
    if v.fecha <> v_hoy then
      raise exception 'Solo puedes anular ventas de hoy. Pide al administrador que la corrija.' using errcode = '42501';
    end if;
  end if;
  if v.anulada_at is not null then return jsonb_build_object('ok', true, 'numero', v.numero, 'repetido', true); end if;
  update public.ventas_reparto
     set anulada_at = now(), anulada_por = auth.uid(), anulada_motivo = left(nullif(trim(coalesce(p_motivo, '')), ''), 200)
   where id = p_venta;
  update public.variantes_producto vp set stock = vp.stock + i.cantidad
    from public.ventas_reparto_items i
   where i.venta_id = p_venta and vp.id = i.variante_id and vp.controla_stock;
  return jsonb_build_object('ok', true, 'numero', v.numero);
end;
$$;

-- 4c. Autocompletar por celular: dirección, trato y nombre de la última venta anotada con ese número exacto
create or replace function public.cliente_reparto(p_telefono text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tel text := public.normalizar_telefono_cl(p_telefono); r record;
begin
  if not public.tiene_permiso('pedidos.registrar') then
    raise exception 'No tienes permiso.' using errcode = '42501';
  end if;
  if v_tel is null then return null; end if;
  select direccion, trato, nombre into r from public.ventas_reparto
   where telefono = v_tel and anulada_at is null order by created_at desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object('direccion', r.direccion, 'trato', r.trato, 'nombre', r.nombre);
end;
$$;

-- Lista de ventas (con ítems) de un rango, para la planilla del chofer y la caja del admin
create or replace function public._ventas_lista(p_desde date, p_hasta date, p_chofer uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'numero', v.numero, 'fecha', v.fecha, 'hora', to_char(v.created_at at time zone 'America/Santiago', 'HH24:MI'),
           'chofer_id', v.chofer_id, 'chofer', coalesce(pf.nombre, 'Equipo'),
           'metodo_pago', v.metodo_pago, 'subtotal', v.subtotal, 'descuento', v.descuento, 'total', v.total,
           'direccion', v.direccion, 'telefono', v.telefono, 'trato', v.trato, 'nombre', v.nombre, 'nota', v.nota,
           'anulada', v.anulada_at is not null, 'anulada_motivo', v.anulada_motivo,
           'items', (select coalesce(jsonb_agg(jsonb_build_object('producto', i.producto, 'variante', i.variante,
                       'cantidad', i.cantidad, 'precio_unitario', i.precio_unitario, 'subtotal', i.subtotal)
                       order by i.producto), '[]'::jsonb) from public.ventas_reparto_items i where i.venta_id = v.id))
         order by v.created_at desc), '[]'::jsonb)
    from public.ventas_reparto v left join public.perfiles pf on pf.id = v.chofer_id
   where v.fecha between p_desde and p_hasta and (p_chofer is null or v.chofer_id = p_chofer);
$$;

-- Pedidos ENTREGADOS en un rango (día de la entrega, hora de Santiago), con quién los entregó
create or replace function public._entregas_rango(p_desde date, p_hasta date, p_chofer uuid)
returns table (pedido_id uuid, numero bigint, fecha date, chofer_id uuid, canal text, metodo text, total integer, unidades integer)
language sql stable security definer set search_path = public as $$
  select p.id, p.numero, (h.at at time zone 'America/Santiago')::date, h.por, p.canal,
         case when p.canal = 'web' then 'mercado_pago' else coalesce(p.metodo_pago, 'efectivo') end,
         p.total, (select coalesce(sum(d.cantidad), 0)::int from public.detalle_pedido d where d.pedido_id = p.id)
    from public.pedidos p
    join lateral (select max(x.created_at) as at,
                         (array_agg(x.cambiado_por order by x.created_at desc))[1] as por
                    from public.historial_pedido x where x.pedido_id = p.id and x.estado_nuevo = 'entregado') h on h.at is not null
   where p.estado = 'entregado'
     and (h.at at time zone 'America/Santiago')::date between p_desde and p_hasta
     and (p_chofer is null or h.por = p_chofer);
$$;
revoke execute on function public._ventas_lista(date, date, uuid), public._entregas_rango(date, date, uuid)
  from public, anon, authenticated;

-- 4d. Planilla del día del chofer: sus ventas anotadas + las entregas de ruta que marcó
create or replace function public.mis_ventas_reparto(p_fecha date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_f date := coalesce(p_fecha, (now() at time zone 'America/Santiago')::date);
begin
  if not public.tiene_permiso('pedidos.registrar') then
    raise exception 'No tienes permiso.' using errcode = '42501';
  end if;
  if v_f < (now() at time zone 'America/Santiago')::date - 62 then
    raise exception 'La planilla muestra hasta 2 meses atrás. Pide el detalle al administrador.';
  end if;
  return jsonb_build_object(
    'fecha', v_f,
    'ventas', public._ventas_lista(v_f, v_f, v_uid),
    'entregas', (select jsonb_build_object('cantidad', count(*), 'total', coalesce(sum(total), 0),
                   'efectivo', coalesce(sum(total) filter (where metodo = 'efectivo'), 0),
                   'transferencia', coalesce(sum(total) filter (where metodo = 'transferencia'), 0),
                   'tarjeta', coalesce(sum(total) filter (where metodo = 'tarjeta'), 0),
                   'mercado_pago', coalesce(sum(total) filter (where metodo = 'mercado_pago'), 0))
                   from public._entregas_rango(v_f, v_f, v_uid)));
end;
$$;

-- 4e. Caja del admin: ventas anotadas + pedidos entregados, por día, por chofer y por medio de pago
create or replace function public.caja_resumen(p_desde date, p_hasta date, p_chofer uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.tiene_permiso('caja.ver') then
    raise exception 'No tienes permiso para ver la caja.' using errcode = '42501';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then raise exception 'Elige un rango de fechas válido.'; end if;
  if p_hasta - p_desde > 370 then raise exception 'El rango máximo es de un año.'; end if;
  return (
    with mov as (   -- cada venta anotada y cada pedido entregado como un "movimiento" de caja
      select 'venta'::text as origen, v.fecha, v.chofer_id, v.metodo_pago as metodo, v.total,
             (select coalesce(sum(i.cantidad), 0)::int from public.ventas_reparto_items i where i.venta_id = v.id) as unidades
        from public.ventas_reparto v
       where v.anulada_at is null and v.fecha between p_desde and p_hasta and (p_chofer is null or v.chofer_id = p_chofer)
      union all
      select case when e.canal = 'web' then 'web' else 'fuera_pagina' end, e.fecha, e.chofer_id, e.metodo, e.total, e.unidades
        from public._entregas_rango(p_desde, p_hasta, p_chofer) e
    )
    select jsonb_build_object(
      'desde', p_desde, 'hasta', p_hasta,
      'totales', (select jsonb_build_object(
          'total', coalesce(sum(total), 0), 'movimientos', count(*), 'unidades', coalesce(sum(unidades), 0),
          'efectivo', coalesce(sum(total) filter (where metodo = 'efectivo'), 0),
          'transferencia', coalesce(sum(total) filter (where metodo = 'transferencia'), 0),
          'tarjeta', coalesce(sum(total) filter (where metodo = 'tarjeta'), 0),
          'mercado_pago', coalesce(sum(total) filter (where metodo = 'mercado_pago'), 0),
          'ventas_chofer', coalesce(sum(total) filter (where origen = 'venta'), 0),
          'n_ventas_chofer', count(*) filter (where origen = 'venta'),
          'pedidos_web', coalesce(sum(total) filter (where origen = 'web'), 0),
          'n_pedidos_web', count(*) filter (where origen = 'web'),
          'pedidos_fuera', coalesce(sum(total) filter (where origen = 'fuera_pagina'), 0),
          'n_pedidos_fuera', count(*) filter (where origen = 'fuera_pagina')) from mov),
      'por_dia', (select coalesce(jsonb_agg(d order by d->>'fecha'), '[]'::jsonb) from (
          select jsonb_build_object('fecha', fecha, 'total', sum(total), 'movimientos', count(*), 'unidades', sum(unidades),
                   'efectivo', coalesce(sum(total) filter (where metodo = 'efectivo'), 0),
                   'ventas_chofer', coalesce(sum(total) filter (where origen = 'venta'), 0),
                   'pedidos', coalesce(sum(total) filter (where origen <> 'venta'), 0)) d
            from mov group by fecha) x),
      'por_chofer', (select coalesce(jsonb_agg(c order by (c->>'total')::int desc), '[]'::jsonb) from (
          select jsonb_build_object('chofer_id', m.chofer_id, 'chofer', coalesce(pf.nombre, 'Sin registrar'),
                   'total', sum(m.total), 'movimientos', count(*), 'unidades', sum(m.unidades),
                   'efectivo', coalesce(sum(m.total) filter (where m.metodo = 'efectivo'), 0),
                   'transferencia', coalesce(sum(m.total) filter (where m.metodo = 'transferencia'), 0),
                   'tarjeta', coalesce(sum(m.total) filter (where m.metodo = 'tarjeta'), 0),
                   'mercado_pago', coalesce(sum(m.total) filter (where m.metodo = 'mercado_pago'), 0)) c
            from mov m left join public.perfiles pf on pf.id = m.chofer_id group by m.chofer_id, pf.nombre) y),
      'choferes', (select coalesce(jsonb_agg(jsonb_build_object('id', pf.id, 'nombre', pf.nombre) order by pf.nombre), '[]'::jsonb)
                     from public.perfiles pf
                    where pf.activo and (pf.rol = 'admin' or exists (select 1 from public.rol_permisos rp
                                          where rp.rol_id = pf.rol and rp.permiso in ('pedidos.registrar', 'pedidos.repartir')))),
      'ventas', public._ventas_lista(p_desde, p_hasta, p_chofer))
  );
end;
$$;

revoke execute on function public.registrar_venta_reparto(jsonb, text, text, text, text, text, integer, text),
  public.anular_venta_reparto(uuid, text), public.cliente_reparto(text), public.mis_ventas_reparto(date),
  public.caja_resumen(date, date, uuid) from public, anon;
grant execute on function public.registrar_venta_reparto(jsonb, text, text, text, text, text, integer, text),
  public.anular_venta_reparto(uuid, text), public.cliente_reparto(text), public.mis_ventas_reparto(date),
  public.caja_resumen(date, date, uuid) to authenticated;

-- 5. Avisos de reparto por WhatsApp con tono cordial (de "usted")
create or replace function public._mensaje_reparto(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p public.pedidos%rowtype; v_items text; v_dir text; v_msg text; v_hora timestamptz; v_total text; v_medio text;
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

  v_total := '$' || replace(to_char(v_p.total, 'FM999,999,999'), ',', '.');
  v_medio := case v_p.metodo_pago when 'efectivo' then 'efectivo' when 'tarjeta' then 'tarjeta'
                                  when 'transferencia' then 'transferencia' else null end;

  if v_p.estado = 'en_ruta' then
    v_msg := '*Agua Purificada Befine · Pedido #' || v_p.numero || '*' || chr(10)
          || public._saludo(null, v_p.contacto_nombre) || '.' || chr(10)
          || 'Le informamos que su pedido va en camino a ' || coalesce(v_dir, 'su dirección') || '.' || chr(10)
          || case when v_p.canal <> 'web' and v_p.cobro_estado = 'por_cobrar'
                  then 'Total a pagar: ' || v_total || coalesce(' (' || v_medio || ')', '') || '.' || chr(10) else '' end
          || 'Le avisaremos apenas sea entregado. Muchas gracias.';
  elsif v_p.estado = 'entregado' then
    select max(h.created_at) into v_hora from public.historial_pedido h
     where h.pedido_id = p_pedido and h.estado_nuevo = 'entregado';
    v_msg := '*Agua Purificada Befine · Pedido #' || v_p.numero || ' entregado*' || chr(10)
          || public._saludo(null, v_p.contacto_nombre) || '.' || chr(10)
          || 'Le confirmamos que su pedido fue entregado el '
          || to_char(coalesce(v_hora, now()) at time zone 'America/Santiago', 'DD/MM/YYYY "a las" HH24:MI') || ' h.' || chr(10)
          || 'Productos:' || chr(10)
          || coalesce(v_items, '') || chr(10)
          || 'Dirección: ' || coalesce(v_dir, '-') || chr(10)
          || case when v_p.es_canje then 'Premio del Club Befine canjeado.' || chr(10)
                  when v_p.canal <> 'web' and v_p.cobro_estado = 'por_cobrar'
                    then 'Total a pagar: ' || v_total || coalesce(' (' || v_medio || ')', '') || chr(10)
                  else 'Total pagado: ' || v_total || coalesce(' (' || v_medio || ')', '') || chr(10) end
          || 'Muchas gracias por su preferencia. Quedamos atentos a su próximo pedido.';
  else
    raise exception 'El aviso es solo para pedidos "En camino" o "Entregado".';
  end if;

  return jsonb_build_object('pedido_id', v_p.id, 'numero', v_p.numero, 'estado', v_p.estado,
                            'telefono', v_p.contacto_telefono,   -- 569XXXXXXXX
                            'mensaje', v_msg);
end;
$$;

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261127000023', '23_ventas_reparto') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
