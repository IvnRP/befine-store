-- REVERSA de la migración 20 (correo con la boleta o factura) — Befine Store
-- Quita el reinicio automático y las columnas del envío. Los documentos y sus PDF se conservan;
-- se pierde solo el registro de a quién y cuándo se envió cada correo.
drop trigger if exists trg_dte_reiniciar_correo on public.documentos_tributarios;
drop function if exists public.dte_reiniciar_correo();
alter table public.documentos_tributarios
  drop constraint if exists dte_correo_error_largo,
  drop column if exists correo_error,
  drop column if exists correo_id,
  drop column if exists correo_destino,
  drop column if exists correo_enviado_at;

do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261122000020'$q$;
  end if;
exception when others then
  raise notice 'No se pudo actualizar schema_migrations: %', sqlerrm;
end;
$reg$;
