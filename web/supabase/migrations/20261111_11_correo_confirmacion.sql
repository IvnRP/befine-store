-- =====================================================================
-- Migración 11: registro del correo de confirmación de compra (aplicada el 11-nov-2026; prueba en seco T01..T03 OK)
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-10 / RF-09 · Ley 19.496 art. 12 A (confirmación escrita de la compra)
-- Requiere:  08 aplicada (pedidos.es_canje).
-- Aplicar:   ANTES de publicar las funciones enviar-correo y mp-webhook nuevas.
-- Reversa:   20261111_11_correo_confirmacion_reversa.sql
-- Prueba:    20261111_11_prueba_en_seco.sql (11 + prueba; T01..T03)
--
-- La Edge Function enviar-correo "reserva" el envío marcando correo_confirmacion_at con un
-- UPDATE condicional (solo si está vacío y el pedido está pagado): así un pedido recibe UNA sola
-- confirmación aunque el webhook y la tienda la pidan a la vez. Es además la prueba de que se
-- envió (fecha, id del correo en Resend) o del motivo si falló (correo_error, para reintentar).
-- Los clientes no pueden escribir estas columnas: solo el servidor (RLS de pedidos, migración 01).
-- =====================================================================
alter table public.pedidos
  add column if not exists correo_confirmacion_at timestamptz,
  add column if not exists correo_confirmacion_id text,
  add column if not exists correo_error           text check (correo_error is null or length(correo_error) <= 300);

comment on column public.pedidos.correo_confirmacion_at is 'Cuándo se envió el correo de confirmación de compra (HU-10). Null = no enviado.';
comment on column public.pedidos.correo_confirmacion_id is 'Id del correo en Resend (trazabilidad del envío).';
comment on column public.pedidos.correo_error           is 'Último error al enviar la confirmación (se reintenta).';

create index if not exists idx_pedidos_sin_correo on public.pedidos(created_at)
  where correo_confirmacion_at is null and estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado');
