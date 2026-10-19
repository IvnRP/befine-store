-- PRUEBA EN SECO de la migración 04 (reglas de cupones) — Befine Store
-- Requiere: 01 y 01b aplicadas. Pegar completo en Supabase > SQL Editor > Run.
-- Aplica la 04 dentro de una transacción, prueba los casos y termina SIEMPRE con
-- un error intencional: todo se deshace. El texto del error muestra los
-- resultados T01..T20. Busca la palabra FALLA: no debería aparecer.
--
-- Uso: pegar primero el contenido completo de 04_cupones_reglas.sql y, a
-- continuación, este archivo, y ejecutar todo junto con "begin;" al inicio
-- (el bloque final hace rollback por error).

do $do$
declare
  u1 uuid := gen_random_uuid();   -- cliente nuevo con cuenta
  u2 uuid := gen_random_uuid();   -- otra cuenta, mismo celular que u1
  u3 uuid := gen_random_uuid();   -- invitado (sesión anónima)
  u4 uuid := gen_random_uuid();   -- otra cuenta, mismo correo de contacto que u1
  u5 uuid := gen_random_uuid();   -- cliente para usos por cliente
  v_rec uuid; v_bid uuid; p1 uuid; p2 uuid;
  j jsonb; n int;
  res text := 'RESULTADOS';
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  c1  jsonb := '{"nombre":"Camila Rojas","telefono":"9 1111 2222","email":"camila@correo.cl"}';
  items_rec  jsonb; items_bid jsonb;

  procedure_ok boolean;
