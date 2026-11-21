-- =====================================================================
-- Reversa de la migración 18 (Trae un amigo a prueba de abusos) — Befine Store
-- Vuelve a la regla de la migración 08: el premio de referido se da al PAGAR el primer pedido
-- del amigo y no se descuenta si se cancela. Publicar ANTES la versión del sitio con los
-- textos anteriores (terminos.html y cuenta.js) y Befine.legalVersion = "2026-11-17".
-- Los puntos ya entregados o descontados con la regla 18 quedan como están (movimientos_puntos).
-- =====================================================================
drop trigger if exists trg_club_referido_al_entregar on public.pedidos;
drop function if exists public.club_referido_al_entregar();

-- Funciones originales de la migración 08 (copia textual)
create or replace function public.club_al_pagar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ref public.referidos%rowtype; v_pts integer; v_tel text; v_mail text;
begin
  perform public._vencer_puntos(new.perfil_id);

  select * into v_ref from public.referidos where referido_id = new.perfil_id and premiado_at is null for update;
  if found then
    select pf.telefono, lower(u.email) into v_tel, v_mail
      from public.perfiles pf left join auth.users u on u.id = pf.id where pf.id = v_ref.referente_id;
    -- Evita invitarse a sí mismo con otra cuenta (mismo celular o correo que quien invitó)
    if (v_tel is null or new.contacto_telefono is distinct from v_tel)
       and (v_mail is null or lower(new.contacto_email) is distinct from v_mail) then
      v_pts := public._param_int('club_referido_puntos', 10);
      perform public._mover_puntos(v_ref.referente_id, 'ajuste', v_pts, 'Trae un amigo: tu invitado hizo su primera compra');
      perform public._mover_puntos(new.perfil_id,     'ajuste', v_pts, 'Trae un amigo: bienvenida al Club Befine');
    end if;
    update public.referidos set premiado_at = now() where referido_id = new.perfil_id;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_club_al_pagar on public.pedidos;
create trigger trg_club_al_pagar
  after update of estado on public.pedidos
  for each row when (new.estado = 'pagado' and old.estado = 'pendiente_pago')
  execute function public.club_al_pagar();

-- Pedido cancelado después de pagado: se descuentan los puntos que sumó (sin dejar saldo negativo)
create or replace function public.club_al_cancelar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pts integer; v_saldo integer;
begin
  select coalesce(sum(puntos), 0) into v_pts from public.movimientos_puntos
   where pedido_id = new.id and tipo in ('acumulacion', 'ajuste');
  if v_pts > 0 then
    select puntos_saldo into v_saldo from public.perfiles where id = new.perfil_id;
    perform public._mover_puntos(new.perfil_id, 'ajuste', -least(v_pts, greatest(coalesce(v_saldo, 0), 0)),
                                 'Pedido #' || new.numero || ' cancelado', new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_club_al_cancelar on public.pedidos;
create trigger trg_club_al_cancelar
  after update of estado on public.pedidos
  for each row when (new.estado = 'cancelado' and old.estado in ('pagado', 'en_preparacion', 'en_ruta', 'entregado'))
  execute function public.club_al_cancelar();

revoke execute on function public.club_al_pagar()    from public, anon, authenticated;
revoke execute on function public.club_al_cancelar() from public, anon, authenticated;

alter table public.referidos drop column if exists revertido_at, drop column if exists puntos_referente, drop column if exists pedido_id;
delete from public.parametros where clave = 'club_referido_tope_mes';
update public.parametros set valor = '2026-11-17' where clave = 'terminos_version';

do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261121000018'$q$;
  end if;
end;
$reg$;
