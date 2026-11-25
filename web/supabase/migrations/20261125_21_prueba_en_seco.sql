-- PRUEBA EN SECO de la migración 21 (pedidos fuera de la página) — Befine Store
-- Requiere: 01 a 20 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261125_21_pedidos_fuera_pagina.sql y (2) este
-- archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace (no queda ningún
-- pedido, dirección, stock ni boleta de prueba).
-- Muestra T01..T15. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  adm uuid := gen_random_uuid();   -- dueño (admin)
  cho uuid := gen_random_uuid();   -- chofer
  cli uuid := gen_random_uuid();   -- cliente de la web
  vb uuid; pr int; st0 int; st1 int; j jsonb; r jsonb; pm uuid; pg uuid; n int; msg text; t text;
  hoy date := (now() at time zone 'America/Santiago')::date;
  cli_ws jsonb := '{"canal":"whatsapp","nombre":"Juan Pérez","telefono":"9 2101 2101"}';
  dir    jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura","referencia":"Portón verde"}';
  efe    jsonb := '{"metodo":"efectivo","estado":"por_cobrar"}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  select precio into pr from public.precios_variante where variante_id = vb and nivel_precio_id = 1;
  update public.variantes_producto set controla_stock = true, stock = 10 where id = vb;
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (adm, 'admin21@correo.cl', '{"nombre":"Admin"}', false), (cho, 'chofer21@correo.cl', '{"nombre":"Chofer"}', false),
    (cli, 'cli21@correo.cl', '{"nombre":"Cli"}', false);
  update public.perfiles set rol = 'admin' where id = adm;
  update public.perfiles set rol = 'chofer' where id = cho;

  res := res || chr(10) || 'T01 permiso pedidos.registrar creado y asignado al chofer: ' ||
    case when exists (select 1 from public.rol_permisos where rol_id = 'chofer' and permiso = 'pedidos.registrar')
         then 'OK' else 'FALLA' end;

  -- T02: un cliente no puede registrar pedidos
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin perform public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe);
        msg := 'FALLA (pudo)';
  exception when others then msg := case when sqlstate = '42501' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T02 un cliente no puede registrar pedidos fuera de la página: ' || msg;

  -- T03: el chofer registra un pedido por WhatsApp, por cobrar en efectivo (2 recargas: bajo el mínimo, paga despacho)
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  j := public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 2)), efe,
         null, null, null, 'Dejar con el conserje');
  pm := (j->>'id')::uuid;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T03 pedido por WhatsApp: En preparación, sin cuenta, por cobrar, para hoy: ' ||
    case when exists (select 1 from public.pedidos where id = pm and estado = 'en_preparacion' and perfil_id is null
                       and canal = 'whatsapp' and metodo_pago = 'efectivo' and cobro_estado = 'por_cobrar'
                       and fecha_entrega = hoy and creado_por = cho and cobrado_at is null and puntos_ganados = 0)
          and exists (select 1 from public.historial_pedido where pedido_id = pm and estado_nuevo = 'en_preparacion'
                       and cambiado_por = cho and nota like 'Pedido fuera de la página (whatsapp)%')
         then 'OK' else 'FALLA ' || j::text end;

  -- T04: precio y despacho los pone el servidor; el stock se descuenta
  select stock into st1 from public.variantes_producto where id = vb;
  res := res || chr(10) || 'T04 precio del catálogo + despacho $2.500 bajo el mínimo y stock descontado: ' ||
    case when (j->>'subtotal')::int = 2 * pr and (j->>'costo_despacho')::int = 2500 and (j->>'total')::int = 2 * pr + 2500
              and exists (select 1 from public.detalle_pedido where pedido_id = pm and precio_unitario = pr and cantidad = 2)
              and st1 = 8
         then 'OK' else 'FALLA ' || j::text || ' stock=' || st1 end;

  -- T05: sobre el mínimo el despacho es gratis; pagado por transferencia queda cobrado
  perform set_config('role', 'authenticated', true);
  j := public.registrar_pedido_manual('{"canal":"llamada","nombre":"Ana","telefono":"9 2102 2102","email":"ana21@correo.cl"}', dir,
         jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), '{"metodo":"transferencia","estado":"pagado"}');
  pg := (j->>'id')::uuid;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T05 despacho gratis desde el mínimo y transferencia ya pagada: ' ||
    case when (j->>'costo_despacho')::int = 0
              and exists (select 1 from public.pedidos where id = pg and cobro_estado = 'pagado' and cobrado_at is not null and cobrado_por = cho)
         then 'OK' else 'FALLA ' || j::text end;

  -- T06: descuento sin motivo o mayor que el total se rechaza; con motivo se aplica
  perform set_config('role', 'authenticated', true);
  t := '';
  begin perform public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe,
                  null, '{"descuento":500}'); t := t || 'sin motivo pasó; ';
  exception when others then null; end;
  begin perform public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe,
                  null, '{"descuento":999999,"motivo":"regalo"}'); t := t || 'mayor que total pasó; ';
  exception when others then null; end;
  j := public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe,
         null, '{"descuento":500,"motivo":"Cliente antiguo"}');
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T06 descuento con motivo obligatorio y nunca mayor que el total: ' ||
    case when t = '' and (j->>'descuento')::int = 500 and (j->>'total')::int = pr + 2500 - 500
              and exists (select 1 from public.pedidos where id = (j->>'id')::uuid and descuento_motivo = 'Cliente antiguo')
         then 'OK' else 'FALLA ' || t || j::text end;

  -- T07: datos inválidos se rechazan (comuna sin despacho, celular, canal web, sin productos, medio de pago)
  perform set_config('role', 'authenticated', true);
  t := ''; n := 0;
  begin perform public.registrar_pedido_manual(cli_ws, '{"calle":"X","comuna":"Las Condes"}', jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe); t := t || 'comuna; ';
  exception when others then n := n + 1; end;
  begin perform public.registrar_pedido_manual('{"canal":"whatsapp","nombre":"Juan","telefono":"123"}', dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe); t := t || 'celular; ';
  exception when others then n := n + 1; end;
  begin perform public.registrar_pedido_manual('{"canal":"web","nombre":"Juan","telefono":"9 2101 2101"}', dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe); t := t || 'canal web; ';
  exception when others then n := n + 1; end;
  begin perform public.registrar_pedido_manual(cli_ws, dir, '[]', efe); t := t || 'sin productos; ';
  exception when others then n := n + 1; end;
  begin perform public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), '{"metodo":"cheque","estado":"pagado"}'); t := t || 'medio; ';
  exception when others then n := n + 1; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T07 se rechazan comuna sin despacho, celular inválido, canal web, sin productos y medio no válido: ' ||
    case when n = 5 then 'OK' else 'FALLA (' || t || ')' end;

  -- T08: la fecha va de hoy a 45 días
  perform set_config('role', 'authenticated', true);
  t := '';
  begin perform public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe,
                  jsonb_build_object('fecha', hoy - 1)); t := 'ayer pasó';
  exception when others then null; end;
  j := public.registrar_pedido_manual(cli_ws, dir, jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), efe,
         jsonb_build_object('fecha', hoy + 1));
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T08 fecha de entrega desde hoy (mañana sí, ayer no): ' ||
    case when t = '' and (j->>'fecha_entrega')::date = hoy + 1 then 'OK' else 'FALLA ' || t end;

  -- T09: el chofer lo ve en la ruta de hoy con canal, total y cobro
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  r := public.reparto_del_dia(hoy);
  res := res || chr(10) || 'T09 aparece en el reparto de hoy con canal, total y "por cobrar": ' ||
    case when exists (select 1 from jsonb_array_elements(r) e where (e->>'id')::uuid = pm and e->>'canal' = 'whatsapp'
                       and (e->>'total')::int = 2 * pr + 2500 and e->>'cobro_estado' = 'por_cobrar'
                       and e->>'metodo_pago' = 'efectivo' and e->>'calle' = 'Los Tailandeses')
         then 'OK' else 'FALLA' end;

  -- T10: "En camino" avisa el total a pagar y el medio
  r := public.marcar_reparto(pm, 'en_ruta');
  res := res || chr(10) || 'T10 "En camino": el aviso dice el total a pagar en efectivo: ' ||
    case when r->>'mensaje' like '%Total a pagar: $' || replace(to_char(2 * pr + 2500, 'FM999,999,999'), ',', '.') || ' (efectivo)%'
         then 'OK' else 'FALLA ' || (r->>'mensaje') end;

  -- T11: el chofer registra el cobro (una sola vez) y el aviso de entrega dice "Total pagado"
  r := public.cobrar_pedido(pm, null);
  j := public.cobrar_pedido(pm, null);
  r := public.marcar_reparto(pm, 'entregado');
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T11 cobro registrado una vez y aviso "Total pagado (efectivo)": ' ||
    case when (j->>'ya_cobrado')::boolean
              and exists (select 1 from public.pedidos where id = pm and cobro_estado = 'pagado' and cobrado_por = cho and estado = 'entregado')
              and r->>'mensaje' like '%Total pagado: $%(efectivo)%'
         then 'OK' else 'FALLA ' || (r->>'mensaje') end;

  -- T12: solo el admin corrige el monto, con motivo y auditoría
  perform set_config('role', 'authenticated', true);
  begin perform public.ajustar_pedido_manual(pg, 1000, 'Error de precio'); msg := 'FALLA (el chofer pudo)';
  exception when others then msg := case when sqlstate = '42501' then 'chofer no OK' else 'FALLA ' || sqlerrm end; end;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  r := public.ajustar_pedido_manual(pg, 1000, 'Error de precio');
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T12 solo el admin corrige el monto (con motivo y en el historial): ' ||
    case when msg = 'chofer no OK' and (r->>'total')::int = 3 * pr - 1000
              and exists (select 1 from public.historial_pedido where pedido_id = pg and nota like 'Monto corregido:%Error de precio%' and cambiado_por = adm)
         then 'OK' else 'FALLA ' || msg || ' ' || r::text end;

  -- T13: no suman puntos ni aparecen a ningún cliente; el admin los ve
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  select count(*) into n from public.pedidos where canal <> 'web';
  msg := case when n = 0 then 'cliente no ve OK' else 'FALLA cliente ve ' || n end;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  select count(*) into n from public.pedidos where canal <> 'web';
  msg := msg || case when n >= 4 then ', admin ve OK' else ', FALLA admin ve ' || n end;
  perform set_config('role', 'none', true);
  select count(*) into n from public.movimientos_puntos where pedido_id in (pm, pg);
  msg := msg || case when n = 0 then ', sin puntos OK' else ', FALLA puntos' end;
  res := res || chr(10) || 'T13 sin puntos del Club, invisibles para clientes y visibles para el admin: ' || msg;

  -- T14: cuenta como boleta por subir: se registra su boleta igual que un pedido web; un pedido web sin perfil no existe
  insert into storage.objects (bucket_id, name) values ('documentos', pg::text || '/boleta-21001.pdf');
  perform set_config('role', 'authenticated', true);
  r := public.registrar_documento(pg, 'boleta', 21001);
  perform set_config('role', 'none', true);
  begin insert into public.pedidos (perfil_id, nivel_precio_id, canal) values (null, 1, 'web'); msg := 'FALLA (web sin perfil)';
  exception when check_violation then msg := 'OK'; end;
  res := res || chr(10) || 'T14 su boleta se registra como la de la web; un pedido web siempre exige cuenta: ' ||
    case when (r->>'ok')::boolean and msg = 'OK' then 'OK' else 'FALLA ' || r::text || ' ' || msg end;

  -- T15: con boleta emitida no se corrige el monto; el admin puede anularlo y ya no se cobra
  perform set_config('role', 'authenticated', true);
  begin perform public.ajustar_pedido_manual(pg, 0, 'Otro'); msg := 'FALLA (corrigió con boleta)';
  exception when others then msg := 'con boleta no corrige OK'; end;
  update public.pedidos set estado = 'cancelado' where id = pg;
  get diagnostics n = row_count;
  begin perform public.cobrar_pedido(pg, null); msg := msg || ', FALLA (cobró anulado)';
  exception when others then msg := msg || ', anulado no se cobra OK'; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T15 con boleta no se corrige el monto y un pedido anulado no se cobra: ' ||
    case when n = 1 then msg else 'FALLA no anuló' end;

  raise exception 'PRUEBA EN SECO 21 (todo se deshace): %', res;
end $do$;
