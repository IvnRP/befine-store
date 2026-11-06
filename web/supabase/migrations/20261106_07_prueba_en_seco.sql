-- PRUEBA EN SECO de la migración 07 (fotos de productos en Storage) — Befine Store
-- Requiere: 01 aplicada.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261106_07_fotos_productos.sql
-- y (2) este archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo
-- se deshace. Muestra T01..T05. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  u_cli uuid := gen_random_uuid();
  u_adm uuid := gen_random_uuid();
  n int; b record;
  res text := 'RESULTADOS';
begin
  select public, file_size_limit, allowed_mime_types into b from storage.buckets where id = 'productos';
  res := res || chr(10) || 'T01 bucket productos público, máx. 2 MB, solo imágenes: ' ||
         case when b.public and b.file_size_limit = 2097152 and 'image/webp' = any(b.allowed_mime_types)
                   and not ('application/pdf' = any(b.allowed_mime_types)) then 'OK' else 'FALLA' end;

  select count(*) into n from public.productos where imagen_url like '%-1000.webp';
  res := res || chr(10) || 'T02 productos con foto asignada (esperado 11): ' ||
         case when n = 11 then 'OK' else 'FALLA ' || n end;

  select count(*) into n from public.productos where activo and coalesce(imagen_url, '') = '';
  res := res || chr(10) || 'T03 ningún producto activo queda sin foto: ' ||
         case when n = 0 then 'OK' else 'FALLA sin foto=' || n end;

  insert into auth.users (id, email, raw_user_meta_data) values
    (u_cli, 'cli.fotos@correo.cl', '{"nombre":"Cliente Fotos"}'),
    (u_adm, 'adm.fotos@correo.cl', '{"nombre":"Admin Fotos"}');
  update public.perfiles set rol = 'admin' where id = u_adm;

  -- Un cliente no puede subir fotos
  perform set_config('request.jwt.claims', json_build_object('sub', u_cli, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    insert into storage.objects (bucket_id, name, owner) values ('productos', 'prueba-cliente.webp', u_cli);
    res := res || chr(10) || 'T04 un cliente no puede subir fotos: FALLA (se permitió)';
  exception when insufficient_privilege then
    res := res || chr(10) || 'T04 un cliente no puede subir fotos: OK';
  end;

  -- El administrador sí puede
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    insert into storage.objects (bucket_id, name, owner) values ('productos', 'prueba-admin.webp', u_adm);
    res := res || chr(10) || 'T05 el administrador puede subir fotos: OK';
  exception when others then
    res := res || chr(10) || 'T05 el administrador puede subir fotos: FALLA ' || sqlerrm;
  end;
  perform set_config('role', 'none', true);

  raise exception 'PRUEBA EN SECO 07 (todo se deshace): %', res;
end $do$;
