// Docs search. The index is fetched once, on first interaction, so a reader who
// never searches pays nothing for it.
//
// The whole block starts hidden and is revealed here: without JavaScript a
// search box that cannot search is worse than no search box.
(() => {
  const root = document.querySelector('[data-search]');
  if (!root) return;

  const input = root.querySelector('input');
  const output = root.querySelector('[data-search-results]');
  const status = root.querySelector('[data-search-status]');
  if (!input || !output || !status) return;

  root.hidden = false;

  let index = null;
  let loading = null;

  const load = () => {
    if (index) return Promise.resolve(index);
    if (!loading) {
      loading = fetch(root.dataset.search)
        .then((r) => {
          if (!r.ok) throw new Error(r.status);
          return r.json();
        })
        .then((data) => {
          index = data;
          return index;
        })
        .catch(() => {
          index = [];
          status.textContent = 'Search is unavailable.';
          return index;
        });
    }
    return loading;
  };

  // Every term has to appear somewhere in the record, so "imds port" finds the
  // page that mentions both rather than everything mentioning either.
  const search = (query) => {
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    if (!terms.length) return [];

    return index
      .map((rec) => {
        const title = rec.t.toLowerCase();
        const hay = `${rec.t} ${rec.s} ${rec.d} ${rec.b}`.toLowerCase();
        if (!terms.every((t) => hay.includes(t))) return null;
        // A title match beats a body match, and a title that starts with the
        // query beats one that merely contains it.
        let score = 0;
        for (const t of terms) {
          if (title.startsWith(t)) score += 4;
          else if (title.includes(t)) score += 2;
        }
        return { rec, score };
      })
      .filter(Boolean)
      .sort((a, b) => b.score - a.score)
      .slice(0, 8)
      .map((m) => m.rec);
  };

  const render = (results, query) => {
    output.textContent = '';

    if (!query) {
      status.textContent = '';
      return;
    }

    if (!results.length) {
      status.textContent = `No pages match “${query}”.`;
      return;
    }

    status.textContent = `${results.length} ${results.length === 1 ? 'page' : 'pages'} match “${query}”.`;

    for (const rec of results) {
      const li = document.createElement('li');
      const a = document.createElement('a');
      a.href = rec.u;
      a.className = 'search__hit';

      const title = document.createElement('span');
      title.className = 'search__hit-title';
      title.textContent = rec.t;
      a.append(title);

      if (rec.s) {
        const section = document.createElement('span');
        section.className = 'search__hit-section';
        section.textContent = rec.s;
        a.append(section);
      }

      li.append(a);
      output.append(li);
    }
  };

  let timer;
  const run = () => {
    const query = input.value.trim();
    if (!query) {
      render([], '');
      return;
    }
    load().then(() => render(search(query), query));
  };

  input.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(run, 120);
  });

  // Warm the index on focus so the first keystroke has it ready.
  input.addEventListener('focus', load, { once: true });

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      input.value = '';
      render([], '');
      input.blur();
    }
    // Down from the field moves into the results.
    if (e.key === 'ArrowDown') {
      const first = output.querySelector('a');
      if (first) {
        e.preventDefault();
        first.focus();
      }
    }
  });

  output.addEventListener('keydown', (e) => {
    const links = [...output.querySelectorAll('a')];
    const i = links.indexOf(document.activeElement);
    if (i === -1) return;
    if (e.key === 'ArrowDown' && links[i + 1]) {
      e.preventDefault();
      links[i + 1].focus();
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      (links[i - 1] || input).focus();
    }
  });
})();
