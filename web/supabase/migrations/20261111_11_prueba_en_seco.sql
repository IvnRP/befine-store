-- PRUEBA EN SECO de la migración 11 (registro del correo de confirmación) — Befine Store
-- Uso: pegar en UNA misma consulta (1) 20261111_11_correo_confirmacion.sql y (2) este archivo.
-- Termina SIEMPRE con un error intencional: todo se deshace. Busca FALLA: no debería aparecer.
do $do$
declare
  cli uuid := gen_random_uuid(); vb uuid; p1 uuid; p2 uuid; j jsonb; n int;
  dir jsonb := '{"calle":"Prueba","numero":"11","comuna":"Quilicura"}';
  k   jsonb := '{"nombre":"Cliente Correo","telefono":"9 2222 1111","email":"correo11@correo.cl","acepta_terminos":true}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values (cli, 'correo11@correo.cl', '{"nombre":"Cliente"}', false);

  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j  := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir, k);
  p1 := (j->>'id')::uuid;
  p2 := ((public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir, k))->>'id')::uuid;

  -- T01: el cliente no puede marcar el correo como enviado (lo hace solo el servidor)
  update public.pedidos set correo_confirmacion_at = now() where id = p1;
  get diagnostics n = row_count;
  res := res || chr(10) || 'T01 el cliente no puede marcar el correo como enviado: ' || case when n = 0 then 'OK' else 'FALLA filas=' || n end;

  perform set_config('role', 'none', true);
  perform public.confirmar_pago(p1, 'PRUEBA-11-1', (j->>'total')::int);

  -- T02: la reserva del envío funciona una sola vez y solo para pedidos pagados
  update public.pedidos set correo_confirmacion_at = now()
   where id in (p1, p2) and correo_confirmacion_at is null and estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado');
  get diagnostics n = row_count;
  res := res || chr(10) || 'T02 se reserva solo el pedido pagado (no el pendiente): ' || case when n = 1 then 'OK' else 'FALLA filas=' || n end;

  -- T03: una segunda reserva del mismo pedido no aplica (no hay doble correo)
  update public.pedidos set correo_confirmacion_at = now()
   where id = p1 and correo_confirmacion_at is null and estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado');
  get diagnostics n = row_count;
  res := res || chr(10) || 'T03 un pedido no se reserva dos veces (sin correos duplicados): ' || case when n = 0 then 'OK' else 'FALLA filas=' || n end;

  raise exception 'PRUEBA EN SECO 11 (todo se deshace): %', res;
end $do$;
