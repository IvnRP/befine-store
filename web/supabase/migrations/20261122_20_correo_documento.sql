-- =====================================================================
-- Migración 20: la boleta o factura le llega al cliente por correo al subirla
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  RF-08 (documentos tributarios) · RF-09 (correos). Decisión del dueño 22-nov-2026: al subir
--            el PDF en el panel, el cliente lo recibe adjunto en su correo (con o sin cuenta).
-- Requiere:  01 a 19 aplicadas.
-- Reversa:   20261122_20_correo_documento_reversa.sql
-- Prueba:    20261122_20_prueba_en_seco.sql (20 + prueba; T01..T08)
--
-- Qué hace:
--   1. documentos_tributarios: registro del envío por correo (cuándo, a quién, id en Resend, error).
--      La Edge Function enviar-correo (tipo "documento") "reserva" el envío marcando correo_enviado_at
--      con un UPDATE condicional (dos clics seguidos no envían dos correos) y, si Resend falla, lo
--      libera y guarda el motivo en correo_error para reintentar desde el panel.
--   2. Si se reemplaza el documento por OTRO (cambia el tipo o el folio), el envío se reinicia para que
--      el cliente reciba el documento correcto; el envío anterior queda en raw_response->'correo_anterior'.
--      Si solo se vuelve a subir el mismo folio, no se reenvía.
-- =====================================================================

-- 1. Registro del envío por correo
alter table public.documentos_tributarios
  add column if not exists correo_enviado_at timestamptz,
  add column if not exists correo_destino    text,
  add column if not exists correo_id         text,
  add column if not exists correo_error      text;

do $chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'dte_correo_error_largo') then
    alter table public.documentos_tributarios
      add constraint dte_correo_error_largo check (correo_error is null or length(correo_error) <= 300);
  end if;
end;
$chk$;

comment on column public.documentos_tributarios.correo_enviado_at is
  'Cuándo se envió el documento (PDF adjunto) al correo del cliente (migración 20). Null = no enviado.';
comment on column public.documentos_tributarios.correo_destino is 'Correo al que se envió el documento.';
comment on column public.documentos_tributarios.correo_id      is 'Id del correo en Resend.';
comment on column public.documentos_tributarios.correo_error   is 'Motivo del último envío fallido (para reintentar).';

-- 2. Reemplazo por otro documento → se reinicia el envío (y se guarda el anterior)
create or replace function public.dte_reiniciar_correo()
returns trigger language plpgsql set search_path = public as $$
begin
  if (new.tipo is distinct from old.tipo or new.folio is distinct from old.folio) then
    if old.correo_enviado_at is not null then
      new.raw_response := coalesce(new.raw_response, '{}'::jsonb) || jsonb_build_object('correo_anterior',
        jsonb_build_object('tipo', old.tipo, 'folio', old.folio, 'enviado_at', old.correo_enviado_at,
                           'destino', old.correo_destino, 'id', old.correo_id));
    end if;
    new.correo_enviado_at := null;
    new.correo_destino    := null;
    new.correo_id         := null;
    new.correo_error      := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dte_reiniciar_correo on public.documentos_tributarios;
create trigger trg_dte_reiniciar_correo
  before update of tipo, folio on public.documentos_tributarios
  for each row execute function public.dte_reiniciar_correo();

revoke execute on function public.dte_reiniciar_correo() from public, anon, authenticated;

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261122000020', '20_correo_documento') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
