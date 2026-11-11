-- Reversa de la migración 11 (registro del correo de confirmación)
-- Antes de revertir, volver a publicar mp-webhook SIN la llamada a enviar-correo y quitar enviar-correo.
drop index if exists public.idx_pedidos_sin_correo;
alter table public.pedidos
  drop column if exists correo_confirmacion_at,
  drop column if exists correo_confirmacion_id,
  drop column if exists correo_error;
