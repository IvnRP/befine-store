-- PRUEBA EN SECO de la migración 18 (Trae un amigo a prueba de abusos) — Befine Store
-- Requiere: 01 a 17 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261121_18_referidos_seguros.sql y (2) este
-- archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace.
-- Muestra T01..T09. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  r   uuid := gen_random_uuid();   -- quien invita
  a   uuid := gen_random_uuid();   -- amiga A (compra real)
  b   uuid := gen_random_uuid();   -- amiga B (paga y cancela antes de recibir)
  c1  uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); c3 uuid := gen_random_uuid();   -- para el tope
  s   uuid := gen_random_uuid();   -- "amiga" que es la misma persona (mismo correo que r)
  vb uuid; j jsonb; pa uuid; pa2 uuid; pb uuid; ps uuid; s0 int; s1 int; n int; ok boolean;
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (r,  'invita18@correo.cl', '{"nombre":"Invita"}', false),
    (a,  'amiga18a@correo.cl', '{"nombre":"Amiga A"}', false),
    (b,  'amiga18b@correo.cl', '{"nombre":"Amiga B"}', false),
    (c1, 'amiga18c1@correo.cl', '{"nombre":"C1"}', false),
    (c2, 'amiga18c2@correo.cl', '{"nombre":"C2"}', false),
    (c3, 'amiga18c3@correo.cl', '{"nombre":"C3"}', false),
    (s,  'otra18@correo.cl', '{"nombre":"Misma"}', false);
  insert into public.referidos (referido_id, referente_id) values (a, r), (b, r), (c1, r), (c2, r), (c3, r), (s, r);
  update public.parametros set valor = '2' where clave = 'club_referido_tope_mes';   -- tope chico para probarlo

  -- Cada amiga crea su pedido con su cuenta
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  pa  := (public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir,
          '{"nombre":"Amiga A","telefono":"9 1801 1801","email":"amiga18a@correo.cl","acepta_terminos":true}')->>'id')::uuid;
  pa2 := (public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir,
          '{"nombre":"Amiga A","telefono":"9 1801 1801","email":"amiga18a@correo.cl","acepta_terminos":true}')->>'id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  pb  := (public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir,
          '{"nombre":"Amiga B","telefono":"9 1802 1802","email":"amiga18b@correo.cl","acepta_terminos":true}')->>'id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', s, 'role', 'authenticated')::text, true);
  ps  := (public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir,
          '{"nombre":"Misma","telefono":"9 1803 1803","email":"invita18@correo.cl","acepta_terminos":true}')->>'id')::uuid;

  -- Servidor: Mercado Pago confirma los pagos
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '{}', true);
  perform public.confirmar_pago(pa, 'PRUEBA-18-A', (select total from public.pedidos where id = pa));
  perform public.confirmar_pago(pb, 'PRUEBA-18-B', (select total from public.pedidos where id = pb));
  perform public.confirmar_pago(ps, 'PRUEBA-18-S', (select total from public.pedidos where id = ps));

  select puntos_saldo into s0 from public.perfiles where id = r;
  res := res || chr(10) || 'T01 al PAGAR el pedido de la amiga todavía no hay puntos de referido: ' ||
    case when s0 = 0 and (select premiado_at from public.referidos where referido_id = a) is null then 'OK' else 'FALLA saldo=' || s0 end;

  update public.pedidos set estado = 'en_ruta'   where id = pa;
  update public.pedidos set estado = 'entregado' where id = pa;
  res := res || chr(10) || 'T02 al ENTREGARSE: quien invita +10 y la amiga recibe su bienvenida ligada a su pedido: ' ||
    case when (select puntos_saldo from public.perfiles where id = r) = 10
              and exists (select 1 from public.movimientos_puntos where perfil_id = a and pedido_id = pa and puntos = 10 and descripcion like 'Trae un amigo%')
              and (select pedido_id from public.referidos where referido_id = a) = pa then 'OK' else 'FALLA' end;

  perform public.confirmar_pago(pa2, 'PRUEBA-18-A2', (select total from public.pedidos where id = pa2));
  update public.pedidos set estado = 'en_ruta'   where id = pa2;
  update public.pedidos set estado = 'entregado' where id = pa2;
  res := res || chr(10) || 'T03 un segundo pedido de la misma amiga no vuelve a premiar: ' ||
    case when (select puntos_saldo from public.perfiles where id = r) = 10 then 'OK' else 'FALLA' end;

  select puntos_saldo into s1 from public.perfiles where id = a;
  update public.pedidos set estado = 'cancelado' where id = pa;
  res := res || chr(10) || 'T04 si el pedido premiado se cancela, se quitan los 10 a los dos y la invitación queda pendiente: ' ||
    case when (select puntos_saldo from public.perfiles where id = r) = 0
              and not exists (select 1 from public.movimientos_puntos m where m.perfil_id = a and m.pedido_id = pa
                                and m.descripcion like 'Pedido #% cancelado' and m.puntos > -10)
              and (select premiado_at is null and revertido_at is not null from public.referidos where referido_id = a)
         then 'OK' else 'FALLA r=' || (select puntos_saldo from public.perfiles where id = r) end;

  update public.pedidos set estado = 'cancelado' where id = pb;     -- pagado y cancelado sin recibirlo
  res := res || chr(10) || 'T05 pagar y cancelar antes de recibir no da puntos de referido: ' ||
    case when (select puntos_saldo from public.perfiles where id = r) = 0
              and (select premiado_at from public.referidos where referido_id = b) is null then 'OK' else 'FALLA' end;

  update public.pedidos set estado = 'en_ruta'   where id = ps;
  update public.pedidos set estado = 'entregado' where id = ps;
  res := res || chr(10) || 'T06 invitarse a sí mismo (mismo correo) no da puntos a nadie: ' ||
    case when (select puntos_saldo from public.perfiles where id = r) = 0
              and (select puntos_referente from public.referidos where referido_id = s) = 0
              and not exists (select 1 from public.movimientos_puntos where perfil_id = s and descripcion like 'Trae un amigo%')
         then 'OK' else 'FALLA' end;

  -- Tope (2 al mes): 3 amigas reciben su pedido este mes
  perform set_config('role', 'authenticated', true);
  for n in 1..3 loop
    perform set_config('request.jwt.claims', json_build_object('sub', (array[c1, c2, c3])[n], 'role', 'authenticated')::text, true);
    j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir,
           jsonb_build_object('nombre', 'C' || n, 'telefono', '9 181' || n || ' 181' || n,
                              'email', 'amiga18c' || n || '@correo.cl', 'acepta_terminos', true));
    perform set_config('role', 'none', true); perform set_config('request.jwt.claims', '{}', true);
    perform public.confirmar_pago((j->>'id')::uuid, 'PRUEBA-18-C' || n, (j->>'total')::int);
    update public.pedidos set estado = 'en_ruta'   where id = (j->>'id')::uuid;
    update public.pedidos set estado = 'entregado' where id = (j->>'id')::uuid;
    perform set_config('role', 'authenticated', true);
  end loop;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T07 con tope 2 al mes, quien invita recibe 20 (no 30) y la 3.ª amiga igual su bienvenida: ' ||
    case when (select puntos_saldo from public.perfiles where id = r) = 20
              and (select puntos_referente from public.referidos where referido_id = c3) = 0
              and exists (select 1 from public.movimientos_puntos where perfil_id = c3 and descripcion like 'Trae un amigo%')
         then 'OK' else 'FALLA r=' || (select puntos_saldo from public.perfiles where id = r) end;

  -- Quien invita gasta sus puntos y luego se cancela un pedido que lo premió: no queda negativo
  perform public._mover_puntos(r, 'canje', -20, 'Prueba: canje');
  update public.pedidos set estado = 'cancelado' where id = (select pedido_id from public.referidos where referido_id = c1);
  res := res || chr(10) || 'T08 si quien invita ya gastó sus puntos, la cancelación no deja saldo negativo: ' ||
    case when (select puntos_saldo from public.perfiles where id = r) = 0 then 'OK' else 'FALLA' end;

  res := res || chr(10) || 'T09 nueva versión de los Términos 2026-11-21 y tope por defecto 10 en la migración: ' ||
    case when (select valor from public.parametros where clave = 'terminos_version') = '2026-11-21' then 'OK' else 'FALLA' end;

  raise exception 'PRUEBA EN SECO 18 (todo se deshace): %', res;
end $do$;
