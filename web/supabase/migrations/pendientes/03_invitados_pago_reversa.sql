-- REVERSA de la migración 03 (invitados + confirmación de pago)
-- No borra pagos, puntos ni pedidos ya registrados; solo quita trigger y funciones.
drop trigger  if exists on_auth_user_upgraded on auth.users;
drop function if exists public.handle_user_upgrade();
drop function if exists public.confirmar_pago(uuid, text, integer, jsonb, text);
