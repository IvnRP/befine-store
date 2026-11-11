-- PRUEBA EN SECO de la migración 09 (entregados de hoy en el reparto) — Befine Store
-- Uso: pegar en UNA misma consulta (1) 20261111_09_reparto_entregados_hoy.sql y (2) este archivo.
-- Termina SIEMPRE con un error intencional: todo se deshace. Busca FALLA: no debería aparecer.
do $do$
declare
  cho uuid := gen_random_uuid(); cli uuid := gen_random_uuid(); vb uuid; p1 uuid; j jsonb; r jsonb; n int;
  hoy date := (now() at time zone 'America/Santiago')::date;
  dir jsonb := '{"calle":"Prueba","numero":"9","comuna":"Quilicura"}';
  k   jsonb := '{"nombre":"Cliente Atrasado","telefono":"9 7777 8888","email":"atrasado@correo.cl","acepta_terminos":true}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (cho, 'atr.cho@correo.cl', '{"nombre":"Chofer"}', false), (cli, 'atrasado@correo.cl', '{"nombre":"Cliente"}', false);
  update public.perfiles set rol = 'chofer' where id = cho;

  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 4)), dir, k);
  p1 := (j->>'id')::uuid;
  perform set_config('role', 'none', true);
  perform public.confirmar_pago(p1, 'PRUEBA-09-1', (j->>'total')::int);
  update public.pedidos set fecha_entrega = hoy - 3 where id = p1;   -- atrasado

  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.marcar_reparto(p1, 'en_ruta');
  perform public.marcar_reparto(p1, 'entregado');
  r := public.reparto_del_dia(hoy);
  select count(*) into n from jsonb_array_elements(r) e where (e->>'id')::uuid = p1 and e->>'estado' = 'entregado';
  res := res || chr(10) || 'T01 un atrasado entregado hoy aparece en el reparto de hoy: ' || case when n = 1 then 'OK' else 'FALLA' end;
  select count(*) into n from jsonb_array_elements(r) e where (e->>'id')::uuid = p1 and (e->>'atrasado')::boolean;
  res := res || chr(10) || 'T02 un pedido entregado ya no se marca como atrasado: ' || case when n = 0 then 'OK' else 'FALLA' end;
  perform set_config('role', 'none', true);
  raise exception 'PRUEBA EN SECO 09 (todo se deshace): %', res;
end $do$;
