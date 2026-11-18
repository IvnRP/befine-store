-- PRUEBA EN SECO de la migración 15 (despacho desde $7.000) — Befine Store
-- Uso: pegar en UNA misma consulta (1) 20261117_15_despacho_desde_7000.sql y (2) este archivo.
-- Termina SIEMPRE con un error intencional: todo se deshace. Busca FALLA: no debería aparecer.
do $do$
declare
  cli uuid := gen_random_uuid(); vb uuid; pr int; j jsonb; minimo int; n_bajo int; n_sobre int;
  quil jsonb := '{"calle":"Prueba","numero":"15","comuna":"Quilicura"}';
  huec jsonb := '{"calle":"Prueba","numero":"15","comuna":"Huechuraba"}';
  k    jsonb := '{"nombre":"Cliente Quince","telefono":"9 1515 0015","email":"cliente15@correo.cl","acepta_terminos":true}';
  res  text := 'RESULTADOS';
begin
  select vp.id, pv.precio into vb, pr from public.variantes_producto vp
    join public.precios_variante pv on pv.variante_id = vp.id and pv.nivel_precio_id = 1
   where vp.sku = 'BEF-REC-20-BEFINE';
  select valor::int into minimo from public.parametros where clave = 'envio_gratis_minimo';
  n_bajo  := greatest(ceil(minimo::numeric / pr)::int - 1, 1);   -- cantidad que queda bajo el mínimo
  n_sobre := ceil(minimo::numeric / pr)::int;                    -- cantidad que llega al mínimo
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous)
    values (cli, 'cliente15@correo.cl', '{"nombre":"Cliente Quince"}', false);

  res := res || chr(10) || 'T01 ninguna zona activa con despacho $0: ' ||
         case when not exists (select 1 from public.zonas_despacho where activo and costo_despacho = 0) then 'OK' else 'FALLA' end;

  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', n_bajo)), quil, k);
  res := res || chr(10) || 'T02 Quilicura bajo $' || minimo || ' (subtotal ' || (j->>'subtotal') || ') cobra $2.500: ' ||
         case when (j->>'costo_despacho')::int = 2500 and (j->>'total')::int = (j->>'subtotal')::int + 2500 then 'OK' else 'FALLA ' || j::text end;

  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', n_sobre)), quil, k);
  res := res || chr(10) || 'T03 Quilicura desde $' || minimo || ' (subtotal ' || (j->>'subtotal') || ') despacho gratis: ' ||
         case when (j->>'costo_despacho')::int = 0 and (j->>'total')::int = (j->>'subtotal')::int then 'OK' else 'FALLA ' || j::text end;

  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', n_bajo)), huec, k);
  res := res || chr(10) || 'T04 Huechuraba bajo el mínimo sigue en $2.500: ' ||
         case when (j->>'costo_despacho')::int = 2500 then 'OK' else 'FALLA ' || j::text end;

  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', n_sobre)), huec, k);
  res := res || chr(10) || 'T05 Huechuraba desde el mínimo, despacho gratis: ' ||
         case when (j->>'costo_despacho')::int = 0 then 'OK' else 'FALLA ' || j::text end;
  perform set_config('role', 'none', true);

  res := res || chr(10) || 'T06 el pedido guarda la versión 2026-11-17 de los textos legales: ' ||
         case when (select terminos_version from public.pedidos where id = (j->>'id')::uuid) = '2026-11-17' then 'OK' else 'FALLA' end;

  raise exception 'PRUEBA EN SECO 15 (todo se deshace): %', res;
end $do$;
