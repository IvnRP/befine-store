-- PRUEBA EN SECO de la migración 22 (correcciones de la auditoría de seguridad) — Befine Store
-- Requiere: 01 a 21 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261125_22_seguridad_auditoria.sql y (2) este
-- archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace (no queda ningún
-- pedido, cupón, rol ni usuario de prueba).
-- Muestra T01..T14 (incluye T10b). Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  adm uuid := gen_random_uuid();   -- dueño
  cli uuid := gen_random_uuid();   -- cliente 1
  cl2 uuid := gen_random_uuid();   -- cliente 2
  bot uuid := gen_random_uuid();   -- invitado que crea pedidos sin pagar
  emp uuid := gen_random_uuid();   -- empleado con clientes.gestionar
  cho uuid := gen_random_uuid();   -- chofer
  vb uuid; cup uuid; j jsonb; p1 uuid; p2 uuid; p3 uuid; pv uuid; t1 int; n int; msg text; i int;
  dir  jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  item jsonb;
  res text := 'RESULTADOS';
  usos int; cup2 uuid; prem text; pp uuid;
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  item := jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 4));
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (adm, 'adm22@correo.cl', '{"nombre":"Admin"}', false), (cli, 'cli22@correo.cl', '{"nombre":"Cli"}', false),
    (cl2, 'cl222@correo.cl', '{"nombre":"Cli2"}', false), (bot, null, '{}', true),
    (emp, 'emp22@correo.cl', '{"nombre":"Emp"}', false), (cho, 'cho22@correo.cl', '{"nombre":"Cho"}', false);
  update public.perfiles set rol = 'admin' where id = adm;
  update public.perfiles set rol = 'chofer' where id = cho;
  insert into public.roles (id, nombre) values ('vendedor22', 'Vendedor prueba');
  insert into public.rol_permisos (rol_id, permiso) values ('vendedor22', 'clientes.gestionar'), ('vendedor22', 'clientes.ver');
  update public.perfiles set rol = 'vendedor22' where id = emp;
  insert into public.cupones (codigo, tipo, valor, usos_maximos) values ('PRUEBA22', 'porcentaje', 10, 1) returning id into cup;

  -- T01: crear un pedido con cupón NO gasta el cupón
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  j := public.crear_pedido(item, dir, '{"nombre":"Cli","telefono":"9 2201 2201","email":"cli22@correo.cl","acepta_terminos":true}',
                           null, null, 'PRUEBA22');
  p1 := (j->>'id')::uuid; t1 := (j->>'total')::int;
  perform set_config('role', 'none', true);
  select usos_actuales into usos from public.cupones where id = cup;
  res := res || chr(10) || 'T01 un pedido sin pagar no gasta el cupón: ' ||
    case when (j->>'descuento_cupon')::int > 0 and usos = 0 then 'OK' else 'FALLA usos=' || usos end;

  -- T02: otro cliente puede usar el mismo cupón (de 1 uso) mientras nadie lo haya pagado
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cl2, 'role', 'authenticated')::text, true);
  begin
    j := public.crear_pedido(item, dir, '{"nombre":"Cli2","telefono":"9 2202 2202","email":"cl222@correo.cl","acepta_terminos":true}',
                             null, null, 'PRUEBA22');
    p2 := (j->>'id')::uuid; msg := 'OK';
  exception when others then msg := 'FALLA ' || sqlerrm; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T02 un bot no agota el cupón: otro cliente aún puede usarlo: ' || msg;

  -- T03: al confirmarse el pago, el uso se cuenta
  perform public.confirmar_pago(p1, 'PRUEBA-22-1', t1);
  select usos_actuales into usos from public.cupones where id = cup;
  res := res || chr(10) || 'T03 el uso del cupón se cuenta al pagar: ' || case when usos = 1 then 'OK' else 'FALLA usos=' || usos end;

  -- T04: con el cupón ya pagado una vez (máximo 1), un pedido nuevo lo rechaza
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  begin
    perform public.crear_pedido(item, dir, '{"nombre":"Adm","telefono":"9 2203 2203","email":"adm22@correo.cl","acepta_terminos":true}',
                                null, null, 'PRUEBA22');
    msg := 'FALLA (aceptó)';
  exception when others then msg := case when sqlerrm like '%límite de usos%' then 'OK' else 'FALLA ' || sqlerrm end; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T04 un cupón agotado por pagos reales se rechaza: ' || msg;

  -- T05: cancelar un pedido sin pagar no devuelve un uso que nunca contó; cancelar uno pagado sí
  update public.pedidos set estado = 'cancelado' where id = p2;
  select usos_actuales into usos from public.cupones where id = cup;
  msg := case when usos = 1 then 'sin pagar OK' else 'FALLA sin pagar usos=' || usos end;
  update public.pedidos set estado = 'cancelado' where id = p1;
  select usos_actuales into usos from public.cupones where id = cup;
  msg := msg || case when usos = 0 then ', pagado OK' else ', FALLA pagado usos=' || usos end;
  res := res || chr(10) || 'T05 al cancelar solo se devuelve el uso de un pedido pagado: ' || msg;

  -- T06: un invitado (bot) puede tener como máximo 5 pedidos sin pagar en 24 h
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bot, 'role', 'authenticated')::text, true);
  n := 0;
  for i in 1..5 loop
    perform public.crear_pedido(item, dir, '{"nombre":"Bot","telefono":"9 2209 2209","email":"bot22@correo.cl","acepta_terminos":true}');
    n := n + 1;
  end loop;
  begin
    perform public.crear_pedido(item, dir, '{"nombre":"Bot","telefono":"9 2209 2209","email":"bot22@correo.cl","acepta_terminos":true}');
    msg := 'FALLA (creó el 6.º)';
  exception when others then msg := case when sqlerrm like '%varios pedidos sin pagar%' then 'OK' else 'FALLA ' || sqlerrm end; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T06 máximo 5 pedidos sin pagar en 24 h por cuenta o invitado: ' || case when n = 5 then msg else 'FALLA n=' || n end;

  -- T07: los pedidos sin pagar de más de 48 h se vencen solos; los recientes no
  select id into pv from public.pedidos where perfil_id = bot order by created_at limit 1;
  update public.pedidos set created_at = now() - interval '50 hours' where id = pv;
  n := public.vencer_pedidos_pendientes(48);
  res := res || chr(10) || 'T07 vencimiento automático a las 48 h (solo los antiguos): ' ||
    case when n = 1
              and exists (select 1 from public.pedidos where id = pv and estado = 'cancelado' and vencido_at is not null)
              and (select count(*) from public.pedidos where perfil_id = bot and estado = 'pendiente_pago') = 4
              and exists (select 1 from public.historial_pedido where pedido_id = pv and nota like 'Vencido: 48 h sin pago%')
         then 'OK' else 'FALLA n=' || n end;

  -- T08: si llega el pago de un pedido vencido, se reabre y se confirma (no se pierde la venta)
  j := public.confirmar_pago(pv, 'PRUEBA-22-2', (select total from public.pedidos where id = pv));
  res := res || chr(10) || 'T08 un pago que llega tarde reabre y confirma el pedido vencido: ' ||
    case when (j->>'ok')::boolean
              and exists (select 1 from public.pedidos where id = pv and estado = 'en_preparacion' and vencido_at is null)
              and exists (select 1 from public.historial_pedido where pedido_id = pv and nota like 'Reabierto%')
         then 'OK' else 'FALLA ' || j::text end;

  -- T09: nadie desde la API puede ejecutar el vencimiento (solo pg_cron)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  begin perform public.vencer_pedidos_pendientes(24); msg := 'FALLA (pudo)';
  exception when insufficient_privilege then msg := 'OK'; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T09 el vencimiento no se puede llamar desde la tienda ni el panel: ' || msg;

  -- T10: un empleado con clientes.gestionar edita a un cliente, pero no su propio nivel ni estado
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', emp, 'role', 'authenticated')::text, true);
  update public.perfiles set es_empresa = true where id = cl2;
  update public.perfiles set es_empresa = true, activo = false where id = emp;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T10 un empleado no puede cambiarse su propio nivel, estado ni marca de empresa: ' ||
    case when (select es_empresa from public.perfiles where id = cl2)
              and (select not es_empresa and activo from public.perfiles where id = emp)
         then 'OK' else 'FALLA' end;

  -- T10b: tampoco desde el panel (editar_cliente) puede marcarse como empresa a sí mismo
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', emp, 'role', 'authenticated')::text, true);
  begin
    perform public.editar_cliente(emp, '{"es_empresa":true,"rut":"76.086.428-5","razon_social":"Mi SpA","giro":"Venta"}');
    msg := 'FALLA (pudo)';
  exception when insufficient_privilege then msg := 'OK'; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T10b tampoco desde el panel puede marcarse como empresa a sí mismo: ' || msg;

  -- T11: el chofer no lista direcciones de la tabla; las de su ruta le llegan por reparto_del_dia(); el admin ve todo
  update public.pedidos set estado = 'en_ruta', fecha_entrega = (now() at time zone 'America/Santiago')::date where id = pv;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  select count(*) into n from public.direcciones;
  msg := case when n = 0 then 'tabla cerrada OK' else 'FALLA ve ' || n || ' direcciones' end;
  msg := msg || case when exists (select 1 from jsonb_array_elements(public.reparto_del_dia(null)) e
                                   where (e->>'id')::uuid = pv and e->>'calle' = 'Los Tailandeses')
                     then ', ruta con dirección OK' else ', FALLA ruta' end;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  select count(*) into n from public.direcciones d where d.id = (select direccion_id from public.pedidos where id = p1);
  msg := msg || case when n = 1 then ', admin historial OK' else ', FALLA admin' end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T11 el chofer no lista direcciones; solo recibe las de su ruta (el admin, el historial): ' || msg;

  -- T12: el cliente sigue sin ver pedidos ni direcciones de otros
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cl2, 'role', 'authenticated')::text, true);
  select count(*) into n from public.pedidos where perfil_id <> cl2;
  select count(*) + n into n from public.direcciones where perfil_id is distinct from cl2;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T12 un cliente no ve pedidos ni direcciones de otros: ' || case when n = 0 then 'OK' else 'FALLA ' || n end;

  -- T13: el MISMO cliente no puede usar dos veces un cupón de 1 uso dejando pedidos sin pagar
  insert into public.cupones (codigo, tipo, valor, usos_maximos) values ('PRUEBA22C', 'porcentaje', 10, 1) returning id into cup2;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cl2, 'role', 'authenticated')::text, true);
  perform public.crear_pedido(item, dir, '{"nombre":"Cli2","telefono":"9 2202 2202","email":"cl222@correo.cl","acepta_terminos":true}',
                              null, null, 'PRUEBA22C');
  begin
    perform public.crear_pedido(item, dir, '{"nombre":"Cli2","telefono":"9 2202 2202","email":"cl222@correo.cl","acepta_terminos":true}',
                                null, null, 'PRUEBA22C');
    msg := 'FALLA (lo usó dos veces)';
  exception when others then msg := case when sqlerrm like '%límite de usos%' then 'OK' else 'FALLA ' || sqlerrm end; end;
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin
    perform public.crear_pedido(item, dir, '{"nombre":"Cli","telefono":"9 2201 2201","email":"cli22@correo.cl","acepta_terminos":true}',
                                null, null, 'PRUEBA22C');
    msg := msg || ', otro cliente aún puede OK';
  exception when others then msg := msg || ', FALLA otro cliente: ' || sqlerrm; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T13 el mismo cliente no repite un cupón de 1 uso con pedidos sin pagar: ' || msg;

  -- T14: un premio del Club ya puesto en un pedido sin pagar cuenta como usado (no se canjea otro encima)
  update public.perfiles set puntos_saldo = 400 where id = cli;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  j := public.canjear_recompensa('menor'); prem := coalesce(j->>'codigo', j->>'cupon');
  begin
    perform public.canjear_recompensa('menor'); msg := 'FALLA (canjeó con un premio sin usar)';
  exception when others then msg := case when sqlerrm like '%premio sin usar%' then 'bloqueo previo OK' else 'FALLA ' || sqlerrm end; end;
  j := public.crear_pedido(item, dir, '{"nombre":"Cli","telefono":"9 2201 2201","email":"cli22@correo.cl","acepta_terminos":true}',
                           null, null, prem);
  begin
    perform public.canjear_recompensa('menor'); msg := msg || ', con el premio en un pedido canjea otro OK';
  exception when others then msg := msg || ', FALLA ' || sqlerrm; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T14 un premio del Club en un pedido sin pagar no bloquea el siguiente canje: ' || msg;

  raise exception 'PRUEBA EN SECO 22 (todo se deshace): %', res;
end $do$;
