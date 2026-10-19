/* Pruebas de las reglas del panel de administración (web/js/admin-logic.js)
   Casos CP-U14 (acceso por rol) y CP-U15 (pedidos) del Plan de Pruebas. */
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { cargar } = require("../helpers/cargar");

const { AdminLogic: L } = cargar(["admin-logic.js"]);
const arr = (x) => Array.from(x);   // los arreglos vienen del contexto aislado

test("CP-U14a el admin tiene todos los permisos y el cliente ninguno", () => {
  assert.equal(L.permisosDe("admin", []).length, 12);
  assert.deepEqual(arr(L.permisosDe("cliente", [{ rol_id: "cliente", permiso: "pedidos.ver" }])), []);
  assert.deepEqual(arr(L.permisosDe(null, [])), []);
});

test("CP-U14b un rol del equipo solo tiene los permisos que el admin le asignó", () => {
  const filas = [
    { rol_id: "chofer", permiso: "pedidos.ver" },
    { rol_id: "chofer", permiso: "pedidos.ver" },          // duplicado: se cuenta una vez
    { rol_id: "bodega", permiso: "catalogo.gestionar" },   // otro rol: no aplica
  ];
  assert.deepEqual(arr(L.permisosDe("chofer", filas)), ["pedidos.ver"]);
});

test("CP-U14c el panel muestra solo las secciones permitidas", () => {
  const ids = (p) => arr(L.seccionesVisibles(p)).map((s) => s.id);
  assert.ok(ids(L.permisosDe("admin", [])).includes("pedidos"));
  assert.deepEqual(ids(["pedidos.ver"]), ["pedidos"]);
  assert.deepEqual(ids([]), []);                       // cliente: sin acceso al panel
});

/* ---------- Pedidos (RF-16) — CP-U15 ---------- */
const pedidos = [
  { id: "a", numero: 101, estado: "pendiente_pago", total: 5000, created_at: "2026-10-19T10:00:00", fecha_entrega: "2026-10-20", contacto_nombre: "María José Pérez", contacto_telefono: "56991234567", direccion: { comuna: "Quilicura" } },
  { id: "b", numero: 102, estado: "pagado",         total: 8000, created_at: "2026-10-19T11:00:00", fecha_entrega: "2026-10-19", contacto_nombre: "Juan Soto",         contacto_telefono: "56987654321", direccion: { comuna: "Huechuraba" } },
  { id: "c", numero: 103, estado: "en_ruta",        total: 3000, created_at: "2026-10-18T09:00:00", fecha_entrega: "2026-10-19", contacto_nombre: "Ana Fuentes",       contacto_telefono: "56911112222", direccion: { comuna: "Recoleta" } },
  { id: "d", numero: 104, estado: "entregado",      total: 6000, created_at: "2026-09-30T09:00:00", fecha_entrega: "2026-10-01", contacto_nombre: "Luis Araya",        contacto_telefono: "56933334444", direccion: { comuna: "Quilicura" } },
  { id: "e", numero: 105, estado: "cancelado",      total: 9000, created_at: "2026-10-19T08:00:00", fecha_entrega: "2026-10-20", contacto_nombre: "Rosa Muñoz",        contacto_telefono: "56955556666", direccion: { comuna: "Quilicura" } },
];
const nums = (l) => arr(l).map((p) => p.numero);

test("CP-U15a el panel no puede marcar 'pagado' (solo Mercado Pago) y los estados finales no cambian", () => {
  assert.deepEqual(arr(L.siguientesEstados("pendiente_pago")), ["cancelado"]);
  assert.equal(L.puedeCambiar("pendiente_pago", "pagado"), false);
  assert.equal(L.puedeCambiar("pagado", "en_preparacion"), true);
  assert.equal(L.puedeCambiar("en_preparacion", "en_ruta"), true);
  assert.equal(L.puedeCambiar("en_ruta", "entregado"), true);
  assert.equal(L.puedeCambiar("en_ruta", "cancelado"), false);   // ya salió a reparto
  assert.deepEqual(arr(L.siguientesEstados("entregado")), []);
  assert.deepEqual(arr(L.siguientesEstados("cancelado")), []);
  assert.deepEqual(arr(L.siguientesEstados("inventado")), []);
});

test("CP-U15b filtros por estado: 'para gestionar' son los pagados aún no entregados", () => {
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { estado: "activos" })), [102, 103]);
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { estado: "todos" })), [101, 102, 103, 104, 105]);
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { estado: "cancelado" })), [105]);
  const c = L.contarPorEstado(pedidos);
  assert.equal(c.todos, 5); assert.equal(c.activos, 2); assert.equal(c.pagado, 1); assert.equal(c.en_preparacion, 0);
});

test("CP-U15c búsqueda por número, nombre sin acentos, teléfono o comuna", () => {
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { q: "#103" })), [103]);
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { q: "maria jose" })), [101]);
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { q: "8765 4321" })), [102]);
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { q: "huechuraba" })), [102]);
  assert.deepEqual(nums(L.filtrarPedidos(pedidos, { q: "munoz", estado: "activos" })), []);
});

test("CP-U15d indicadores: pedidos de hoy, por preparar y ventas del mes (solo pagados)", () => {
  const r = L.resumenPedidos(pedidos, new Date(2026, 9, 19, 15));
  assert.equal(r.hoy, 2);            // 101 y 102 (el cancelado no cuenta)
  assert.equal(r.porPreparar, 1);    // 102
  assert.equal(r.enRuta, 1);
  assert.equal(r.pendientesPago, 1);
  assert.equal(r.entregaHoy, 2);     // 102 y 103 se entregan el 19
  assert.equal(r.ventasMes, 11000);  // 102 + 103 (104 es de septiembre; 101 sin pagar; 105 cancelado)
  assert.equal(r.pedidosMes, 2);
});

test("CP-U15e enlace de WhatsApp solo con celular chileno válido", () => {
  assert.equal(L.linkWhatsApp("56991234567", "Hola #1"), "https://wa.me/56991234567?text=Hola%20%231");
  assert.equal(L.linkWhatsApp("+56 9 9123 4567"), "https://wa.me/56991234567");
  assert.equal(L.linkWhatsApp("221234567"), null);
  assert.equal(L.linkWhatsApp(null), null);
  assert.equal(L.telefonoVisible("56991234567"), "+56 9 9123 4567");
});
