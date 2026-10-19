-- =====================================================================
-- REVERSA de la migración 01: 20261009_01_seguridad_roles
-- Deja políticas, funciones y perfiles.rol como estaban el 2026-10-08.
-- No borra pedidos, perfiles ni direcciones. SÍ pierde:
--   - los roles personalizados (sus usuarios vuelven a 'cliente'),
--   - las columnas nuevas de pedidos (contacto, fecha de entrega, boleta/factura).
-- Si ya se aplicaron 02 o 03, revertir esas primero.
-- =====================================================================

-- 1. Funciones nuevas fuera
drop function if exists public.crear_pedido(jsonb, jsonb, jsonb, jsonb, jsonb, text, text);
drop function if exists public.normalizar_telefono_cl(text);
drop function if exists public.es_rut_valido(text);
alter table public.pedidos
  drop column if exists contacto_nombre,
  drop column if exists contacto_telefono,
  drop column if exists contacto_email,
  drop column if exists fecha_entrega,
  drop column if exists tipo_documento,
  drop column if exists doc_rut,
  drop column if exists doc_razon_social,
  drop column if exists doc_giro;
drop function if exists public.precio_efectivo(uuid);

create function public.precio_efectivo(p_perfil uuid, p_variante uuid)
returns integer language sql stable security definer set search_path to 'public' as $$
  select pv.precio
    from public.precios_variante pv
    join public.perfiles pf on pf.id = p_perfil
   where pv.variante_id = p_variante and pv.nivel_precio_id = pf.nivel_precio_id;
$$;

-- 2. Políticas originales (es_admin)
alter policy categorias_admin  on public.categorias          using (public.es_admin()) with check (public.es_admin());
alter policy productos_admin   on public.productos           using (public.es_admin()) with check (public.es_admin());
alter policy variantes_admin   on public.variantes_producto  using (public.es_admin()) with check (public.es_admin());
alter policy precios_var_admin on public.precios_variante    using (public.es_admin()) with check (public.es_admin());
alter policy niveles_admin     on public.niveles_precio      using (public.es_admin()) with check (public.es_admin());
alter policy cupones_admin     on public.cupones             using (public.es_admin()) with check (public.es_admin());
alter policy cupon_var_admin   on public.cupon_variantes     using (public.es_admin()) with check (public.es_admin());
alter policy recompensas_admin on public.recompensas         using (public.es_admin()) with check (public.es_admin());
alter policy zonas_admin       on public.zonas_despacho      using (public.es_admin()) with check (public.es_admin());
alter policy comunas_admin     on public.comunas_cobertura   using (public.es_admin()) with check (public.es_admin());
alter policy parametros_admin  on public.parametros          using (public.es_admin()) with check (public.es_admin());
alter policy pedidos_admin     on public.pedidos             using (public.es_admin()) with check (public.es_admin());
alter policy detalle_admin     on public.detalle_pedido      using (public.es_admin()) with check (public.es_admin());
alter policy historial_admin   on public.historial_pedido    using (public.es_admin()) with check (public.es_admin());
alter policy pagos_admin       on public.pagos               using (public.es_admin()) with check (public.es_admin());
alter policy dte_admin         on public.documentos_tributarios using (public.es_admin()) with check (public.es_admin());
alter policy mov_puntos_admin  on public.movimientos_puntos  using (public.es_admin()) with check (public.es_admin());

alter policy productos_lectura   on public.productos          using ((activo = true) or public.es_admin());
alter policy variantes_lectura   on public.variantes_producto using ((activo = true) or public.es_admin());
alter policy recompensas_lectura on public.recompensas        using ((activo = true) or public.es_admin());
alter policy cupones_lectura     on public.cupones
  using (((activo = true) and (perfil_id is null)) or (perfil_id = auth.uid()) or public.es_admin());

alter policy pedidos_select   on public.pedidos          using ((perfil_id = auth.uid()) or public.es_admin());
alter policy detalle_select   on public.detalle_pedido   using (exists (select 1 from public.pedidos p where p.id = detalle_pedido.pedido_id   and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy historial_select on public.historial_pedido using (exists (select 1 from public.pedidos p where p.id = historial_pedido.pedido_id and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy pagos_select     on public.pagos            using (exists (select 1 from public.pedidos p where p.id = pagos.pedido_id            and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy dte_select       on public.documentos_tributarios using (exists (select 1 from public.pedidos p where p.id = documentos_tributarios.pedido_id and ((p.perfil_id = auth.uid()) or public.es_admin())));
alter policy mov_puntos_select on public.movimientos_puntos using ((perfil_id = auth.uid()) or public.es_admin());
alter policy perfiles_select   on public.perfiles           using ((id = auth.uid()) or public.es_admin());

drop policy if exists direcciones_reparto   on public.direcciones;
drop policy if exists perfiles_staff_update on public.perfiles;

create policy pedidos_insert on public.pedidos for insert to authenticated
  with check (perfil_id = auth.uid());
create policy detalle_insert on public.detalle_pedido for insert to authenticated
  with check (exists (select 1 from public.pedidos p
                       where p.id = detalle_pedido.pedido_id and p.perfil_id = auth.uid()
                         and p.estado = 'pendiente_pago'::estado_pedido));

-- 3. perfiles.rol vuelve al enum app_rol
create type public.app_rol as enum ('cliente', 'operador', 'admin', 'repartidor');
alter table public.perfiles drop constraint if exists perfiles_rol_fkey;
alter table public.perfiles alter column rol drop default;
alter table public.perfiles alter column rol type public.app_rol
  using (case rol when 'chofer' then 'repartidor'
                  when 'cliente' then 'cliente' when 'admin' then 'admin'
                  when 'operador' then 'operador' when 'repartidor' then 'repartidor'
                  else 'cliente' end)::public.app_rol;
alter table public.perfiles alter column rol set default 'cliente'::public.app_rol;

-- 4. Funciones originales
create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfiles
                  where id = auth.uid() and rol in ('admin','operador'));
$$;

create or replace function public.proteger_campos_perfil()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.es_admin() then
    new.rol             := old.rol;
    new.nivel_precio_id := old.nivel_precio_id;
    new.puntos_saldo    := old.puntos_saldo;
  end if;
  return new;
end;
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.perfiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)));
  return new;
end;
$$;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;

-- 5. Tablas de roles fuera
drop function if exists public.tiene_permiso(text);
drop table if exists public.rol_permisos;
drop table if exists public.permisos;
drop table if exists public.roles;

-- 6. Permisos de ejecución como estaban
grant execute on function public.handle_new_user()                to public, anon, authenticated;
grant execute on function public.proteger_campos_perfil()         to public, anon, authenticated;
grant execute on function public.aplicar_movimiento_puntos()      to public, anon, authenticated;
grant execute on function public.registrar_cambio_estado_pedido() to public, anon, authenticated;
grant execute on function public.set_updated_at()                 to public, anon, authenticated;
grant execute on function public.precio_efectivo(uuid, uuid)      to public, anon, authenticated;
