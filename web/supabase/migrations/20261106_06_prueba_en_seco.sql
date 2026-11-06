-- PRUEBA EN SECO de la migración 06 (aceptación de Términos y Privacidad) — Befine Store
-- Requiere: 01, 01b, 04, 03 y 05 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261106_06_aceptacion_terminos.sql
-- y (2) este archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo
-- se deshace. Muestra T01..T05. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  u1 uuid := gen_random_uuid();
  v_rec uuid; p1 uuid; j jsonb; n int;
  ts timestamptz; ver text;
  res text := 'RESULTADOS';
  dir   jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  items jsonb;
begin
  select id into v_rec from public.variantes_producto where sku = 'BEF-REC-12';
  items := jsonb_build_array(jsonb_build_object('variante_id', v_rec, 'cantidad', 2));
  insert into auth.users (id, email, raw_user_meta_data) values (u1, 'legal@correo.cl', '{"nombre":"Prueba Legal"}');

  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  begin
    perform public.crear_pedido(items, dir, '{"nombre":"Prueba Legal","telefono":"9 4444 5555","email":"legal@correo.cl"}', null, null, null, null);
    res := res || chr(10) || 'T01 sin aceptar los términos se rechaza: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T01 sin aceptar los términos se rechaza: ' ||
           case when sqlerrm like 'Debes aceptar los Términos%' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  begin
    perform public.crear_pedido(items, dir, '{"nombre":"Prueba Legal","telefono":"9 4444 5555","email":"legal@correo.cl","acepta_terminos":"si"}', null, null, null, null);
    res := res || chr(10) || 'T02 un valor distinto de true no cuenta como aceptación: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T02 un valor distinto de true no cuenta como aceptación: OK';
  end;

  j := public.crear_pedido(items, dir, '{"nombre":"Prueba Legal","telefono":"9 4444 5555","email":"legal@correo.cl","acepta_terminos":true}', null, null, null, null);
  p1 := (j->>'id')::uuid;
  perform set_config('role', 'none', true);
  select terminos_aceptados_at, terminos_version into ts, ver from public.pedidos where id = p1;
  res := res || chr(10) || 'T03 aceptando se crea el pedido con fecha del servidor y versión 2026-11: ' ||
         case when ts is not null and ts > now() - interval '1 minute' and ver = '2026-11' then 'OK' else 'FALLA ts=' || coalesce(ts::text,'null') || ' ver=' || coalesce(ver,'null') end;

  -- El cliente no puede cambiar su aceptación (RLS: solo pedidos.gestionar actualiza pedidos)
  perform set_config('role', 'authenticated', true);
  update public.pedidos set terminos_aceptados_at = now() - interval '10 days' where id = p1;
  get diagnostics n = row_count;
  res := res || chr(10) || 'T04 el cliente no puede modificar la aceptación: ' || case when n = 0 then 'OK' else 'FALLA filas=' || n end;

  perform set_config('role', 'none', true);
  select count(*) into n from public.parametros where clave = 'terminos_version';
  res := res || chr(10) || 'T05 existe el parámetro terminos_version: ' || case when n = 1 then 'OK' else 'FALLA' end;

  raise exception 'PRUEBA EN SECO 06 (todo se deshace): %', res;
end $do$;
