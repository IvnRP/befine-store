-- PRUEBA EN SECO de la migración 16 (slug de productos) — Befine Store
-- Uso: pegar en UNA misma consulta (1) 20261118_16_productos_slug.sql y (2) este archivo.
-- Termina SIEMPRE con un error intencional: todo se deshace. Busca FALLA: no debería aparecer.
do $do$
declare
  cat smallint; s1 text; s2 text; ok boolean;
  res text := 'RESULTADOS';
begin
  select id into cat from public.categorias order by id limit 1;

  res := res || chr(10) || 'T01 los 11 productos de la tienda tienen su dirección decidida: ' ||
    case when (select count(*) from public.productos where slug in (
      'recarga-agua-purificada-bidon-20-litros','recarga-agua-purificada-bidon-12-litros',
      'bidon-20-litros-con-agua-purificada','bidon-12-litros-con-agua-purificada',
      'pack-3-bidones-20-litros-con-dispensador','pack-4-bidones-12-litros-con-dispensador',
      'dispensador-agua-fria-caliente-sobre-mesa','dispensador-agua-fria-caliente-bidon-oculto',
      'dispensador-agua-fria-caliente-pedestal','dispensador-electrico-usb-para-bidon',
      'dispensador-soporte-para-bidon')) = 11 then 'OK' else 'FALLA' end;

  res := res || chr(10) || 'T02 ningún producto queda sin dirección: ' ||
    case when not exists (select 1 from public.productos where slug is null) then 'OK' else 'FALLA' end;

  res := res || chr(10) || 'T03 slug_de quita tildes, ñ y símbolos: ' ||
    case when public.slug_de('Bidón + Recarga 12 Litros') = 'bidon-recarga-12-litros'
          and public.slug_de('  Niño  Ñandú!! ') = 'nino-nandu' and public.slug_de('—') is null then 'OK'
         else 'FALLA ' || coalesce(public.slug_de('Bidón + Recarga 12 Litros'), 'null') end;

  insert into public.productos (categoria_id, nombre) values (cat, 'Producto Prueba Dieciséis') returning slug into s1;
  res := res || chr(10) || 'T04 producto nuevo sin slug recibe uno desde el nombre: ' ||
    case when s1 = 'producto-prueba-dieciseis' then 'OK' else 'FALLA ' || coalesce(s1, 'null') end;

  insert into public.productos (categoria_id, nombre, slug) values (cat, 'Producto Prueba Dieciséis', '') returning slug into s2;
  res := res || chr(10) || 'T05 nombre repetido recibe -2: ' ||
    case when s2 = 'producto-prueba-dieciseis-2' then 'OK' else 'FALLA ' || coalesce(s2, 'null') end;

  begin
    insert into public.productos (categoria_id, nombre, slug) values (cat, 'Otro', 'recarga-agua-purificada-bidon-20-litros');
    ok := false;
  exception when unique_violation then ok := true;
  end;
  res := res || chr(10) || 'T06 un slug repetido escrito a mano se rechaza: ' || case when ok then 'OK' else 'FALLA' end;

  begin
    insert into public.productos (categoria_id, nombre, slug) values (cat, 'Otro', 'Con Mayúsculas y espacios');
    ok := false;
  exception when check_violation then ok := true;
  end;
  res := res || chr(10) || 'T07 un slug con formato inválido se rechaza: ' || case when ok then 'OK' else 'FALLA' end;

  update public.productos set nombre = 'Producto Prueba Renombrado' where slug = 'producto-prueba-dieciseis';
  res := res || chr(10) || 'T08 cambiar el nombre NO cambia la dirección (los enlaces compartidos siguen sirviendo): ' ||
    case when exists (select 1 from public.productos where nombre = 'Producto Prueba Renombrado' and slug = 'producto-prueba-dieciseis')
         then 'OK' else 'FALLA' end;

  raise exception 'PRUEBA EN SECO 16 (todo se deshace): %', res;
end $do$;
