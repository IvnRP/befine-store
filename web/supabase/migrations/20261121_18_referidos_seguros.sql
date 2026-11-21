-- =====================================================================
-- Migración 18: "Trae un amigo" a prueba de abusos
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  HU-19 (Club Befine). Decisión del dueño 21-nov-2026: que invitar a muchas personas
--            siga siendo rentable y que no se puedan sacar puntos gratis con pedidos que se
--            pagan y después se cancelan o devuelven.
-- Requiere:  01 a 17 aplicadas (08 crea el Club Befine).
-- Reversa:   20261121_18_referidos_seguros_reversa.sql
-- Prueba:    20261121_18_prueba_en_seco.sql (18 + prueba; T01..T09)
--
-- Qué cambia:
--   1. Los 10 puntos de "Trae un amigo" (para quien invita y para el amigo) se dan cuando el
--      primer pedido del amigo se marca ENTREGADO, ya no cuando se paga.
--   2. Si ese pedido se cancela después, se descuentan esos puntos a los dos (sin dejar saldos
--      negativos) y la invitación vuelve a quedar pendiente para un próximo pedido real.
--   3. Tope mensual: quien invita recibe puntos por hasta club_referido_tope_mes amigos al mes
--      (10). El amigo igual recibe su bienvenida.
--   4. Nueva versión de los Términos (sección 12 explica la regla): 2026-11-21.
-- Los premios ya entregados con la regla anterior no se tocan.
-- =====================================================================

-- 1. Seguimiento de cada premio de referido
alter table public.referidos
  add column if not exists pedido_id        uuid references public.pedidos(id) on delete set null,
  add column if not exists puntos_referente integer,
  add column if not exists revertido_at     timestamptz;
comment on column public.referidos.pedido_id is 'Pedido (entregado) del amigo que dio el premio de Trae un amigo (migración 18).';
comment on column public.referidos.puntos_referente is 'Puntos que recibió quien invitó por este amigo (0 si superó el tope del mes o era la misma persona).';
comment on column public.referidos.revertido_at is 'Cuándo se quitó el premio porque el pedido del amigo se canceló.';

-- 2. Tope mensual de amigos premiados para quien invita
insert into public.parametros (clave, valor, descripcion) values
  ('club_referido_tope_mes', '10', 'Club Befine: máximo de amigos al mes por los que quien invita recibe puntos')
on conflict (clave) do nothing;

-- 3. Al pagarse un pedido: solo vence lo antiguo (el premio de referido pasa a la entrega)
create or replace function public.club_al_pagar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._vencer_puntos(new.perfil_id);
  return new;
end;
$$;

-- 4. Al entregarse el pedido: premio de Trae un amigo (una sola vez por amigo)
create or replace function public.club_referido_al_entregar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_ref public.referidos%rowtype; v_pts integer; v_tope integer; v_mes integer; v_dado integer := 0;
  v_tel text; v_mail text;
begin
  select * into v_ref from public.referidos where referido_id = new.perfil_id and premiado_at is null for update;
  if not found then return new; end if;

  -- Evita invitarse a sí mismo con otra cuenta (mismo celular o correo que quien invitó)
  select pf.telefono, lower(u.email) into v_tel, v_mail
    from public.perfiles pf left join auth.users u on u.id = pf.id where pf.id = v_ref.referente_id;
  if (v_tel is not null and new.contacto_telefono = v_tel)
     or (v_mail is not null and lower(new.contacto_email) = v_mail) then
    update public.referidos set premiado_at = now(), pedido_id = new.id, puntos_referente = 0, revertido_at = null
     where referido_id = v_ref.referido_id;
    return new;
  end if;

  v_pts  := public._param_int('club_referido_puntos', 10);
  v_tope := public._param_int('club_referido_tope_mes', 10);
  select count(*) into v_mes from public.referidos
   where referente_id = v_ref.referente_id and coalesce(puntos_referente, 0) > 0
     and premiado_at >= (date_trunc('month', now() at time zone 'America/Santiago') at time zone 'America/Santiago');
  if v_mes < v_tope then
    perform public._mover_puntos(v_ref.referente_id, 'ajuste', v_pts, 'Trae un amigo: tu invitado recibió su primer pedido');
    v_dado := v_pts;
  end if;
  -- Bienvenida del amigo, ligada a SU pedido: si el pedido se cancela, club_al_cancelar la descuenta
  perform public._mover_puntos(new.perfil_id, 'ajuste', v_pts, 'Trae un amigo: bienvenida al Club Befine', new.id);
  update public.referidos set premiado_at = now(), pedido_id = new.id, puntos_referente = v_dado, revertido_at = null
   where referido_id = v_ref.referido_id;
  return new;
end;
$$;
drop trigger if exists trg_club_referido_al_entregar on public.pedidos;
create trigger trg_club_referido_al_entregar
  after update of estado on public.pedidos
  for each row when (new.estado = 'entregado' and old.estado is distinct from 'entregado')
  execute function public.club_referido_al_entregar();

-- 5. Pedido cancelado después de pagado: se descuentan SUS puntos y, si dio el premio de
--    referido, también los de quien invitó (nunca deja saldo negativo)
create or replace function public.club_al_cancelar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pts integer; v_saldo integer; v_ref public.referidos%rowtype;
begin
  select coalesce(sum(puntos), 0) into v_pts from public.movimientos_puntos
   where pedido_id = new.id and perfil_id = new.perfil_id and tipo in ('acumulacion', 'ajuste');
  if v_pts > 0 then
    select puntos_saldo into v_saldo from public.perfiles where id = new.perfil_id;
    perform public._mover_puntos(new.perfil_id, 'ajuste', -least(v_pts, greatest(coalesce(v_saldo, 0), 0)),
                                 'Pedido #' || new.numero || ' cancelado', new.id);
  end if;

  select * into v_ref from public.referidos where pedido_id = new.id and premiado_at is not null for update;
  if found then
    if coalesce(v_ref.puntos_referente, 0) > 0 then
      select puntos_saldo into v_saldo from public.perfiles where id = v_ref.referente_id;
      perform public._mover_puntos(v_ref.referente_id, 'ajuste',
                                   -least(v_ref.puntos_referente, greatest(coalesce(v_saldo, 0), 0)),
                                   'Trae un amigo: el pedido de tu invitado se canceló');
    end if;
    update public.referidos set premiado_at = null, pedido_id = null, puntos_referente = null, revertido_at = now()
     where referido_id = v_ref.referido_id;
  end if;
  return new;
end;
$$;

revoke execute on function public.club_referido_al_entregar() from public, anon, authenticated;
revoke execute on function public.club_al_pagar()             from public, anon, authenticated;
revoke execute on function public.club_al_cancelar()          from public, anon, authenticated;

-- 6. Nueva versión de los textos legales (terminos.html, sección 12)
update public.parametros set valor = '2026-11-21' where clave = 'terminos_version';

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261121000018', '18_referidos_seguros') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
