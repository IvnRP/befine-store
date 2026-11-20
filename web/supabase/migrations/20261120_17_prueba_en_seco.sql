-- PRUEBA EN SECO de la migración 17 (compra como invitado desde otro navegador) — Befine Store
-- Requiere: 01 a 16 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261120_17_pedidos_invitado.sql y (2) este
-- archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace.
-- Muestra T01..T12. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  a1  uuid := gen_random_uuid();   -- invitada que pagó desde WhatsApp (2 pedidos, mismo correo)
  a2  uuid := gen_random_uuid();   -- celular compartido: un pedido con su correo y otro con otro correo
  a3  uuid := gen_random_uuid();   -- invitado de otra persona
  cu  uuid := gen_random_uuid();   -- la cuenta que la clienta crea en otro navegador (correo confirmado)
  nc  uuid := gen_random_uuid();   -- cuenta con el correo de a3 pero SIN confirmar
  vb uuid; j jsonb; r jsonb; n int; s0 int; msg text;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; t1 int; d1 uuid;
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  ka  jsonb := '{"nombre":"Ana Diecisiete","telefono":"9 1717 1717","email":"Ana17@Correo.cl","acepta_terminos":true}';
  kx  jsonb := '{"nombre":"Otra Persona","telefono":"9 1818 1818","email":"otra17@correo.cl","acepta_terminos":true}';
  kb  jsonb := '{"nombre":"Beto Diecisiete","telefono":"9 1919 1919","email":"beto17@correo.cl","acepta_terminos":true}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous, email_confirmed_at) values
    (a1, null, '{}', true, null), (a2, null, '{}', true, null), (a3, null, '{}', true, null),
    (cu, 'ana17@correo.cl',  '{"nombre":"Ana"}',  false, now()),
    (nc, 'beto17@correo.cl', '{"nombre":"Beto"}', false, null);

  -- Compras como invitado (cada una en su propio "navegador" = su sesión anónima)
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
  j  := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir, ka);
  p1 := (j->>'id')::uuid; t1 := (j->>'total')::int;
  j  := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir, ka);
  p2 := (j->>'id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', a2, 'role', 'authenticated')::text, true);
  perform public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir, ka);
  perform public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir, kx);
  perform set_config('request.jwt.claims', json_build_object('sub', a3, 'role', 'authenticated')::text, true);
  j  := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir, kb);
  p3 := (j->>'id')::uuid;

  -- Servidor: Mercado Pago confirma p1; la invitada tiene 10 puntos; p3 es antiguo (8 días)
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '{}', true);
  perform public.confirmar_pago(p1, 'PRUEBA-17-1', t1);
  perform public._mover_puntos(a1, 'ajuste', 10, 'Prueba 17');
  update public.pedidos set created_at = now() - interval '8 days' where id = p3;
  select direccion_id into d1 from public.pedidos where id = p1;

  -- T01: otro navegador SIN sesión ve el resultado del pago, sin datos personales
  perform set_config('role', 'anon', true);
  r := public.pedido_vuelta(p1);
  res := res || chr(10) || 'T01 sin sesión se ve número, estado y total del pedido pagado: ' ||
    case when r->>'estado' in ('pagado', 'en_preparacion') and (r->>'total')::int = t1 and (r->>'numero') is not null
              and (r->>'invitado')::boolean then 'OK' else 'FALLA ' || coalesce(r::text, 'null') end;
  res := res || chr(10) || 'T02 el correo va enmascarado y no hay nombre, teléfono ni dirección: ' ||
    case when r->>'correo' = 'an•••@correo.cl'
              and not (r ?| array['contacto_nombre','contacto_telefono','contacto_email','direccion','direccion_id','perfil_id'])
         then 'OK' else 'FALLA ' || coalesce(r::text, 'null') end;
  res := res || chr(10) || 'T03 un id inexistente o un pedido de hace más de 7 días no muestra nada: ' ||
    case when public.pedido_vuelta(gen_random_uuid()) is null and public.pedido_vuelta(p3) is null then 'OK' else 'FALLA' end;
  res := res || chr(10) || 'T04 máscara de correo (corto, nulo, sin @): ' ||
    case when public.correo_mascara('Jo@X.cl') = 'j•••@x.cl' and public.correo_mascara(null) is null
              and public.correo_mascara('sin-arroba') is null then 'OK' else 'FALLA ' || coalesce(public.correo_mascara('Jo@X.cl'), 'null') end;

  -- T05: sin sesión no se puede reclamar
  begin perform public.reclamar_pedidos_invitado(); msg := 'FALLA (pudo llamarla)';
  exception when others then msg := case when sqlstate = '42501' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T05 sin sesión no se puede reclamar: ' || msg;

  -- T06: una sesión de invitado no reclama nada
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a3, 'role', 'authenticated')::text, true);
  r := public.reclamar_pedidos_invitado();
  res := res || chr(10) || 'T06 un invitado no puede reclamar pedidos: ' ||
    case when (r->>'ok')::boolean = false then 'OK' else 'FALLA ' || r::text end;

  -- T07: cuenta con el mismo correo pero SIN confirmar: no se lleva los pedidos
  perform set_config('request.jwt.claims', json_build_object('sub', nc, 'role', 'authenticated')::text, true);
  r := public.reclamar_pedidos_invitado();
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T07 sin correo confirmado no se traspasa nada: ' ||
    case when r->>'motivo' = 'correo_sin_confirmar' and (select perfil_id from public.pedidos where id = p3) = a3
         then 'OK' else 'FALLA ' || r::text end;

  -- T08..T11: la clienta entra con su cuenta (correo confirmado, mayúsculas distintas)
  select puntos_saldo into s0 from public.perfiles where id = cu;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cu, 'role', 'authenticated')::text, true);
  r := public.reclamar_pedidos_invitado();
  select count(*) into n from public.pedidos where id in (p1, p2);   -- con RLS: solo ve los suyos
  res := res || chr(10) || 'T08 sus 2 pedidos de invitada pasan a su cuenta y los ve en Mis pedidos: ' ||
    case when (r->>'pedidos')::int = 2 and n = 2 then 'OK' else 'FALLA ' || r::text || ' visibles=' || n end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T09 el celular compartido (otro correo en el mismo invitado) no se mezcla: ' ||
    case when (select count(*) from public.pedidos where perfil_id = a2) = 2 then 'OK' else 'FALLA' end;
  res := res || chr(10) || 'T10 sus puntos y su dirección pasan a la cuenta: ' ||
    case when (select puntos_saldo from public.perfiles where id = cu) = s0 + (r->>'puntos')::int
              and (r->>'puntos')::int >= 10
              and (select puntos_saldo from public.perfiles where id = a1) = 0
              and not exists (select 1 from public.movimientos_puntos where perfil_id = a1)
              and (select perfil_id from public.direcciones where id = d1) = cu
         then 'OK' else 'FALLA ' || r::text end;
  res := res || chr(10) || 'T11 queda registrado en cambios_cliente: ' ||
    case when exists (select 1 from public.cambios_cliente where perfil_id = cu and antes->>'motivo' = 'compra_como_invitado'
                         and (antes->>'invitado_id')::uuid = a1) then 'OK' else 'FALLA' end;

  -- T12: repetir no hace nada y la vuelta ya no ofrece crear cuenta
  perform set_config('role', 'authenticated', true);
  r := public.reclamar_pedidos_invitado();
  res := res || chr(10) || 'T12 repetir no traspasa nada y la vuelta ya no ofrece crear cuenta: ' ||
    case when (r->>'pedidos')::int = 0 and not (public.pedido_vuelta(p1)->>'invitado')::boolean then 'OK' else 'FALLA ' || r::text end;

  raise exception 'PRUEBA EN SECO 17 (todo se deshace): %', res;
end $do$;
