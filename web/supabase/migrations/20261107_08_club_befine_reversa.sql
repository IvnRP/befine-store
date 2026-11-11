-- =====================================================================
-- Reversa de la migración 08 (Club Befine)
-- Pasos (en este orden):
--   1. Ejecutar de nuevo la sección 2 de 20261020_04_cupones_reglas.sql (_evaluar_cupon de la 04)
--      y la sección 3 de 20261106_06_aceptacion_terminos.sql (crear_pedido de la 06), con sus permisos.
--   2. Ejecutar este archivo.
-- Ojo: borra los códigos de invitación, las invitaciones y los cupones de premios sin usar.
-- Los movimientos de puntos y los saldos se conservan (historial). No devuelve LEGACY2000 ni
-- el precio anterior de la recarga con envase de otra marca (eran decisiones del dueño).
-- =====================================================================
drop trigger if exists trg_club_al_pagar    on public.pedidos;
drop trigger if exists trg_club_al_cancelar on public.pedidos;
drop function if exists public.club_al_pagar();
drop function if exists public.club_al_cancelar();
drop function if exists public.club_estado();
drop function if exists public.canjear_recompensa(text);
drop function if exists public.registrar_referido(text);
drop function if exists public.vencer_puntos_inactivos();
drop function if exists public._vencer_puntos(uuid);
drop function if exists public._mover_puntos(uuid, public.tipo_mov_puntos, integer, text, uuid, uuid);
drop function if exists public._es_invitado(uuid);
drop function if exists public._param_int(text, integer);
drop table if exists public.referidos;
drop table if exists public.codigos_referido;

delete from public.cupones c where c.recompensa_id is not null and c.usos_actuales = 0;
update public.cupones set recompensa_id = null where recompensa_id is not null;
alter table public.cupones drop column if exists recompensa_id, drop column if exists descuento_maximo;
delete from public.recompensas where codigo in ('menor', 'medio', 'mayor')
   and not exists (select 1 from public.movimientos_puntos m where m.recompensa_id = recompensas.id);
alter table public.recompensas drop column if exists codigo, drop column if exists compra_minima,
  drop column if exists cupon_tope, drop column if exists solo_recargas, drop column if exists orden;
alter table public.variantes_producto drop column if exists suma_puntos;
alter table public.pedidos drop column if exists es_canje;
delete from public.parametros where clave in ('club_bono_min_recargas', 'club_bono_puntos', 'club_referido_puntos',
                                              'club_vencimiento_meses', 'club_cupon_dias');
delete from supabase_migrations.schema_migrations where version = '20261107000008';
