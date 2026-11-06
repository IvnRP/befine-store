-- PRUEBA EN SECO de la migración 05 (el stock nunca frena una venta) — Befine Store
-- Requiere: 01, 01b y 04 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor, en este orden y sin agregar
-- begin/commit: (1) 20261105_03_invitados_pago.sql, (2) 20261105_05_stock_sin_bloqueos.sql
-- y (3) este archivo. Ejecutar. Termina SIEMPRE con un error intencional: todo se
-- deshace. El texto del error muestra los resultados T01..T07. Busca la palabra
-- FALLA: no debería aparecer.

do $do$
declare
  u1    uuid := gen_random_uuid();
  v_bid uuid; v_rec uuid;
  p1 uuid; p2 uuid; t1 int; t2 int;
  j jsonb; n int; b boolean;
  res text := 'RESULTADOS';
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  c1  jsonb := '{"nombre":"Prueba Stock","telefono":"9 3333 4444","email":"stock@correo.cl"}';
begin
  -- ---------- Datos de prueba ----------
  select id into v_bid from public.variantes_producto where sku = 'BEF-BID-20';
  select id into v_rec from public.variantes_producto where sku = 'BEF-REC-12';
  update public.variantes_producto set controla_stock = true, stock = 0  where id = v_bid;   -- sin stock
  update public.variantes_producto set controla_stock = true, stock = 10 where id = v_rec;   -- con stock
  insert into auth.users (id, email, raw_user_meta_data) values (u1, 'stock@correo.cl', '{"nombre":"Prueba Stock"}');

  -- ---------- Como cliente ----------
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  begin
    j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', v_bid, 'cantidad', 2)), dir, c1, null, null, null, null);
    p1 := (j->>'id')::uuid; t1 := (j->>'total')::int;
    res := res || chr(10) || 'T01 producto con stock 0 se puede comprar: OK';
  exception when others then
    res := res || chr(10) || 'T01 producto con stock 0 se puede comprar: FALLA ' || sqlerrm;
  end;

  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', v_rec, 'cantidad', 3)), dir, c1, null, null, null, null);
  p2 := (j->>'id')::uuid; t2 := (j->>'total')::int;

  begin
    perform public.confirmar_pago(p1, 'PRUEBA-MP-1', t1, null, null);
    res := res || chr(10) || 'T02 el cliente no puede confirmar pagos: FALLA (se permitió)';
  exception when insufficient_privilege then
    res := res || chr(10) || 'T02 el cliente no puede confirmar pagos: OK';
  end;

  -- ---------- Servidor (webhook de Mercado Pago) ----------
  perform set_config('role', 'none', true);

  j := public.confirmar_pago(p1, 'PRUEBA-MP-1', t1, null, null);
  select sobreventa into b from public.pedidos where id = p1;
  select stock into n from public.variantes_producto where id = v_bid;
  res := res || chr(10) || 'T03 pago con stock insuficiente se confirma y queda marcado: ' ||
         case when (j->>'ok')::boolean and (j->>'sobreventa')::boolean and b then 'OK' else 'FALLA ' || j::text end;
  res := res || chr(10) || 'T04 el stock nunca queda bajo 0: ' || case when n = 0 then 'OK' else 'FALLA stock=' || n end;

  j := public.confirmar_pago(p2, 'PRUEBA-MP-2', t2, null, null);
  select sobreventa into b from public.pedidos where id = p2;
  select stock into n from public.variantes_producto where id = v_rec;
  res := res || chr(10) || 'T05 pago normal: descuenta stock (10-3=7) sin marcar sobreventa: ' ||
         case when (j->>'ok')::boolean and not b and n = 7 then 'OK' else 'FALLA ' || j::text || ' stock=' || n end;

  j := public.confirmar_pago(p2, 'PRUEBA-MP-2', t2, null, null);
  select stock into n from public.variantes_producto where id = v_rec;
  res := res || chr(10) || 'T06 notificación repetida no descuenta dos veces: ' ||
         case when (j->>'repetido')::boolean and n = 7 then 'OK' else 'FALLA ' || j::text || ' stock=' || n end;

  -- ---------- Un producto desactivado sigue sin poder comprarse ----------
  update public.variantes_producto set activo = false where id = v_bid;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', v_bid, 'cantidad', 1)), dir, c1, null, null, null, null);
    res := res || chr(10) || 'T07 producto desactivado no se puede comprar: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T07 producto desactivado no se puede comprar: ' ||
           case when sqlerrm like 'Un producto del carrito ya no está disponible%' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  raise exception 'PRUEBA EN SECO 05 (todo se deshace): %', res;
end $do$;
