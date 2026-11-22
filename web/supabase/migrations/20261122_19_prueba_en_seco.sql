-- PRUEBA EN SECO de la migración 19 (boletas y facturas en la tienda) — Befine Store
-- Requiere: 01 a 18 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261122_19_documentos_tributarios.sql y (2) este
-- archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace (también los
-- archivos de prueba que se registran en storage.objects; no se sube ningún PDF real).
-- Muestra T01..T12. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  adm uuid := gen_random_uuid();   -- dueño (admin)
  cli uuid := gen_random_uuid();   -- cliente con boleta
  emp uuid := gen_random_uuid();   -- empresa con factura
  otr uuid := gen_random_uuid();   -- otro cliente (no debe ver nada ajeno)
  vb uuid; j jsonb; r jsonb; pb uuid; pf uuid; pp uuid; tb int; n int; msg text;
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (adm, 'admin19@correo.cl', '{"nombre":"Admin"}', false), (cli, 'cli19@correo.cl', '{"nombre":"Cli"}', false),
    (emp, 'emp19@correo.cl', '{"nombre":"Emp"}', false), (otr, 'otr19@correo.cl', '{"nombre":"Otro"}', false);
  update public.perfiles set rol = 'admin' where id = adm;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 4)), dir,
         '{"nombre":"Cli","telefono":"9 1901 1901","email":"cli19@correo.cl","acepta_terminos":true}');
  pb := (j->>'id')::uuid; tb := (j->>'total')::int;
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir,
         '{"nombre":"Cli","telefono":"9 1901 1901","email":"cli19@correo.cl","acepta_terminos":true}');
  pp := (j->>'id')::uuid;                                         -- queda sin pagar
  perform set_config('request.jwt.claims', json_build_object('sub', emp, 'role', 'authenticated')::text, true);
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 10)), dir,
         '{"nombre":"Emp","telefono":"9 1902 1902","email":"emp19@correo.cl","acepta_terminos":true}', null,
         '{"tipo":"factura","rut":"76.086.428-5","razon_social":"Empresa Prueba SpA","giro":"Servicios"}');
  pf := (j->>'id')::uuid;
  perform set_config('role', 'none', true); perform set_config('request.jwt.claims', '{}', true);
  perform public.confirmar_pago(pb, 'PRUEBA-19-B', tb);
  perform public.confirmar_pago(pf, 'PRUEBA-19-F', (select total from public.pedidos where id = pf));

  res := res || chr(10) || 'T01 el bucket "documentos" es privado y solo acepta PDF: ' ||
    case when exists (select 1 from storage.buckets where id = 'documentos' and not public and allowed_mime_types = array['application/pdf'])
         then 'OK' else 'FALLA' end;

  -- T02: un cliente no puede registrar documentos
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin perform public.registrar_documento(pb, 'boleta', 11298); msg := 'FALLA (pudo)';
  exception when others then msg := case when sqlstate = '42501' then 'OK' else 'FALLA ' || sqlerrm end; end;
  res := res || chr(10) || 'T02 un cliente no puede registrar boletas: ' || msg;

  -- Como admin
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  r := public.registrar_documento(pp, 'boleta', 900);
  res := res || chr(10) || 'T03 un pedido sin pagar no recibe documento: ' || case when r->>'motivo' = 'pedido_no_pagado' then 'OK' else 'FALLA ' || r::text end;
  r := public.registrar_documento(pf, 'boleta', 901);
  res := res || chr(10) || 'T04 si el cliente pidió factura, no se le registra boleta: ' || case when r->>'motivo' = 'tipo_distinto' then 'OK' else 'FALLA ' || r::text end;
  r := public.registrar_documento(pb, 'boleta', 11298);
  res := res || chr(10) || 'T05 sin el PDF subido no se registra: ' || case when r->>'motivo' = 'archivo_no_encontrado' then 'OK' else 'FALLA ' || r::text end;

  -- El PDF "subido" (solo el registro en storage.objects; se deshace al final)
  perform set_config('role', 'none', true);
  insert into storage.objects (bucket_id, name) values
    ('documentos', pb::text || '/boleta-11298.pdf'), ('documentos', pb::text || '/boleta-11299.pdf'),
    ('documentos', pf::text || '/factura-496.pdf'), ('documentos', pf::text || '/factura-11298.pdf');
  perform set_config('role', 'authenticated', true);

  r := public.registrar_documento(pb, 'boleta', 11298);
  res := res || chr(10) || 'T06 boleta registrada con neto e IVA como Haulmer (total/1,19): ' ||
    case when (r->>'ok')::boolean and (r->>'neto')::int = round(tb / 1.19) and (r->>'neto')::int + (r->>'iva')::int = tb
              and (select archivo from public.documentos_tributarios where pedido_id = pb and estado = 'emitido') = pb::text || '/boleta-11298.pdf'
         then 'OK' else 'FALLA ' || r::text end;

  r := public.registrar_documento(pf, 'factura', 496);
  res := res || chr(10) || 'T07 factura registrada con RUT y razón social del pedido: ' ||
    case when (r->>'ok')::boolean and exists (select 1 from public.documentos_tributarios where pedido_id = pf and folio = 496
              and razon_social = 'Empresa Prueba SpA' and rut_receptor is not null) then 'OK' else 'FALLA ' || r::text end;

  -- T08: el mismo folio en otro pedido se rechaza (folios por tipo: boleta 11298 ≠ factura 11298)
  r := public.registrar_documento(pf, 'factura', 11298);
  res := res || chr(10) || 'T08 folios por tipo (factura 11298 sí; boleta 11298 en otro pedido no): ' ||
    case when (r->>'ok')::boolean then 'OK' else 'FALLA ' || r::text end;
  perform set_config('role', 'none', true);
  insert into storage.objects (bucket_id, name) values ('documentos', pf::text || '/boleta-11298.pdf');
  update public.pedidos set tipo_documento = 'boleta' where id = pf;
  perform set_config('role', 'authenticated', true);
  r := public.registrar_documento(pf, 'boleta', 11298);
  res := res || chr(10) || 'T09 un folio ya usado en otro pedido se rechaza: ' ||
    case when r->>'motivo' = 'folio_repetido' then 'OK' else 'FALLA ' || r::text end;

  -- T10: reemplazar el documento de un pedido (se corrigió el folio) deja uno solo y guarda el anterior
  r := public.registrar_documento(pb, 'boleta', 11299);
  select count(*) into n from public.documentos_tributarios where pedido_id = pb;
  res := res || chr(10) || 'T10 reemplazar deja un solo documento y audita el anterior: ' ||
    case when (r->>'reemplazo')::boolean and n = 1 and r->>'archivo_anterior' = pb::text || '/boleta-11298.pdf'
              and (select raw_response->'anterior'->>'folio' from public.documentos_tributarios where pedido_id = pb) = '11298'
         then 'OK' else 'FALLA ' || r::text || ' n=' || n end;

  -- T11: el cliente ve su boleta (tabla y PDF) y otro cliente no
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  select count(*) into n from public.documentos_tributarios where pedido_id = pb;
  msg := case when n = 1 then 'tabla OK' else 'FALLA tabla' end;
  select count(*) into n from storage.objects where bucket_id = 'documentos' and name = pb::text || '/boleta-11299.pdf';
  msg := msg || case when n = 1 then ', pdf OK' else ', FALLA pdf' end;
  perform set_config('request.jwt.claims', json_build_object('sub', otr, 'role', 'authenticated')::text, true);
  select count(*) into n from public.documentos_tributarios where pedido_id = pb;
  msg := msg || case when n = 0 then ', ajeno OK' else ', FALLA ajeno' end;
  select count(*) into n from storage.objects where bucket_id = 'documentos';
  msg := msg || case when n = 0 then ', pdf ajeno OK' else ', FALLA pdf ajeno' end;
  res := res || chr(10) || 'T11 el cliente ve su boleta y su PDF; otro cliente no ve nada: ' || msg;
  -- T12: un cliente no puede subir PDFs al bucket
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin insert into storage.objects (bucket_id, name) values ('documentos', pb::text || '/boleta-1.pdf'); msg := 'FALLA (pudo subir)';
  exception when others then msg := 'OK'; end;
  perform set_config('role', 'none', true);
  res := res || chr(10) || 'T12 un cliente no puede subir archivos al bucket de documentos: ' || msg;

  raise exception 'PRUEBA EN SECO 19 (todo se deshace): %', res;
end $do$;