begin
  -- ---------- Datos de prueba ----------
  select id into v_rec from public.variantes_producto where sku = 'BEF-REC-12';   -- $2.000
  select id into v_bid from public.variantes_producto where sku = 'BEF-BID-20';   -- $5.490
  items_rec := jsonb_build_array(jsonb_build_object('variante_id', v_rec, 'cantidad', 5));   -- $10.000
  items_bid := jsonb_build_array(jsonb_build_object('variante_id', v_bid, 'cantidad', 1));   -- $5.490

  insert into auth.users (id, email, raw_user_meta_data) values
    (u1, 'camila@correo.cl', '{"nombre":"Camila Rojas","telefono":"+56 9 1111 2222"}'),
    (u2, 'otra.camila@correo.cl', '{"nombre":"Camila Otra"}'),
    (u4, 'tercera@correo.cl', '{"nombre":"Tercera"}'),
    (u5, 'frecuente@correo.cl', '{"nombre":"Frecuente"}');
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values (u3, null, '{}', true);

  insert into public.cupones (codigo, tipo, valor, compra_minima, usos_maximos, vigente_desde, vigente_hasta, descripcion) values
    ('PRUEBA-CYBER', 'porcentaje', 10, 8000, 100, current_date - 1, current_date + 5, 'Campaña de prueba'),
    ('PRUEBA-VENCIDO', 'monto_fijo', 2000, 0, null, current_date - 30, current_date - 1, null),
    ('PRUEBA-AGOTADO', 'monto_fijo', 1000, 0, 1, null, null, null);
  update public.cupones set usos_actuales = 1 where codigo = 'PRUEBA-AGOTADO';
  insert into public.cupones (codigo, tipo, valor, requiere_cuenta, solo_primera_compra) values
    ('PRUEBA-BIENVENIDA', 'porcentaje', 15, true, true);
  insert into public.cupones (codigo, tipo, valor, usos_por_cliente) values
    ('PRUEBA-DOS', 'monto_fijo', 500, 2);
  insert into public.cupones (codigo, tipo, valor) values ('PRUEBA-SOLOREC', 'porcentaje', 50);
  insert into public.cupon_variantes (cupon_id, variante_id)
    select id, v_rec from public.cupones where codigo = 'PRUEBA-SOLOREC';

  -- ---------- Como cliente u1 (cuenta registrada) ----------
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  j := public.revisar_cupon('prueba-cyber', items_rec);
  res := res || chr(10) || 'T01 campaña válida (10% de $10.000=1000): ' || case when (j->>'valido')::boolean and (j->>'descuento')::int = 1000 then 'OK' else 'FALLA ' || j::text end;
  j := public.revisar_cupon('PRUEBA-CYBER', items_bid);
  res := res || chr(10) || 'T02 bajo la compra mínima: ' || case when not (j->>'valido')::boolean and j->>'mensaje' like '%compra mínima de $8.000%' then 'OK' else 'FALLA ' || j::text end;
  j := public.revisar_cupon('PRUEBA-VENCIDO', items_rec);
  res := res || chr(10) || 'T03 vencido: ' || case when not (j->>'valido')::boolean then 'OK' else 'FALLA ' || j::text end;
  j := public.revisar_cupon('PRUEBA-AGOTADO', items_rec);
  res := res || chr(10) || 'T04 sin usos disponibles: ' || case when j->>'mensaje' like '%límite de usos%' then 'OK' else 'FALLA ' || j::text end;
  j := public.revisar_cupon('PRUEBA-SOLOREC', items_bid);
  res := res || chr(10) || 'T05 no aplica a esos productos: ' || case when j->>'mensaje' like '%no aplica%' then 'OK' else 'FALLA ' || j::text end;
  j := public.revisar_cupon('PRUEBA-SOLOREC', items_rec || items_bid);
  res := res || chr(10) || 'T06 aplica solo a recargas (50% de $10.000): ' || case when (j->>'descuento')::int = 5000 then 'OK' else 'FALLA ' || j::text end;
  j := public.revisar_cupon('PRUEBA-BIENVENIDA', items_rec);
  res := res || chr(10) || 'T07 bienvenida, cuenta nueva: ' || case when (j->>'valido')::boolean and (j->>'descuento')::int = 1500 then 'OK' else 'FALLA ' || j::text end;
  select usos_actuales into n from public.cupones where codigo = 'PRUEBA-BIENVENIDA';
  res := res || chr(10) || 'T08 revisar no gasta usos: ' || case when n = 0 then 'OK' else 'FALLA ' || n end;

  j := public.crear_pedido(items_rec, dir, c1, null, null, 'PRUEBA-BIENVENIDA', null);
  p1 := (j->>'id')::uuid;
  select usos_actuales into n from public.cupones where codigo = 'PRUEBA-BIENVENIDA';
  res := res || chr(10) || 'T09 pedido con bienvenida (total 10000-1500=8500, uso=1): ' || case when (j->>'total')::int = 8500 and n = 1 then 'OK' else 'FALLA ' || j::text || ' usos=' || n end;

  begin
    perform public.crear_pedido(items_rec, dir, c1, null, null, 'PRUEBA-BIENVENIDA', null);
    res := res || chr(10) || 'T10 segundo pedido con bienvenida pendiente: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T10 segundo pedido con bienvenida pendiente: ' || case when sqlerrm like 'Ya tienes un pedido con este cupón%' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  begin
    perform public._evaluar_cupon('PRUEBA-CYBER', u1, null, null, '[]'::jsonb, false);
    res := res || chr(10) || 'T11 _evaluar_cupon no se expone por la API: FALLA (se pudo ejecutar)';
  exception when insufficient_privilege then
    res := res || chr(10) || 'T11 _evaluar_cupon no se expone por la API: OK';
  end;

  -- ---------- Servidor: cancelar devuelve el uso ----------
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  update public.pedidos set estado = 'cancelado' where id = p1;
  select usos_actuales into n from public.cupones where codigo = 'PRUEBA-BIENVENIDA';
  res := res || chr(10) || 'T12 cancelar devuelve el uso del cupón: ' || case when n = 0 then 'OK' else 'FALLA usos=' || n end;

  perform set_config('role', 'authenticated', true);
  j := public.crear_pedido(items_rec, dir, c1, null, null, 'PRUEBA-BIENVENIDA', null);
  p2 := (j->>'id')::uuid;
  res := res || chr(10) || 'T13 tras cancelar, la bienvenida vuelve a servir: ' || case when (j->>'descuento_cupon')::int = 1500 then 'OK' else 'FALLA ' || j::text end;

  -- El pedido se paga (lo hará el webhook de Mercado Pago)
  perform set_config('role', 'none', true);
  update public.pedidos set estado = 'pagado' where id = p2;

  -- ---------- Otra cuenta con el MISMO celular ----------
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.crear_pedido(items_rec, dir, '{"nombre":"Camila Otra","telefono":"+56 9 1111 2222","email":"otra.camila@correo.cl"}', null, null, 'PRUEBA-BIENVENIDA', null);
    res := res || chr(10) || 'T14 otra cuenta, mismo celular: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T14 otra cuenta, mismo celular: ' || case when sqlerrm = 'Este cupón es solo para tu primera compra.' then 'OK' else 'FALLA ' || sqlerrm end;
  end;
  -- revisar_cupon no revela datos de terceros: con su propia cuenta (sin compras) aparece válido
  j := public.revisar_cupon('PRUEBA-BIENVENIDA', items_rec);
  res := res || chr(10) || 'T15 revisar no revela compras de otros: ' || case when (j->>'valido')::boolean then 'OK' else 'FALLA ' || j::text end;

  -- ---------- Otra cuenta con el MISMO correo de contacto ----------
  perform set_config('request.jwt.claims', json_build_object('sub', u4, 'role', 'authenticated')::text, true);
  begin
    perform public.crear_pedido(items_rec, dir, '{"nombre":"Tercera","telefono":"9 3333 4444","email":"CAMILA@correo.cl"}', null, null, 'PRUEBA-BIENVENIDA', null);
    res := res || chr(10) || 'T16 otra cuenta, mismo correo: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T16 otra cuenta, mismo correo: ' || case when sqlerrm = 'Este cupón es solo para tu primera compra.' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  -- ---------- Misma cuenta, ya compró ----------
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  j := public.revisar_cupon('PRUEBA-BIENVENIDA', items_rec);
  res := res || chr(10) || 'T17 misma cuenta que ya compró: ' || case when j->>'mensaje' = 'Este cupón es solo para tu primera compra.' then 'OK' else 'FALLA ' || j::text end;

  -- ---------- Invitado ----------
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated', 'is_anonymous', true)::text, true);
  j := public.revisar_cupon('PRUEBA-BIENVENIDA', items_rec);
  res := res || chr(10) || 'T18 invitado no usa la bienvenida: ' || case when j->>'mensaje' like 'Este cupón es para clientes con cuenta%' then 'OK' else 'FALLA ' || j::text end;

  -- ---------- Usos por cliente ----------
  perform set_config('request.jwt.claims', json_build_object('sub', u5, 'role', 'authenticated')::text, true);
  perform public.crear_pedido(items_rec, dir, '{"nombre":"Frecuente","telefono":"9 5555 6666","email":"frecuente@correo.cl"}', null, null, 'PRUEBA-DOS', null);
  perform public.crear_pedido(items_rec, dir, '{"nombre":"Frecuente","telefono":"9 5555 6666","email":"frecuente@correo.cl"}', null, null, 'PRUEBA-DOS', null);
  j := public.revisar_cupon('PRUEBA-DOS', items_rec);
  res := res || chr(10) || 'T19 tercer uso con límite de 2 por cliente: ' || case when j->>'mensaje' = 'Ya usaste este cupón el máximo de veces permitido.' then 'OK' else 'FALLA ' || j::text end;

  -- ---------- Regla de integridad ----------
  perform set_config('role', 'none', true);
  begin
    insert into public.cupones (codigo, tipo, valor, solo_primera_compra, requiere_cuenta) values ('PRUEBA-MAL', 'monto_fijo', 1, true, false);
    res := res || chr(10) || 'T20 bienvenida sin exigir cuenta: FALLA (se permitió)';
  exception when check_violation then
    res := res || chr(10) || 'T20 bienvenida sin exigir cuenta se rechaza: OK';
  end;

  raise exception 'PRUEBA EN SECO 04 (todo se deshace): %', res;
end $do$;
