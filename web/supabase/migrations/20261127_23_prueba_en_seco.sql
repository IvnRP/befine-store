-- PRUEBA EN SECO de la migración 23 (ventas del chofer y caja) — Befine Store
-- Requiere: 01 a 22 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261127_23_ventas_reparto.sql y (2) este archivo,
-- sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace (no queda ninguna venta,
-- pedido, stock ni usuario de prueba).
-- Muestra T01..T15. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  adm uuid := gen_random_uuid();   -- dueño (admin)
  cho uuid := gen_random_uuid();   -- chofer 1
  ch2 uuid := gen_random_uuid();   -- chofer 2
  cli uuid := gen_random_uuid();   -- cliente de la web
  vr uuid; vb uuid; pr int; pb int; st int; j jsonb; c jsonb; v1 uuid; v2 uuid; v3 uuid; pm uuid; n int; msg text; t text;
  hoy date := (now() at time zone 'America/Santiago')::date;
  rec2 jsonb; res text := 'RESULTADOS';
begin
  select id into vr from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  select id into vb from public.variantes_producto where sku = 'BEF-BID-20';
  select precio into pr from public.precios_variante where variante_id = vr and nivel_precio_id = 1;
  select precio into pb from public.precios_variante where variante_id = vb and nivel_precio_id = 1;
  update public.variantes_producto set controla_stock = true, stock = 50 where id in (vr, vb);
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (adm, 'admin23@correo.cl', '{"nombre":"Iván"}', false), (cho, 'chofer23@correo.cl', '{"nombre":"Pedro"}', false),
    (ch2, 'chofer23b@correo.cl', '{"nombre":"Luis"}', false), (cli, 'cli23@correo.cl', '{"nombre":"Cli"}', false);
  update public.perfiles set rol = 'admin' where id = adm;
  update public.perfiles set rol = 'chofer' where id in (cho, ch2);
  rec2 := jsonb_build_array(jsonb_build_object('variante_id', vr, 'cantidad', 2, 'precio', 1));   -- el precio que mande el celular se ignora

  -- T01: el chofer anota una venta en efectivo: precio del catálogo, stock descontado, celular normalizado
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  j := public.registrar_venta_reparto(rec2, 'efectivo', 'Los Tailandeses 1156, Quilicura', '9 2101 2101', 'don', 'juan pérez');
  v1 := (j->>'id')::uuid;
  perform set_config('role', 'none', true);
  select stock into st from public.variantes_producto where id = vr;
  res := res || chr(10) || 'T01 venta anotada: precio del catálogo, stock descontado y celular +569: ' ||
    case when (j->>'total')::int = 2 * pr and st = 48
              and exists (select 1 from public.ventas_reparto where id = v1 and chofer_id = cho and fecha = hoy and metodo_pago = 'efectivo'
                           and telefono = '56921012101' and trato = 'don')
              and exists (select 1 from public.ventas_reparto_items where venta_id = v1 and precio_unitario = pr and cantidad = 2)
         then 'OK' else 'FALLA ' || j::text || ' stock=' || st end;

  -- T02: anotar no arma ni envía mensajes al cliente (solo registra)
  res := res || chr(10) || 'T02 la venta solo se registra: no arma mensajes para el cliente: ' ||
    case when not (j ? 'mensaje') and to_regprocedure('public._mensaje_venta(uuid)') is null
         then 'OK' else 'FALLA ' || j::text end;

  -- T03: validaciones (sin dirección, pago inválido, celular malo, sin productos, descuento mayor)
  perform set_config('role', 'authenticated', true);
  t := '';
  begin perform public.registrar_venta_reparto(rec2, 'efectivo', ' '); t := t || 'sin dirección pasó; '; exception when others then null; end;
  begin perform public.registrar_venta_reparto(rec2, 'cheque', 'Calle 1'); t := t || 'pago inválido pasó; '; exception when others then null; end;
  begin perform public.registrar_venta_reparto(rec2, 'efectivo', 'Calle 1', '123'); t := t || 'celular malo pasó; '; exception when others then null; end;
  begin perform public.registrar_venta_reparto('[]', 'efectivo', 'Calle 1'); t := t || 'sin productos pasó; '; exception when others then null; end;
  begin perform public.registrar_venta_reparto(jsonb_build_array(jsonb_build_object('variante_id', vr, 'cantidad', 0)), 'efectivo', 'Calle 1');
        t := t || 'cantidad 0 pasó; '; exception when others then null; end;
  begin perform public.registrar_venta_reparto(rec2, 'efectivo', 'Calle 1', null, null, null, 2 * pr + 1); t := t || 'descuento mayor pasó; ';
  exception when others then null; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T03 rechaza dirección vacía, pago inválido, celular malo, sin productos y descuento mayor: ' ||
    case when t = '' then 'OK' else 'FALLA ' || t end;

  -- T04: descuento registrado; transferencia; sin celular también se puede
  perform set_config('role', 'authenticated', true);
  j := public.registrar_venta_reparto(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), 'transferencia',
         'Pasaje 2 #45, Huechuraba', null, null, null, 490);
  v2 := (j->>'id')::uuid;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T04 descuento registrado y venta sin celular por transferencia: ' ||
    case when (j->>'total')::int = pb - 490 and (j->>'descuento')::int = 490
              and exists (select 1 from public.ventas_reparto where id = (j->>'id')::uuid and telefono is null)
         then 'OK' else 'FALLA ' || j::text end;

  -- T05: autocompletar por celular (número exacto, con o sin +56)
  perform set_config('role', 'authenticated', true);
  c := public.cliente_reparto('+56 9 2101 2101');
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T05 al escribir el celular se completan dirección, trato y nombre: ' ||
    case when c->>'direccion' = 'Los Tailandeses 1156, Quilicura' and c->>'trato' = 'don' and c->>'nombre' = 'juan pérez'
         then 'OK' else 'FALLA ' || coalesce(c::text, 'null') end;

  -- T06: un cliente no puede anotar, buscar ni ver la caja; el chofer no ve la caja
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  t := '';
  begin perform public.registrar_venta_reparto(rec2, 'efectivo', 'Calle 1'); t := t || 'cliente anotó; ';
  exception when others then if sqlstate <> '42501' then t := t || sqlerrm || '; '; end if; end;
  begin perform public.cliente_reparto('9 2101 2101'); t := t || 'cliente buscó; ';
  exception when others then if sqlstate <> '42501' then t := t || sqlerrm || '; '; end if; end;
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  begin perform public.caja_resumen(hoy, hoy); t := t || 'chofer vio la caja; ';
  exception when others then if sqlstate <> '42501' then t := t || sqlerrm || '; '; end if; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T06 cliente sin acceso; el chofer no ve la caja: ' || case when t = '' then 'OK' else 'FALLA ' || t end;

  -- T07: RLS: cada chofer ve solo sus ventas; nadie escribe directo en las tablas
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ch2, 'role', 'authenticated')::text, true);
  j := public.registrar_venta_reparto(jsonb_build_array(jsonb_build_object('variante_id', vr, 'cantidad', 1)), 'tarjeta', 'Av. Recoleta 100');
  v3 := (j->>'id')::uuid;
  select count(*) into n from public.ventas_reparto;                     -- ch2 solo ve la suya
  t := case when n = 1 then '' else 'ch2 ve ' || n || '; ' end;
  begin insert into public.ventas_reparto (chofer_id, metodo_pago, subtotal, total, direccion) values (ch2, 'efectivo', 0, 0, 'Calle 1');
        t := t || 'insert directo pasó; ';
  exception when others then null; end;
  begin update public.ventas_reparto set total = 1 where id = v3; get diagnostics n = row_count;
        if n > 0 then t := t || 'update directo pasó; '; end if;
  exception when others then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  select count(*) into n from public.ventas_reparto;
  if n > 0 then t := t || 'cliente ve ' || n || '; '; end if;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T07 cada chofer ve solo sus ventas y nadie las edita por fuera: ' || case when t = '' then 'OK' else 'FALLA ' || t end;

  -- T08: el chofer anula su venta de hoy: el stock vuelve y no se puede anular dos veces
  select stock into st from public.variantes_producto where id = vb;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  perform public.anular_venta_reparto(v2, 'Me equivoqué de producto');
  j := public.anular_venta_reparto(v2);
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T08 anular devuelve el stock y es idempotente: ' ||
    case when (select stock from public.variantes_producto where id = vb) = st + 1 and (j->>'repetido')::boolean
              and exists (select 1 from public.ventas_reparto where id = v2 and anulada_at is not null and anulada_por = cho)
         then 'OK' else 'FALLA' end;

  -- T09: el chofer no anula ventas de otro ni de días anteriores; el admin sí
  update public.ventas_reparto set fecha = hoy - 1 where id = v1;
  perform set_config('role', 'authenticated', true);
  t := '';
  begin perform public.anular_venta_reparto(v3); t := t || 'anuló la de otro; '; exception when others then null; end;
  begin perform public.anular_venta_reparto(v1); t := t || 'anuló la de ayer; '; exception when others then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  begin perform public.anular_venta_reparto(v1, 'Corrección del admin');
  exception when others then t := t || 'admin no pudo: ' || sqlerrm || '; '; end;
  perform set_config('role', 'none', true);
  update public.ventas_reparto set fecha = hoy where id = v1;
  res := res || chr(10) || 'T09 el chofer solo anula sus ventas de hoy; el admin cualquiera: ' || case when t = '' then 'OK' else 'FALLA ' || t end;

  -- Datos para la caja: 1 venta nueva de cho (efectivo) + 1 pedido fuera de la página entregado por cho (efectivo)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  perform public.registrar_venta_reparto(rec2, 'efectivo', 'Los Tailandeses 1156, Quilicura', '9 2101 2101');
  j := public.registrar_pedido_manual('{"canal":"whatsapp","nombre":"María Soto","telefono":"9 2103 2103"}',
         '{"calle":"Los Tailandeses","numero":"1200","comuna":"Quilicura"}',
         jsonb_build_array(jsonb_build_object('variante_id', vr, 'cantidad', 4)), '{"metodo":"efectivo","estado":"pagado"}');
  pm := (j->>'id')::uuid;
  perform public.marcar_reparto(pm, 'en_ruta');
  perform public.marcar_reparto(pm, 'entregado');

  -- T10: planilla del chofer: solo sus ventas del día y sus entregas de ruta
  c := public.mis_ventas_reparto();
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T10 planilla del día del chofer (sus ventas y sus entregas de ruta): ' ||
    case when jsonb_array_length(c->'ventas') = 3                                   -- v1 y v2 (anuladas, se muestran tachadas) + la nueva
              and (c->'entregas'->>'cantidad')::int = 1 and (c->'entregas'->>'efectivo')::int = (j->>'total')::int
              and not exists (select 1 from jsonb_array_elements(c->'ventas') e where (e->>'chofer_id')::uuid <> cho)
         then 'OK' else 'FALLA ' || c::text end;

  -- T11: caja del admin: ventas no anuladas + pedido entregado, por medio de pago y por chofer
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  c := public.caja_resumen(hoy, hoy);
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T11 caja de hoy: anotadas (sin anuladas) + entregados, por medio y por chofer: ' ||
    case when (c->'totales'->>'total')::int = 2 * pr + pr + (j->>'total')::int
              and (c->'totales'->>'efectivo')::int = 2 * pr + (j->>'total')::int
              and (c->'totales'->>'tarjeta')::int = pr
              and (c->'totales'->>'n_ventas_chofer')::int = 2 and (c->'totales'->>'n_pedidos_fuera')::int = 1
              and exists (select 1 from jsonb_array_elements(c->'por_chofer') x
                           where (x->>'chofer_id')::uuid = cho and (x->>'efectivo')::int = 2 * pr + (j->>'total')::int)
              and jsonb_array_length(c->'por_dia') = 1
         then 'OK' else 'FALLA ' || (c->'totales')::text end;

  -- T12: filtro por chofer y semana
  perform set_config('role', 'authenticated', true);
  c := public.caja_resumen(hoy - 6, hoy, ch2);
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T12 caja de la semana filtrada por un chofer: ' ||
    case when (c->'totales'->>'total')::int = pr and (c->'totales'->>'tarjeta')::int = pr
              and jsonb_array_length(c->'ventas') = 1
         then 'OK' else 'FALLA ' || (c->'totales')::text end;

  -- T13: rangos inválidos
  perform set_config('role', 'authenticated', true);
  t := '';
  begin perform public.caja_resumen(hoy, hoy - 1); t := t || 'rango al revés pasó; '; exception when others then null; end;
  begin perform public.caja_resumen(hoy - 400, hoy); t := t || 'más de un año pasó; '; exception when others then null; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T13 rechaza rangos al revés o de más de un año: ' || case when t = '' then 'OK' else 'FALLA ' || t end;

  -- T14: avisos de reparto con tono cordial; funciones internas cerradas a la API
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  c := public.aviso_reparto(pm);
  t := '';
  begin perform public._ventas_lista(hoy, hoy, null); t := t || '_ventas_lista abierta; '; exception when others then null; end;
  begin perform * from public._entregas_rango(hoy, hoy, null); t := t || '_entregas_rango abierta; '; exception when others then null; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T14 aviso "Entregado" de usted y funciones internas cerradas: ' ||
    case when c->>'mensaje' like '%, María.%' and c->>'mensaje' like '%Le confirmamos que su pedido fue entregado%'
              and c->>'mensaje' like '%Muchas gracias por su preferencia%' and t = ''
         then 'OK' else 'FALLA ' || t || coalesce(c->>'mensaje', 'null') end;

  -- T15: saludo: trato solo si hay nombre
  res := res || chr(10) || 'T15 saludo con trato (Sra. María) y sin nombre no usa trato: ' ||
    case when public._saludo('sra', 'maría josé') like '%, Sra. María' and public._saludo('don', null) !~ 'Don'
              and public._saludo(null, null) ~ '^Buen(os días|as tardes|as noches)$'
         then 'OK' else 'FALLA ' || public._saludo('sra', 'maría josé') || ' / ' || public._saludo('don', null) end;

  raise exception 'PRUEBA EN SECO 23 (todo se deshace): %', res;
end $do$;
