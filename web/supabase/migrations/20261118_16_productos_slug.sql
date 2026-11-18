-- =====================================================================
-- Migración 16: dirección amigable (slug) de cada producto para SEO
-- Proyecto:  Befine Store (Supabase tbnevbvvwwzpnowxqyps)
-- Historia:  Auditoría SEO 18-nov-2026 · RF-02 (ficha de producto) · RNF de posicionamiento
-- Requiere:  01 a 15 aplicadas.
-- Aplicar:   ANTES de publicar la versión del sitio que usa /productos/<slug> (la tienda
--            sigue funcionando con producto?id=... mientras tanto).
-- Reversa:   20261118_16_productos_slug_reversa.sql
-- Prueba:    20261118_16_prueba_en_seco.sql (16 + prueba; T01..T08)
--
-- Qué hace:
--   1. productos.slug: texto único con letras minúsculas, números y guiones
--      (ej. recarga-agua-purificada-bidon-20-litros). La ficha queda en
--      https://aguabefine.cl/productos/<slug>.
--   2. Carga las 11 direcciones decididas por el dueño (claras y con palabras que busca
--      la gente). Cualquier otro producto recibe una a partir de su nombre.
--   3. Trigger: si el panel crea o guarda un producto SIN slug, se genera solo desde el
--      nombre y, si ya existe, se le agrega -2, -3…
-- Sin cambios de permisos: el slug se lee igual que el resto del producto (RLS existente).
-- =====================================================================

-- 1. Función que convierte un texto en slug: "Bidón + Recarga 12 Litros" -> "bidon-recarga-12-litros"
create or replace function public.slug_de(p_texto text)
returns text language sql immutable set search_path = public as $$
  select nullif(left(trim(both '-' from regexp_replace(
           lower(translate(coalesce(p_texto, ''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')),
           '[^a-z0-9]+', '-', 'g')), 80), '')
$$;

-- 2. Columna (todavía sin restricciones, para poder cargarla)
alter table public.productos add column if not exists slug text;

-- 3. Direcciones decididas por el dueño (por nombre del producto)
update public.productos p set slug = x.slug
  from (values
    ('Recarga Bidón 20 Litros',                                            'recarga-agua-purificada-bidon-20-litros'),
    ('Recarga Bidón 12 Litros',                                            'recarga-agua-purificada-bidon-12-litros'),
    ('Bidón + Recarga 20 Litros',                                          'bidon-20-litros-con-agua-purificada'),
    ('Bidón + Recarga 12 Litros',                                          'bidon-12-litros-con-agua-purificada'),
    ('Pack Inicial — 3 Bidones de 20 Litros + Dispensador Soporte Blanco', 'pack-3-bidones-20-litros-con-dispensador'),
    ('Pack Inicial — 4 Recargas de 12 Litros + Dispensador Soporte Blanco','pack-4-bidones-12-litros-con-dispensador'),
    ('Dispensador Compresor Sobre Mesa',                                   'dispensador-agua-fria-caliente-sobre-mesa'),
    ('Dispensador Compresor con Bidón Oculto',                             'dispensador-agua-fria-caliente-bidon-oculto'),
    ('Dispensador Compresor SIN Bidón Oculto',                             'dispensador-agua-fria-caliente-pedestal'),
    ('Dispensador con Carga USB',                                          'dispensador-electrico-usb-para-bidon'),
    ('Dispensador Soporte Plástico Blanco',                                'dispensador-soporte-para-bidon')
  ) as x(nombre, slug)
 where p.nombre = x.nombre and p.slug is null;

-- 4. Trigger: genera el slug si viene vacío y evita repetidos (-2, -3…)
create or replace function public._productos_slug()
returns trigger language plpgsql set search_path = public as $$
declare v_base text; v_slug text; n int := 1;
begin
  new.slug := nullif(trim(new.slug), '');
  if new.slug is not null then return new; end if;   -- el panel lo valida; la restricción única avisa si se repite
  v_base := coalesce(public.slug_de(new.nombre), 'producto');
  v_slug := v_base;
  while exists (select 1 from public.productos where slug = v_slug and id <> new.id) loop
    n := n + 1; v_slug := left(v_base, 76) || '-' || n;
  end loop;
  new.slug := v_slug;
  return new;
end;
$$;
drop trigger if exists trg_productos_slug on public.productos;
create trigger trg_productos_slug before insert or update of slug, nombre on public.productos
  for each row execute function public._productos_slug();

-- 5. Productos sin slug (creados en el panel): se generan desde el nombre
update public.productos set slug = null where slug is null;   -- dispara el trigger

-- 6. Restricciones
do $m16$
begin
  if exists (select 1 from public.productos where slug is null) then
    raise exception 'Quedó un producto sin slug.';
  end if;
end;
$m16$;
alter table public.productos alter column slug set not null;
alter table public.productos drop constraint if exists productos_slug_formato;
alter table public.productos add constraint productos_slug_formato
  check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) <= 80);
create unique index if not exists productos_slug_unico on public.productos (slug);
comment on column public.productos.slug is
  'Dirección amigable de la ficha: https://aguabefine.cl/productos/<slug> (SEO, migración 16).';

-- Registro en el historial de migraciones de Supabase (si existe)
do $reg$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$insert into supabase_migrations.schema_migrations (version, name)
               values ('20261118000016', '16_productos_slug') on conflict do nothing$q$;
  end if;
exception when others then
  raise notice 'No se pudo registrar en schema_migrations: %', sqlerrm;
end;
$reg$;
