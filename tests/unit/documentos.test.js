/* Boletas y facturas en la tienda (opción A: emisión en Haulmer + PDF en la tienda, migración 19) — 9 pruebas
   Caso CP-U41: el panel prepara los datos igual que los documentos de Haulmer (boleta N° 11298 y factura
   N° 496 reales), lee tipo y folio del nombre del PDF, valida antes de subir, y el cliente descarga solo
   lo suyo con un enlace temporal. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
const WEB = path.join(__dirname, "..", "..", "web");
const PED = "8f1c2d3e-4b5a-4c6d-8e7f-901234567890";
const recarga = (cantidad, sku = "BEF-REC-20-BEFINE") => ({ cantidad, precio_unitario: 2500, subtotal: cantidad * 2500,
  variante: { sku, nombre: "Con bidón Befine", producto: { nombre: "Recarga Bidón 20 L" } } });

test("CP-U41a neto e IVA como Haulmer: boleta N° 11298 ($10.000) y factura N° 496 ($25.000)", () => {
  assert.equal(JSON.stringify(L.montosDTE(10000)), JSON.stringify({ neto: 8403, iva: 1597, total: 10000 }));
  assert.equal(JSON.stringify(L.montosDTE(25000)), JSON.stringify({ neto: 21008, iva: 3992, total: 25000 }));
  assert.equal(L.netoUnitario(2500), 2100.84);                         // precio neto de la factura N° 496
  assert.equal(L.fmtCLP(2100.84, 2), "$2.100,84");
  assert.equal(L.valorPegar(2100.84, 2), "2100,84");
  assert.equal(L.valorPegar(2500), "2500");
});

test("CP-U41b datos de boleta: precio con IVA, código = SKU, despacho como línea aparte", () => {
  const d = L.datosHaulmer({ tipo_documento: "boleta", total: 12500, costo_despacho: 2500, descuento_cupon: 0, detalle_pedido: [recarga(4)] });
  assert.equal(d.tipo, "boleta"); assert.equal(d.codigoSII, 39); assert.equal(d.receptor, null);
  assert.equal(d.lineas.length, 2);
  assert.equal(JSON.stringify(d.lineas[0]), JSON.stringify({ codigo: "BEF-REC-20-BEFINE", nombre: "Recarga Bidón 20 L (Con bidón Befine)", cantidad: 4, precio: 2500, dec: 0 }));
  assert.equal(d.lineas[1].nombre, "Despacho a domicilio");
  assert.equal(d.montos.total, 12500);
});

test("CP-U41c datos de factura: receptor completo, precio neto con 2 decimales y forma de pago Contado", () => {
  const d = L.datosHaulmer({ tipo_documento: "factura", total: 25000, costo_despacho: 0, doc_rut: "760864285",
    doc_razon_social: "Empresa Prueba SpA", doc_giro: "Servicios", contacto_email: "compras@empresa.cl",
    direccion: { calle: "Evaristo Lillo", numero: "78", depto: "71", comuna: "Las Condes" }, detalle_pedido: [recarga(10)] });
  assert.equal(d.codigoSII, 33); assert.equal(d.formaPago, "Contado");
  assert.equal(d.receptor.rut, "76.086.428-5");
  assert.equal(d.receptor.direccion, "Evaristo Lillo 78, 71");
  assert.equal(d.lineas[0].precio, 2100.84); assert.equal(d.lineas[0].dec, 2);
  assert.equal(JSON.stringify(d.montos), JSON.stringify({ neto: 21008, iva: 3992, total: 25000 }));
});

test("CP-U41d tipo y folio desde el nombre del PDF de Haulmer", () => {
  assert.equal(JSON.stringify(L.leerNombreDTE("boleta_DTE_39-_Empresa_77861415_-_Folio_N__11298.pdf")), JSON.stringify({ tipo: "boleta", folio: 11298 }));
  assert.equal(JSON.stringify(L.leerNombreDTE("DTE_33-_Empresa_77861415_-_Folio_N__496.pdf")), JSON.stringify({ tipo: "factura", folio: 496 }));
  assert.equal(L.leerNombreDTE("foto.pdf"), null);
});

test("CP-U41e validación antes de subir (casos de error)", () => {
  const pdf = { name: "DTE_39-_Empresa_77861415_-_Folio_N__11298.pdf", type: "application/pdf", size: 50000 };
  assert.equal(L.validarDocumento(pdf, "boleta", 11298), "");
  assert.match(L.validarDocumento(null, "boleta", 1), /Elige el PDF/);
  assert.match(L.validarDocumento({ name: "x.png", type: "image/png", size: 10 }, "boleta", 1), /PDF/);
  assert.match(L.validarDocumento({ ...pdf, size: 4 * 1024 * 1024 }, "boleta", 1), /3 MB/);
  assert.match(L.validarDocumento(pdf, "boleta", 0), /folio/);
  assert.match(L.validarDocumento(pdf, "factura", 11298), /es una boleta y el cliente pidió factura/);
});

test("CP-U41f boleta pendiente: solo pedidos pagados con monto y sin documento emitido", () => {
  assert.equal(L.pendienteDocumento({ estado: "entregado", total: 7500 }), true);
  assert.equal(L.pendienteDocumento({ estado: "pendiente_pago", total: 7500 }), false);
  assert.equal(L.pendienteDocumento({ estado: "cancelado", total: 7500 }), false);
  assert.equal(L.pendienteDocumento({ estado: "pagado", total: 0 }), false);           // canje de $0
  assert.equal(L.pendienteDocumento({ estado: "pagado", total: 7500, documentos_tributarios: [{ estado: "emitido", folio: 1 }] }), false);
});

test("CP-U41g Mis pedidos: el PDF del bucket privado se descarga con enlace temporal y solo con una ruta válida", async () => {
  const llamadas = [];
  const cliente = { auth: { getSession: async () => ({ data: { session: null } }), onAuthStateChange: () => ({}) },
    storage: { from: (b) => ({ createSignedUrl: async (ruta, seg) => { llamadas.push([b, ruta, seg]); return { data: { signedUrl: "https://x/firmado" }, error: null }; } }) } };
  const { Befine } = cargar(["data.js"], { cliente });
  const d = Befine.armarDetalle({ id: PED, estado: "entregado", tipo_documento: "boleta",
    documentos_tributarios: [{ tipo: "boleta", estado: "emitido", folio: 11298, url_pdf: null, archivo: `${PED}/boleta-11298.pdf` }] });
  assert.equal(d.boleta.archivo, `${PED}/boleta-11298.pdf`);
  assert.equal(Befine.estadoDocumento(d), "descargar");
  assert.equal(await Befine.urlDocumento(d.boleta.archivo), "https://x/firmado");
  assert.equal(JSON.stringify(llamadas[0]), JSON.stringify(["documentos", `${PED}/boleta-11298.pdf`, 600]));
  assert.equal(await Befine.urlDocumento("../otro/archivo.pdf"), null);           // ruta inválida: no consulta
  assert.equal(llamadas.length, 1);
  const malo = Befine.armarDetalle({ id: PED, estado: "entregado", documentos_tributarios: [{ tipo: "boleta", estado: "emitido", folio: 1, archivo: "x/../y.pdf" }] });
  assert.equal(malo.boleta, null);
});

test("CP-U41h la migración 19 protege los PDF y valida el registro", () => {
  const sql = fs.readFileSync(path.join(WEB, "supabase", "migrations", "20261122_19_documentos_tributarios.sql"), "utf8");
  assert.match(sql, /values \('documentos', 'documentos', false, 3145728, array\['application\/pdf'\]\)/);   // bucket privado
  assert.match(sql, /create policy documentos_ver on storage\.objects[\s\S]*?p\.perfil_id = auth\.uid\(\)/);
  assert.match(sql, /if not public\.tiene_permiso\('documentos\.gestionar'\) then/);
  assert.match(sql, /v_neto := round\(v_p\.total \/ 1\.19\);/);
  assert.match(sql, /'folio_repetido'/);
  assert.match(sql, /'archivo_no_encontrado'/);
  for (const f of ["20261122_19_documentos_tributarios_reversa.sql", "20261122_19_prueba_en_seco.sql"])
    assert.ok(fs.existsSync(path.join(WEB, "supabase", "migrations", f)), f);
  const ped = fs.readFileSync(path.join(WEB, "js", "admin-pedidos.js"), "utf8");
  assert.match(ped, /app\.puede\("documentos\.gestionar"\)/);
});

test("CP-U41i filtro \"Sin boleta/factura\": lista y cuenta solo los pedidos que esperan documento", () => {
  const ped = (numero, estado, total, docs = []) => ({ numero, estado, total, documentos_tributarios: docs });
  const lista = [
    ped(1, "entregado", 10000),                                                   // pendiente
    ped(2, "en_preparacion", 5000),                                               // pendiente
    ped(3, "entregado", 7500, [{ tipo: "boleta", folio: 11298, estado: "emitido" }]), // ya tiene boleta
    ped(4, "pendiente_pago", 2500),                                               // sin pagar
    ped(5, "cancelado", 2500),                                                    // cancelado
    ped(6, "entregado", 0),                                                       // canje sin monto
  ];
  const nums = (xs) => xs.map((p) => p.numero);
  assert.deepEqual(nums(L.filtrarPedidos(lista, { estado: "sin_documento" })), [1, 2]);
  assert.deepEqual(nums(L.filtrarPedidos(lista, { estado: "sin_documento", q: "#2" })), [2]);
  assert.equal(L.contarPorEstado(lista).sin_documento, 2);
  assert.equal(L.contarPorEstado(lista).sin_documento, lista.filter(L.pendienteDocumento).length); // = tarjeta del panel
  const js = fs.readFileSync(path.join(WEB, "js", "admin-pedidos.js"), "utf8");
  assert.match(js, /\["sin_documento", "Sin boleta\/factura"\]/);              // chip solo con documentos.gestionar
  assert.match(js, /data-kpi-doc/);                                              // la tarjeta filtra al hacer clic
});
