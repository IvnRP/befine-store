-- =====================================================================
-- Migración 19: boletas y facturas en la tienda (opción A, emisión en Haulmer)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  RF-08 (documentos tributarios) · HU-18 (Mis pedidos). Decisión del dueño 22-nov-2026:
--            los documentos se siguen emitiendo en Haulmer (Espacio), y la tienda guarda el PDF y el
--            folio de cada pedido para que el cliente lo descargue. Deja lista la tabla para una
--            futura emisión automática propia (opción B), que solo cambiaría QUIÉN la completa.
-- Requiere:  01 a 18 aplicadas.
-- Reversa:   20261122_19_documentos_tributarios_reversa.sql
-- Prueba:    20261122_19_prueba_en_seco.sql (19 + prueba; T01..T12)
--
-- Qué hace:
--   1. Bucket PRIVADO "documentos" (solo PDF, máx. 3 MB). Ruta: <pedido_id>/<boleta|factura>-<folio>.pdf
--      Sube/cambia/borra: solo quien tiene documentos.gestionar. Lee: ese permiso o el dueño del
--      pedido (el cliente descarga con un enlace temporal; nadie más puede ver su boleta).
--   2. documentos_tributarios: columnas archivo (ruta en el bucket) y registrado_por; un solo
--      documento emitido por pedido.
--   3. registrar_documento(pedido, tipo, folio): valida permiso, que el pedido esté pagado, que el
--      tipo sea el que pidió el cliente, que el folio no esté usado en otro pedido y que el PDF ya
--      esté subido; calcula neto e IVA como Haulmer (neto = total / 1,19 redondeado). Si el pedido ya
--      tenía documento, lo reemplaza y guarda el anterior en raw_response (auditoría).
-- =====================================================================

