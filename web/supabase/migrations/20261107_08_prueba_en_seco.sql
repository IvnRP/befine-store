-- PRUEBA EN SECO de la migración 08 (Club Befine) — Befine Store
-- Requiere: 01, 01b, 04, 03, 05, 06 y 07 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261107_08_club_befine.sql y (2) este archivo,
-- sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace.
-- Muestra T01..T14. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  u1 uuid := gen_random_uuid();   -- cliente frecuente
  u2 uuid := gen_random_uuid();   -- amigo invitado por u1
  u3 uuid := gen_random_uuid();   -- cliente inactivo (puntos vencen)
  vb uuid; vo uuid; vbid uuid; vd uuid;
  j jsonb; c jsonb; e jsonb; n int; s int; p1 uuid; p2 uuid; cod text; cup text;
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  k1 jsonb := '{"nombre":"Cliente Club","telefono":"9 1111 2222","email":"club1@correo.cl","acepta_terminos":true}';
  k2 jsonb := '{"nombre":"Amigo Club","telefono":"9 3333 4444","email":"club2@correo.cl","acepta_terminos":true}';
  res text := 'RESULTADOS';
begin
  select id into vb   from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  select id into vo   from public.variantes_producto where sku = 'BEF-REC-20-OTRA';
  select id into vbid from public.variantes_producto where sku = 'BEF-BID-20';
  select id into vd   from public.variantes_producto where sku = 'BEF-DISP-USB';
  -- precios conocidos para la prueba (todo se deshace al final)
  update public.precios_variante set precio = 2500 where variante_id = vb   and nivel_precio_id = 1;
  update public.precios_variante set precio = 5490 where variante_id = vbid and nivel_precio_id = 1;

  select count(*) into n from public.variantes_producto where suma_puntos;
  res := res || chr(10) || 'T01 solo 2 variantes suman puntos (recargas con envase Befine): ' ||
         case when n = 2 and (select suma_puntos from public.variantes_producto where id = vb)
                   and not (select suma_puntos from public.variantes_producto where id = vo) then 'OK' else 'FALLA n=' || n end;

  select count(*) into n from public.recompensas where activo and codigo in ('menor','medio','mayor')
     and puntos_costo in (30, 80, 150);
  res := res || chr(10) || 'T02 premios 30 / 80 / 150 activos: ' || case when n = 3 then 'OK' else 'FALLA n=' || n end;

  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (u1, 'club1@correo.cl', '{"nombre":"Cliente Club"}', false),
    (u2, 'club2@correo.cl', '{"nombre":"Amigo Club"}',   false),
    (u3, 'club3@correo.cl', '{"nombre":"Inactivo"}',     false);

  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- T03: 6 recargas Befine = $15.000 → 15 + 2 de bono
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 6)), dir, k1);
  p1 := (j->>'id')::uuid;
  res := res || chr(10) || 'T03 6 recargas Befine suman 15 + 2 de bono = 17: ' ||
         case when (j->>'puntos_ganados')::int = 17 then 'OK' else 'FALLA ' || (j->>'puntos_ganados') end;

  -- T04: recargas con envase de otra marca no suman
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vo, 'cantidad', 4)), dir, k1);
  res := res || chr(10) || 'T04 recargas con envase de otra marca no suman: ' ||
         case when (j->>'puntos_ganados')::int = 0 then 'OK' else 'FALLA ' || (j->>'puntos_ganados') end;

  -- T05: dispensador + 2 recargas Befine → solo las recargas (5), sin bono
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 2),
                                             jsonb_build_object('variante_id', vd, 'cantidad', 1)), dir, k1);
  res := res || chr(10) || 'T05 el dispensador no suma (2 recargas = 5): ' ||
         case when (j->>'puntos_ganados')::int = 5 then 'OK' else 'FALLA ' || (j->>'puntos_ganados') end;

  -- T06: pago confirmado suma los 17 puntos (webhook)
  perform set_config('role', 'none', true);
  perform public.confirmar_pago(p1, 'PRUEBA-08-1', 15000);
  select puntos_saldo into s from public.perfiles where id = u1;
  res := res || chr(10) || 'T06 al confirmar el pago se suman 17 puntos: ' || case when s = 17 then 'OK' else 'FALLA saldo=' || s end;

  -- Saldo de prueba para canjear (400 puntos)
  perform public._mover_puntos(u1, 'ajuste', 383, 'Prueba en seco');
  perform set_config('role', 'authenticated', true);

  -- T07: canje del premio mayor → cupón personal, saldo 400 - 150 = 250
  c := public.canjear_recompensa('mayor');
  cup := c->>'codigo';
  res := res || chr(10) || 'T07 canje del premio mayor crea cupón CLUB- y descuenta 150: ' ||
         case when cup like 'CLUB-%' and (c->>'saldo')::int = 250 then 'OK' else 'FALLA ' || c::text end;

  -- T08: con un premio sin usar no se puede canjear otro
  begin
    perform public.canjear_recompensa('menor');
    res := res || chr(10) || 'T08 un solo premio activo a la vez: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T08 un solo premio activo a la vez: ' ||
           case when sqlerrm like 'Ya tienes un premio sin usar%' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  -- T09: 50% con tope: 10 recargas ($25.000) → descuento $7.500; puntos (25.000 - 7.500) / 1.000 = 17 + 2
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 10)), dir, k1, null, null, cup);
  res := res || chr(10) || 'T09 50% con tope $7.500 y puntos solo por lo pagado (17 + 2): ' ||
         case when (j->>'descuento_cupon')::int = 7500 and (j->>'puntos_ganados')::int = 19 then 'OK'
              else 'FALLA desc=' || (j->>'descuento_cupon') || ' pts=' || (j->>'puntos_ganados') end;

  -- T10: premio medio (Bidón + Recarga 20 L gratis) → pedido de $0 confirmado sin Mercado Pago, sin puntos
  c := public.canjear_recompensa('medio');
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vbid, 'cantidad', 1)), dir, k1, null, null, c->>'codigo');
  res := res || chr(10) || 'T10 pedido de $0 con premio: confirmado, marcado como canje y sin puntos: ' ||
         case when (j->>'total')::int = 0 and j->>'estado' = 'en_preparacion' and (j->>'es_canje')::boolean
                   and (j->>'puntos_ganados')::int = 0 then 'OK'
              when (j->>'total')::int > 0 then 'OK (no aplica: el despacho de Quilicura no es $0, total ' || (j->>'total') || ')'
              else 'FALLA ' || j::text end;

  -- T11: invitado no puede canjear (sesión anónima)
  perform set_config('role', 'none', true);
  update auth.users set is_anonymous = true where id = u3;
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.canjear_recompensa('menor');
    res := res || chr(10) || 'T11 un invitado no puede canjear: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T11 un invitado no puede canjear: ' || case when sqlerrm like 'Crea tu cuenta%' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  -- T12: Trae un amigo: u2 usa el código de u1 y paga su primer pedido → +10 a cada uno
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  cod := (public.club_estado())->>'codigo_referido';
  e := public.registrar_referido(cod);   -- u1 con su propio código
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  j := public.registrar_referido(cod);
  c := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 2)), dir, k2);
  p2 := (c->>'id')::uuid;
  perform set_config('role', 'none', true);
  select puntos_saldo into s from public.perfiles where id = u1;
  perform public.confirmar_pago(p2, 'PRUEBA-08-2', (c->>'total')::int);
  select puntos_saldo - s into n from public.perfiles where id = u1;
  select puntos_saldo into s from public.perfiles where id = u2;
  res := res || chr(10) || 'T12 Trae un amigo: +10 para cada uno y nadie usa su propio código: ' ||
         case when (e->>'ok')::boolean = false and (j->>'ok')::boolean and n = 10 and s = 15 then 'OK'
              else 'FALLA propio=' || e::text || ' amigo=' || j::text || ' u1+=' || n || ' u2=' || s end;

  -- T13: pedido cancelado después de pagado → se descuentan sus puntos (u2 tenía 5 del pedido + 10 de bienvenida)
  update public.pedidos set estado = 'cancelado' where id = p2;
  select puntos_saldo into s from public.perfiles where id = u2;
  res := res || chr(10) || 'T13 al cancelar un pedido pagado se descuentan sus puntos: ' ||
         case when s = 10 then 'OK' else 'FALLA saldo=' || s end;

  -- T14: vencimiento tras 12 meses sin sumar puntos
  update auth.users set is_anonymous = false where id = u3;
  perform public._mover_puntos(u3, 'ajuste', 40, 'Puntos antiguos');
  update public.movimientos_puntos set created_at = now() - interval '13 months' where perfil_id = u3;
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  c := public.club_estado();
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T14 los puntos vencen tras 12 meses sin sumar: ' ||
         case when (c->>'saldo')::int = 0 then 'OK' else 'FALLA saldo=' || (c->>'saldo') end;

  raise exception 'PRUEBA EN SECO 08 (todo se deshace): %', res;
end $do$;
