-- PRUEBA EN SECO de la migración 20 (la boleta o factura llega por correo) — Befine Store
-- Requiere: 01 a 19 aplicadas.
-- Uso: pegar en UNA misma consulta del SQL Editor (1) 20261122_20_correo_documento.sql y (2) este
-- archivo, sin begin/commit. Termina SIEMPRE con un error intencional: todo se deshace (no se envía
-- ningún correo ni se sube ningún PDF real; los "envíos" se simulan como lo hace la Edge Function).
-- Muestra T01..T08. Busca la palabra FALLA: no debería aparecer.

do $do$
declare
  adm uuid := gen_random_uuid();   -- dueño (admin)
  cli uuid := gen_random_uuid();   -- cliente con boleta
  vb uuid; j jsonb; r jsonb; pb uuid; pp uuid; tb int; n int; msg text; t0 timestamptz;
  dir jsonb := '{"calle":"Los Tailandeses","numero":"1156","comuna":"Quilicura"}';
  res text := 'RESULTADOS';
begin
  select id into vb from public.variantes_producto where sku = 'BEF-REC-20-BEFINE';
  insert into auth.users (id, email, raw_user_meta_data, is_anonymous) values
    (adm, 'admin20@correo.cl', '{"nombre":"Admin"}', false), (cli, 'cli20@correo.cl', '{"nombre":"Cli"}', false);
  update public.perfiles set rol = 'admin' where id = adm;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 4)), dir,
         '{"nombre":"Cli","telefono":"9 2001 2001","email":"cli20@correo.cl","acepta_terminos":true}');
  pb := (j->>'id')::uuid; tb := (j->>'total')::int;
  j := public.crear_pedido(jsonb_build_array(jsonb_build_object('variante_id', vb, 'cantidad', 1)), dir,
         '{"nombre":"Cli","telefono":"9 2001 2001","email":"cli20@correo.cl","acepta_terminos":true}');
  pp := (j->>'id')::uuid;                                         -- queda sin pagar (sin documento)
  perform set_config('role', 'none', true); perform set_config('request.jwt.claims', '{}', true);
  perform public.confirmar_pago(pb, 'PRUEBA-20-B', tb);
  insert into storage.objects (bucket_id, name) values
    ('documentos', pb::text || '/boleta-20001.pdf'), ('documentos', pb::text || '/boleta-20002.pdf');

  res := res || chr(10) || 'T01 columnas del envío y reinicio automático creados: ' ||
    case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'documentos_tributarios'
               and column_name in ('correo_enviado_at', 'correo_destino', 'correo_id', 'correo_error')) = 4
          and exists (select 1 from pg_trigger where tgname = 'trg_dte_reiniciar_correo')
         then 'OK' else 'FALLA' end;

  -- El admin sube la boleta
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  r := public.registrar_documento(pb, 'boleta', 20001);
  res := res || chr(10) || 'T02 boleta recién subida queda pendiente de envío: ' ||
    case when (r->>'ok')::boolean and (select correo_enviado_at is null from public.documentos_tributarios where pedido_id = pb)
         then 'OK' else 'FALLA ' || r::text end;

  -- T03: la reserva del envío (UPDATE condicional de la Edge Function, con la clave de servicio) solo resulta una vez
  perform set_config('role', 'none', true);
  update public.documentos_tributarios set correo_enviado_at = now(), correo_error = null
   where pedido_id = pb and estado = 'emitido' and archivo is not null and correo_enviado_at is null;
  get diagnostics n = row_count; msg := case when n = 1 then 'primera OK' else 'FALLA primera' end;
  update public.documentos_tributarios set correo_enviado_at = now(), correo_error = null
   where pedido_id = pb and estado = 'emitido' and archivo is not null and correo_enviado_at is null;
  get diagnostics n = row_count; msg := msg || case when n = 0 then ', segunda no envía OK' else ', FALLA segunda' end;
  update public.documentos_tributarios set correo_destino = 'cli20@correo.cl', correo_id = 're_prueba_1' where pedido_id = pb;
  select correo_enviado_at into t0 from public.documentos_tributarios where pedido_id = pb;
  res := res || chr(10) || 'T03 dos clics seguidos envían un solo correo: ' || msg;

  -- T04: volver a subir el MISMO folio (PDF corregido) no reenvía
  perform set_config('role', 'authenticated', true);
  r := public.registrar_documento(pb, 'boleta', 20001);
  res := res || chr(10) || 'T04 subir de nuevo el mismo folio no reenvía el correo: ' ||
    case when (r->>'ok')::boolean and (select correo_enviado_at = t0 and correo_id = 're_prueba_1'
                                          from public.documentos_tributarios where pedido_id = pb)
         then 'OK' else 'FALLA ' || r::text end;

  -- T05: reemplazar por OTRO folio reinicia el envío y guarda el anterior
  r := public.registrar_documento(pb, 'boleta', 20002);
  res := res || chr(10) || 'T05 reemplazar por otro folio deja el correo pendiente y audita el envío anterior: ' ||
    case when (r->>'ok')::boolean and exists (select 1 from public.documentos_tributarios where pedido_id = pb
              and correo_enviado_at is null and correo_id is null and correo_destino is null
              and raw_response->'correo_anterior'->>'folio' = '20001'
              and raw_response->'correo_anterior'->>'destino' = 'cli20@correo.cl'
              and raw_response->'anterior'->>'folio' = '20001')
         then 'OK' else 'FALLA ' || r::text end;

  -- T06: el cliente no puede marcar su documento como enviado
  perform set_config('request.jwt.claims', json_build_object('sub', cli, 'role', 'authenticated')::text, true);
  begin
    update public.documentos_tributarios set correo_enviado_at = now() where pedido_id = pb;
    get diagnostics n = row_count; msg := case when n = 0 then 'OK' else 'FALLA (pudo)' end;
  exception when others then msg := 'OK';
  end;
  perform set_config('role', 'none', true); perform set_config('request.jwt.claims', '{}', true);
  if (select correo_enviado_at is not null from public.documentos_tributarios where pedido_id = pb) then msg := 'FALLA (cambió)'; end if;
  res := res || chr(10) || 'T06 un cliente no puede marcar su boleta como enviada: ' || msg;

  -- T07: el motivo de error tiene largo acotado
  begin
    update public.documentos_tributarios set correo_error = repeat('x', 301) where pedido_id = pb; msg := 'FALLA (aceptó)';
  exception when check_violation then msg := 'OK';
  end;
  res := res || chr(10) || 'T07 el motivo de un envío fallido no supera 300 caracteres: ' || msg;

  -- T08: un pedido sin pagar (sin documento) no tiene nada que enviar
  update public.documentos_tributarios set correo_enviado_at = now()
   where pedido_id = pp and estado = 'emitido' and archivo is not null and correo_enviado_at is null;
  get diagnostics n = row_count;
  res := res || chr(10) || 'T08 un pedido sin documento no envía correo: ' || case when n = 0 then 'OK' else 'FALLA' end;

  raise exception 'PRUEBA EN SECO 20 (todo se deshace): %', res;
end $do$;
