-- PRUEBA EN SECO de la migración 10 (avisos sin emojis) — Befine Store
-- Uso: pegar en UNA misma consulta (1) 20261111_10_avisos_sin_emojis.sql y (2) este archivo.
-- Termina SIEMPRE con un error intencional: todo se deshace. Busca FALLA: no debería aparecer.
do $do$
declare
  cho uuid := gen_random_uuid(); cli uuid := gen_random_uuid(); vb uuid; p1 uuid; j jsonb; m1 text; m2 text;
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  k   jsonb := '{"nombre":"Camila Fuentes","telefono":"9 4444 3333","email":"aviso@correo.cl","acepta_terminos":true}';
  res text := 'RESULTADOS';
  -- true si el texto solo tiene letras latinas (con tildes y ñ), números, puntuación simple y saltos de línea
  sin_emojis constant text := '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ¡¿ .,:;!?()#$*/"\-' || chr(10) || ']*$';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (cho, 'aviso.cho@correo.cl', '{"nombre":"Chofer"}', false), (cli, 'aviso@correo.cl', '{"nombre":"Camila"}', false);
  update public.perfiles set rol = 'chofer' where id = cho;

  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 3)), dir, k);
  p1 := (j->>'id')::uuid;
  perform set_config('role', 'none', true);
  perform public.confirmar_pago(p1, 'PRUEBA-10-1', (j->>'total')::int);

  perform set_config('request.jwt.claims', json_build_object('sub', cho, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  m1 := (public.marcar_reparto(p1, 'en_ruta'))->>'mensaje';
  m2 := (public.marcar_reparto(p1, 'entregado'))->>'mensaje';
  perform set_config('role', 'none', true);

  res := res || chr(10) || 'T01 aviso "en camino" sin emojis: ' ||
         case when m1 ~ sin_emojis and m1 like '*Befine: tu pedido #% va en camino*%' and m1 like '%Hola, Camila.%' then 'OK' else 'FALLA ' || m1 end;
  res := res || chr(10) || 'T02 aviso "entregado" sin emojis, con productos y total: ' ||
         case when m2 ~ sin_emojis and m2 like '%fue entregado*%' and m2 like '%- 3 x Recarga Bidón 20 Litros%'
                   and m2 like '%Total pagado: $%' and m2 like '%¡Gracias por preferir Befine!' then 'OK' else 'FALLA ' || m2 end;
  res := res || chr(10) || 'T03 ejemplo del aviso de entrega:' || chr(10) || m2;
  raise exception 'PRUEBA EN SECO 10 (todo se deshace): %', res;
end $do$;
