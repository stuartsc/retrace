/* Static, offline journal filtering. No data leaves this page. */
(() => {
  'use strict';
  const query = document.querySelector('#issue-search');
  const subsystem = document.querySelector('#issue-subsystem');
  const status = document.querySelector('#issue-status');
  const result = document.querySelector('#issue-count');
  const articles = Array.from(document.querySelectorAll('article.issue'));
  if (!query || !subsystem || !status || !result) return;
  function filter() {
    const words = query.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    let visible = 0;
    for (const article of articles) {
      const text = article.textContent.toLocaleLowerCase();
      const show = words.every(word => text.includes(word)) &&
        (!subsystem.value || article.dataset.subsystem === subsystem.value) &&
        (!status.value || article.dataset.status === status.value);
      article.hidden = !show;
      if (show) visible++;
    }
    result.textContent = `${visible} of ${articles.length} issues shown`;
    document.querySelector('#no-issues').hidden = visible !== 0;
  }
  query.addEventListener('input', filter);
  subsystem.addEventListener('change', filter);
  status.addEventListener('change', filter);
  document.querySelector('#clear-filters').addEventListener('click', () => {
    query.value = ''; subsystem.value = ''; status.value = ''; filter(); query.focus();
  });
  function revealAnchor() {
    const id = location.hash.slice(1);
    const target = articles.find(article => article.id === id);
    if (target) { query.value = ''; subsystem.value = ''; status.value = ''; filter(); target.scrollIntoView(); }
  }
  window.addEventListener('hashchange', revealAnchor);
  filter(); revealAnchor();
})();