-- 1. Bucket privado para los PDF
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 3145728, array['application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists documentos_subir     on storage.objects;
drop policy if exists documentos_modificar on storage.objects;
drop policy if exists documentos_borrar    on storage.objects;
drop policy if exists documentos_ver       on storage.objects;

create policy documentos_subir on storage.objects
  for insert to authenticated
  with check (bucket_id = 'documentos' and public.tiene_permiso('documentos.gestionar'));

create policy documentos_modificar on storage.objects
  for update to authenticated
  using      (bucket_id = 'documentos' and public.tiene_permiso('documentos.gestionar'))
  with check (bucket_id = 'documentos' and public.tiene_permiso('documentos.gestionar'));

create policy documentos_borrar on storage.objects
  for delete to authenticated
  using (bucket_id = 'documentos' and public.tiene_permiso('documentos.gestionar'));

create policy documentos_ver on storage.objects
  for select to authenticated
  using (bucket_id = 'documentos' and (
           public.tiene_permiso('documentos.gestionar')
           or exists (select 1 from public.pedidos p
                       where p.id::text = (storage.foldername(name))[1] and p.perfil_id = auth.uid())));

-- 2. Columnas y un solo documento emitido por pedido
alter table public.documentos_tributarios
  add column if not exists archivo        text,
  add column if not exists registrado_por uuid references public.perfiles(id) on delete set null;
comment on column public.documentos_tributarios.archivo is
  'PDF en el bucket privado "documentos": <pedido_id>/<boleta|factura>-<folio>.pdf (migración 19).';
create unique index if not exists dte_un_emitido_por_pedido
  on public.documentos_tributarios (pedido_id) where estado = 'emitido';

-- 3. Registrar el documento emitido en Haulmer
create or replace function public.registrar_documento(p_pedido uuid, p_tipo public.tipo_dte, p_folio bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p public.pedidos%rowtype; v_prev public.documentos_tributarios%rowtype;
  v_otro bigint; v_archivo text; v_neto integer; v_iva integer; v_id uuid;
begin
  if not public.tiene_permiso('documentos.gestionar') then
    raise exception 'No tienes permiso para registrar boletas o facturas.' using errcode = '42501';
  end if;
  select * into v_p from public.pedidos where id = p_pedido for update;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'pedido_no_existe', 'mensaje', 'No encontramos el pedido.');
  end if;
  if v_p.estado not in ('pagado', 'en_preparacion', 'en_ruta', 'entregado') then
    return jsonb_build_object('ok', false, 'motivo', 'pedido_no_pagado', 'mensaje', 'Solo se registran documentos de pedidos pagados.');
  end if;
  if coalesce(v_p.total, 0) <= 0 then
    return jsonb_build_object('ok', false, 'motivo', 'pedido_sin_monto', 'mensaje', 'El pedido no tiene monto (canje de $0).');
  end if;
  if p_tipo is distinct from v_p.tipo_documento then
    return jsonb_build_object('ok', false, 'motivo', 'tipo_distinto',
      'mensaje', 'El cliente pidió ' || v_p.tipo_documento::text || ', no ' || coalesce(p_tipo::text, '—') || '.');
  end if;
  if p_folio is null or p_folio <= 0 then
    return jsonb_build_object('ok', false, 'motivo', 'folio_invalido', 'mensaje', 'El folio debe ser un número mayor que 0.');
  end if;
  select p.numero into v_otro from public.documentos_tributarios d join public.pedidos p on p.id = d.pedido_id
   where d.tipo = p_tipo and d.folio = p_folio and d.pedido_id <> p_pedido limit 1;
  if v_otro is not null then
    return jsonb_build_object('ok', false, 'motivo', 'folio_repetido',
      'mensaje', 'Ese folio ya está registrado en el pedido #' || v_otro || '.');
  end if;
  v_archivo := p_pedido::text || '/' || p_tipo::text || '-' || p_folio || '.pdf';
  if not exists (select 1 from storage.objects where bucket_id = 'documentos' and name = v_archivo) then
    return jsonb_build_object('ok', false, 'motivo', 'archivo_no_encontrado', 'mensaje', 'Primero sube el PDF del documento.');
  end if;

  v_neto := round(v_p.total / 1.19);           -- igual que Haulmer: $10.000 → neto $8.403 + IVA $1.597
  v_iva  := v_p.total - v_neto;

  select * into v_prev from public.documentos_tributarios where pedido_id = p_pedido and estado = 'emitido' for update;
  if found then
    update public.documentos_tributarios
       set tipo = p_tipo, folio = p_folio, archivo = v_archivo,
           rut_receptor = v_p.doc_rut, razon_social = v_p.doc_razon_social,
           monto_neto = v_neto, iva = v_iva, monto_total = v_p.total,
           fecha_emision = now(), registrado_por = auth.uid(),
           raw_response = coalesce(raw_response, '{}'::jsonb) || jsonb_build_object('anterior',
             jsonb_build_object('tipo', v_prev.tipo, 'folio', v_prev.folio, 'archivo', v_prev.archivo,
                                'registrado_por', v_prev.registrado_por, 'reemplazado_at', now()))
     where id = v_prev.id
     returning id into v_id;
  else
    insert into public.documentos_tributarios
      (pedido_id, tipo, estado, folio, rut_receptor, razon_social, monto_neto, iva, monto_total,
       archivo, fecha_emision, registrado_por, raw_response)
    values (p_pedido, p_tipo, 'emitido', p_folio, v_p.doc_rut, v_p.doc_razon_social, v_neto, v_iva, v_p.total,
            v_archivo, now(), auth.uid(), jsonb_build_object('origen', 'haulmer_manual'))
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'tipo', p_tipo, 'folio', p_folio, 'archivo', v_archivo,
                            'neto', v_neto, 'iva', v_iva, 'total', v_p.total,
                            'reemplazo', v_prev.id is not null,
                            'archivo_anterior', case when v_prev.archivo is distinct from v_archivo then v_prev.archivo end);
end;
$$;

revoke execute on function public.registrar_documento(uuid, public.tipo_dte, bigint) from public, anon;
grant  execute on function public.registrar_documento(uuid, public.tipo_dte, bigint) to authenticated;
comment on function public.registrar_documento(uuid, public.tipo_dte, bigint) is
  'Registra la boleta o factura (emitida en Haulmer) de un pedido pagado, con su PDF ya subido (migración 19).';

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261122000019', '19_documentos_tributarios') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
