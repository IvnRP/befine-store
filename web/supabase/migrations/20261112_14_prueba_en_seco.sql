-- PRUEBA EN SECO de la migración 14 (clientes en el panel) — Befine Store
-- Uso: pegar en UNA misma consulta (1) 20261112_14_clientes.sql y (2) este archivo.
-- Termina SIEMPRE con un error intencional: todo se deshace. Busca FALLA: no debería aparecer.
do $do$
declare
  adm uuid := gen_random_uuid(); cli uuid := gen_random_uuid(); cho uuid := gen_random_uuid();
  inv uuid := gen_random_uuid(); inv2 uuid := gen_random_uuid();
  vb uuid; j jsonb; p1 uuid; t1 int; r jsonb; n int; msg text;
  dir jsonb := '{"calle":"Prueba","numero":"14","comuna":"Quilicura"}';
  kc  jsonb := '{"nombre":"Cliente Catorce","telefono":"9 1414 1414","email":"cliente14@correo.cl","acepta_terminos":true}';
  ki  jsonb := '{"nombre":"Invitada Catorce","telefono":"9 1515 1515","email":"invitada14@correo.cl","acepta_terminos":true}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (adm,  'admin14@correo.cl',   '{"nombre":"Admin Catorce"}',   false),
    (cli,  'cliente14@correo.cl', '{"nombre":"Cliente Catorce"}', false),
    (cho,  'chofer14@correo.cl',  '{"nombre":"Chofer Catorce"}',  false),
    (inv,  null, '{}', true),
    (inv2, null, '{}', true);
  update public.perfiles set rol = 'admin'  where id = adm;
  update public.perfiles set rol = 'chofer' where id = cho;

  -- Cliente: un pedido pagado (p1) y uno sin pagar. Invitada: un pedido. inv2: sin pedidos.
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j  := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir, kc);
  p1 := (j->>'id')::uuid; t1 := (j->>'total')::int;
  perform public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir, kc);
  perform set_config('request.jwt.claims', json_build_object('sub', inv, 'role', 'authenticated')::text, true);
  perform public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 2)), dir, ki);
  perform set_config('role', 'none', true);
  perform public.confirmar_pago(p1, 'PRUEBA-14-1', t1);
  perform set_config('role', 'authenticated', true);

  -- T01 / T02: sin clientes.ver no hay lista (chofer y cliente)
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  begin perform public.clientes_resumen(); msg := 'FALLA (pudo verla)';
  exception when others then msg := case when sqlstate = '42501' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T01 el chofer no ve la lista de clientes: ' || msg;
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin perform public.clientes_resumen(); msg := 'FALLA (pudo verla)';
  exception when others then msg := case when sqlstate = '42501' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T02 un cliente no ve la lista de clientes: ' || msg;

  -- T03: el admin ve al cliente con 1 pedido pagado (el pendiente no cuenta) y su gasto
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  r := public.clientes_resumen();
  select count(*) into n from jsonb_array_elements(r) e
   where (e->>'id')::uuid = cli and (e->>'pedidos')::int = 1 and (e->>'gastado')::int = t1
     and e->>'email' = 'cliente14@correo.cl' and e->>'comuna' = 'Quilicura' and not (e->>'invitado')::boolean;
  res := res || chr(10) || 'T03 lista: pedidos pagados, gasto, correo y comuna del cliente: ' || case when n = 1 then 'OK' else 'FALLA' end;

  -- T04: la invitada con pedido aparece con su nombre del pedido; el invitado sin pedidos no
  select count(*) into n from jsonb_array_elements(r) e
   where (e->>'id')::uuid = inv and (e->>'invitado')::boolean and e->>'nombre' = 'Invitada Catorce' and (e->>'pedidos')::int = 0;
  res := res || chr(10) || 'T04 invitada con pedido aparece (sin pagar = 0 pedidos pagados): ' || case when n = 1 then 'OK' else 'FALLA' end;
  select count(*) into n from jsonb_array_elements(r) e where (e->>'id')::uuid = inv2;
  res := res || chr(10) || 'T05 invitado sin pedidos no aparece: ' || case when n = 0 then 'OK' else 'FALLA' end;

  -- T06: ficha del cliente
  r := public.cliente_detalle(cli);
  res := res || chr(10) || 'T06 ficha con correo, 2 pedidos y resumen de 1 pagado: ' ||
         case when r->>'email' = 'cliente14@correo.cl' and jsonb_array_length(r->'pedidos') = 2
                   and (r->'resumen'->>'pedidos')::int = 1 and jsonb_array_length(r->'direcciones') >= 1
              then 'OK' else 'FALLA' end;

  -- T07..T09: validaciones de editar_cliente
  begin perform public.editar_cliente(cli, '{"telefono":"123"}'); msg := 'FALLA (aceptó)';
  exception when others then msg := case when sqlerrm like '%celular%' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T07 rechaza un celular no válido: ' || msg;
  begin perform public.editar_cliente(cli, '{"rut":"12.345.678-0"}'); msg := 'FALLA (aceptó)';
  exception when others then msg := case when sqlerrm like '%RUT%' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T08 rechaza un RUT no válido: ' || msg;
  begin perform public.editar_cliente(cli, '{"es_empresa":true,"rut":"22.222.222-2"}'); msg := 'FALLA (aceptó)';
  exception when others then msg := case when sqlerrm like '%empresa%' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T09 empresa exige RUT, razón social y giro: ' || msg;

  -- T10: edición válida → guarda RUT con formato y audita SOLO lo que cambió
  j := public.editar_cliente(cli, '{"nombre":"Cliente Editado","telefono":"+56 9 1414 1414","es_empresa":true,"rut":"22.222.222-2","razon_social":"Empresa Prueba SpA","giro":"Comercio"}');
  select count(*) into n from public.perfiles where id = cli and nombre = 'Cliente Editado' and rut = '22222222-2'
     and es_empresa and telefono = '56914141414';
  res := res || chr(10) || 'T10 guarda los datos (RUT 22222222-2, celular 569…): ' || case when n = 1 then 'OK' else 'FALLA' end;
  select count(*) into n from public.cambios_cliente
   where perfil_id = cli and cambiado_por = adm and despues ? 'rut' and despues ? 'nombre' and not despues ? 'apellido' and not despues ? 'activo';
  res := res || chr(10) || 'T11 la auditoría guarda quién y solo los campos cambiados: ' || case when n = 1 then 'OK' else 'FALLA' end;

  -- T12: bloquear → no puede comprar
  perform public.editar_cliente(cli, '{"activo":false}');
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin perform public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir, kc); msg := 'FALLA (compró)';
  exception when others then msg := 'OK'; end;
  res := res || chr(10) || 'T12 un cliente bloqueado no puede comprar: ' || msg;

  -- T13: el cliente no edita clientes ni lee la auditoría
  begin perform public.editar_cliente(cli, '{"activo":true}'); msg := 'FALLA (pudo editar)';
  exception when others then msg := case when sqlstate = '42501' then 'OK' else 'FALLA ' || sqlerrm end; end;
  select count(*) into n from public.cambios_cliente;
  res := res || chr(10) || 'T13 un cliente no edita ni lee la auditoría (RLS): ' || case when msg = 'OK' and n = 0 then 'OK' else 'FALLA ' || msg || ' filas=' || n end;

  -- T14: no se bloquea a alguien del equipo ni se edita a un invitado
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  begin perform public.editar_cliente(cho, '{"activo":false}'); msg := 'FALLA (bloqueó al chofer)';
  exception when others then msg := case when sqlerrm like '%equipo%' then 'OK' else 'FALLA ' || sqlerrm end; end;
  begin perform public.editar_cliente(inv, '{"nombre":"Otro Nombre"}'); msg := msg || ' / FALLA (editó invitado)';
  exception when others then msg := msg || case when sqlerrm like '%invitados%' then '' else ' / FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T14 no bloquea al equipo ni edita invitados: ' || msg;

  raise exception 'PRUEBA EN SECO 14 (todo se deshace): %', res;
end $do$;
