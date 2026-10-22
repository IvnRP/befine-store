-- =====================================================================
-- Migración 01b: 20261009_01b_proteger_es_empresa
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Requiere:  01_seguridad_roles aplicada.
-- Reversa:   volver a ejecutar la función de la migración 01 (sección 3).
--
-- Qué hace: "es_empresa" (cliente B2B) pasa a ser un campo protegido.
-- Solo el admin o quien tenga el permiso clientes.gestionar puede marcar
-- a un cliente como empresa. Así, si a futuro las empresas tienen precios
-- o condiciones especiales, un cliente no puede activárselas solo.
-- (Razón social y giro siguen editables por el cliente para su factura.)
-- =====================================================================

create or replace function public.proteger_campos_perfil()
returns trigger language plpgsql security invoker set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;                                   -- cambio interno del servidor
  end if;
  if not public.es_admin() then
    new.rol := old.rol;                           -- roles: solo admin
    if not public.tiene_permiso('clientes.gestionar') then
      new.nivel_precio_id := old.nivel_precio_id;
      new.activo          := old.activo;
      new.es_empresa      := old.es_empresa;      -- cliente B2B: lo define el negocio
    end if;
    new.puntos_saldo := old.puntos_saldo;         -- puntos: solo vía movimientos_puntos
  end if;
  return new;
end;
$$;

revoke execute on function public.proteger_campos_perfil() from public, anon, authenticated;
