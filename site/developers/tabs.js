// Language tabs for code samples. The chosen language is remembered.
(function () {
  let preferred = null;
  try { preferred = localStorage.getItem('mp_dev_lang'); } catch (e) { /* ignore */ }
  document.querySelectorAll('.tabs-code').forEach(function (bar) {
    const group = bar.dataset.group;
    const panels = Array.prototype.slice.call(document.querySelectorAll('.code-panel[data-group="' + group + '"]'));
    function show(lang) {
      panels.forEach(function (p) { p.hidden = p.dataset.lang !== lang; });
      bar.querySelectorAll('button').forEach(function (b) { b.setAttribute('aria-selected', String(b.textContent === lang)); });
    }
    panels.forEach(function (p) {
      const b = document.createElement('button');
      b.type = 'button'; b.setAttribute('role', 'tab'); b.textContent = p.dataset.lang;
      b.addEventListener('click', function () {
        show(p.dataset.lang);
        try { localStorage.setItem('mp_dev_lang', p.dataset.lang); } catch (e) { /* ignore */ }
      });
      bar.appendChild(b);
    });
    const match = panels.find(function (p) { return p.dataset.lang === preferred; });
    show(match ? match.dataset.lang : panels[0].dataset.lang);
  });
})();
