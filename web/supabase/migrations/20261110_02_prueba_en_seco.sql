-- PRUEBA EN SECO de la migración 02 (reparto, WhatsApp y roles) — Befine Store
-- Requiere: 01, 01b, 04, 03, 05, 06, 07 y 08 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261110_02_reparto_roles.sql y (2) este archivo,
-- sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace.
-- Muestra T01..T13. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  adm uuid := gen_random_uuid();   -- administrador
  ad2 uuid := gen_random_uuid();   -- segundo administrador
  cho uuid := gen_random_uuid();   -- chofer
  cli uuid := gen_random_uuid();   -- cliente
  vb uuid; p1 uuid; p2 uuid; j jsonb; r jsonb; n int; t text; hoy date := (now() at time zone 'America/Santiago')::date;
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura","referencia":"Portón negro"}';
  k   jsonb := '{"nombre":"Camila Reparto","telefono":"9 5555 6666","email":"reparto.cli@correo.cl","acepta_terminos":true}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (adm, 'reparto.adm@correo.cl', '{"nombre":"Admin Prueba"}',  false),
    (ad2, 'reparto.ad2@correo.cl', '{"nombre":"Admin Dos"}',     false),
    (cho, 'reparto.cho@correo.cl', '{"nombre":"Chofer Prueba"}', false),
    (cli, 'reparto.cli@correo.cl', '{"nombre":"Camila Reparto"}', false);
  update public.perfiles set rol = 'admin'  where id in (adm, ad2);
  update public.perfiles set rol = 'chofer' where id = cho;

  select count(*) into n from public.rol_permisos where rol_id = 'chofer' and permiso = 'pedidos.repartir';
  res := res || chr(10) || 'T01 el chofer reparte y ya no ve todos los pedidos: ' ||
         case when n = 1 and not exists (select 1 from public.rol_permisos where rol_id = 'chofer' and permiso = 'pedidos.ver')
              then 'OK' else 'FALLA' end;

  -- Pedido pagado (p1) y pedido sin pagar (p2), ambos para hoy
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j  := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 6)), dir, k);
  p1 := (j->>'id')::uuid;
  p2 := ((public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 2)), dir, k))->>'id')::uuid;
  perform set_config('role', 'none', true);
  perform public.confirmar_pago(p1, 'PRUEBA-02-1', (j->>'total')::int);
  update public.pedidos set fecha_entrega = hoy where id in (p1, p2);

  -- T02: el chofer ve el pagado de hoy con dirección y productos, y NO el que no está pagado
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  r := public.reparto_del_dia(hoy);
  select count(*) into n from jsonb_array_elements(r) e where (e->>'id')::uuid = p1
     and e->>'calle' = 'Los Tailandeses' and e->>'referencia' = 'Portón negro' and jsonb_array_length(e->'items') = 1;
  res := res || chr(10) || 'T02 el reparto trae el pedido pagado con dirección y productos: ' || case when n = 1 then 'OK' else 'FALLA' end;
  select count(*) into n from jsonb_array_elements(r) e where (e->>'id')::uuid = p2;
  res := res || chr(10) || 'T03 un pedido sin pagar no aparece en el reparto: ' || case when n = 0 then 'OK' else 'FALLA' end;

  -- T04: el chofer ya no puede leer la tabla de pedidos directamente
  select count(*) into n from public.pedidos where id in (p1, p2);
  res := res || chr(10) || 'T04 el chofer no lee la tabla de pedidos (RLS): ' || case when n = 0 then 'OK' else 'FALLA filas=' || n end;

  -- T05: "En camino" → estado, teléfono y mensaje; queda en el historial con el chofer
  j := public.marcar_reparto(p1, 'en_ruta');
  perform set_config('role', 'none', true);
  select count(*) into n from public.historial_pedido
   where pedido_id = p1 and estado_nuevo = 'en_ruta' and cambiado_por = cho and nota = 'Reparto: en camino';
  res := res || chr(10) || 'T05 "En camino": WhatsApp listo y queda en el historial con el chofer: ' ||
         case when j->>'estado' = 'en_ruta' and j->>'telefono' = '56955556666' and j->>'mensaje' like '%en camino%'
                   and j->>'mensaje' like '%#' || (j->>'numero') || '%' and n = 1 then 'OK' else 'FALLA ' || j::text || ' hist=' || n end;
  perform set_config('role', 'authenticated', true);

  -- T06: no se puede repetir ni saltar pasos
  begin
    perform public.marcar_reparto(p1, 'en_ruta');
    res := res || chr(10) || 'T06 no se marca dos veces "En camino": FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T06 no se marca dos veces "En camino": ' || case when sqlerrm like 'Solo un pedido%' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  -- T07: "Entregado" y reenviar el aviso
  j := public.marcar_reparto(p1, 'entregado');
  r := public.aviso_reparto(p1);
  res := res || chr(10) || 'T07 "Entregado" con resumen y se puede reenviar el aviso: ' ||
         case when j->>'estado' = 'entregado' and j->>'mensaje' like '%entregado%' and j->>'mensaje' like '%Total pagado%'
                   and r->>'mensaje' = j->>'mensaje' then 'OK' else 'FALLA ' || j::text end;

  -- T08: un cliente no puede ver ni marcar repartos
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin
    perform public.reparto_del_dia(hoy);
    res := res || chr(10) || 'T08 un cliente no ve ni marca repartos: FALLA (se permitió)';
  exception when insufficient_privilege then
    begin
      perform public.marcar_reparto(p1, 'entregado');
      res := res || chr(10) || 'T08 un cliente no ve ni marca repartos: FALLA (marcó)';
    exception when insufficient_privilege then
      res := res || chr(10) || 'T08 un cliente no ve ni marca repartos: OK';
    end;
  end;

  -- T09: el admin busca una cuenta por correo; el chofer no puede
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  r := public.buscar_usuario('REPARTO.CLI@correo.cl');
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  begin
    perform public.buscar_usuario('reparto.cli@correo.cl');
    t := 'FALLA (el chofer buscó)';
  exception when insufficient_privilege then t := 'OK';
  end;
  res := res || chr(10) || 'T09 solo el admin busca cuentas por correo: ' ||
         case when (r->>'id')::uuid = cli and t = 'OK' then 'OK' else 'FALLA ' || coalesce(r::text, 'null') || ' ' || t end;

  -- T10: el admin asigna el rol chofer y queda auditado
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  r := public.asignar_rol(cli, 'chofer');
  perform set_config('role', 'none', true);
  select count(*) into n from public.cambios_rol where perfil_id = cli and rol_anterior = 'cliente' and rol_nuevo = 'chofer' and cambiado_por = adm;
  res := res || chr(10) || 'T10 el admin asigna el rol chofer y queda registrado: ' ||
         case when (r->>'ok')::boolean and n = 1 and (select rol from public.perfiles where id = cli) = 'chofer' then 'OK' else 'FALLA ' || r::text end;
  perform set_config('role', 'authenticated', true);

  -- T11: nadie cambia su propio rol
  begin
    perform public.asignar_rol(adm, 'cliente');
    res := res || chr(10) || 'T11 nadie cambia su propio rol: FALLA (se permitió)';
  exception when raise_exception then
    res := res || chr(10) || 'T11 nadie cambia su propio rol: ' || case when sqlerrm like 'No puedes cambiar tu propio rol%' then 'OK' else 'FALLA ' || sqlerrm end;
  end;

  -- T12: se puede quitar un admin si queda otro activo; el equipo lo lista con su correo
  r := public.asignar_rol(ad2, 'cliente');
  j := public.equipo();
  select count(*) into n from jsonb_array_elements(j) e where e->>'email' = 'reparto.cho@correo.cl' and e->>'rol' = 'chofer';
  res := res || chr(10) || 'T12 quitar un admin (queda otro) y listar el equipo con correo: ' ||
         case when (r->>'ok')::boolean and n = 1 then 'OK' else 'FALLA ' || r::text end;

  -- T13: un chofer no puede asignar roles
  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  begin
    perform public.asignar_rol(cli, 'admin');
    res := res || chr(10) || 'T13 un chofer no asigna roles: FALLA (se permitió)';
  exception when insufficient_privilege then
    res := res || chr(10) || 'T13 un chofer no asigna roles: OK';
  end;
  perform set_config('role', 'none', true);

  raise exception 'PRUEBA EN SECO 02 (todo se deshace): %', res;
end $do$;
