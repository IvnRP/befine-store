-- =====================================================================
-- Reversa de la migración 16 (slug de productos) — Befine Store
-- Publicar ANTES la versión del sitio que usa producto?id=... (la de slug dejaría de encontrar productos).
-- =====================================================================
drop trigger if exists trg_productos_slug on public.productos;
drop function if exists public._productos_slug();
drop index if exists public.productos_slug_unico;
alter table public.productos drop constraint if exists productos_slug_formato;
alter table public.productos drop column if exists slug;
drop function if exists public.slug_de(text);
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations where version = '20261118000016'$q$;
  end if;
end;
$reg$;
