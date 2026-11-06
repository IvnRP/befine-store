/* =====================================================================
   legal.js — Completa las páginas legales con los datos del negocio
   - [data-pv="campo"]  → dato de Befine.proveedor (o "[Por completar]" destacado si falta)
   - [data-wa]          → enlace de WhatsApp del negocio; [data-wa-num] → número legible
   - [data-version]     → versión vigente de los textos (Befine.legalVersion)
   - #tablaCobertura    → comunas, zonas y costos de despacho LEÍDOS DE LA BASE (no fijos en el código)
   ===================================================================== */
(function () {
  const PV = Befine.proveedor || {};
  const wa = (Befine.contacto && Befine.contacto.whatsapp) || "";
  const waLegible = wa.replace(/^56(9)(\d{4})(\d{4})$/, "+56 $1 $2 $3");
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  document.querySelectorAll("[data-pv]").forEach((el) => {
    const v = PV[el.dataset.pv];
    el.textContent = v || "[Por completar]";
    el.classList.toggle("pendiente", !v);
  });
  document.querySelectorAll("[data-wa]").forEach((a) => { a.href = "https://wa.me/" + wa; a.target = "_blank"; a.rel = "noopener"; });
  document.querySelectorAll("[data-wa-num]").forEach((el) => { el.textContent = waLegible; });
  document.querySelectorAll("[data-version]").forEach((el) => { el.textContent = Befine.legalVersion; });

  const tabla = document.getElementById("tablaCobertura");
  if (tabla) {
    Befine.getCobertura().then((c) => {
      const filas = (c.comunas || []).map((x) => `<tr><td>${esc(x.comuna)}</td><td>${esc(x.zona || "")}</td><td>${x.costo === 0 ? "Gratis" : Befine.clp(x.costo)}</td></tr>`).join("");
      tabla.innerHTML = filas || `<tr><td colspan="3">No pudimos cargar las comunas. Escríbenos por WhatsApp.</td></tr>`;
      document.querySelectorAll("[data-envio-gratis]").forEach((el) => {
        el.textContent = c.envioGratisDesde ? Befine.clp(c.envioGratisDesde) : "el monto informado en el checkout";
      });
    }).catch(() => { tabla.innerHTML = `<tr><td colspan="3">No pudimos cargar las comunas. Escríbenos por WhatsApp.</td></tr>`; });
  }
})();
