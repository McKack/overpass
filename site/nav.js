// The fades in nav.css show while there's more page above or below.
const root = document.documentElement;
function edges() {
  root.classList.toggle('above', scrollY > 4);
  root.classList.toggle('below', scrollY + innerHeight < root.scrollHeight - 4);
}
addEventListener('scroll', edges, { passive: true });
addEventListener('resize', edges);
new ResizeObserver(edges).observe(document.body);
edges();

// The header's path grows with the pages someone goes through, from the logo. Each page leaves its path behind for the
// next one; the page that takes it keeps it in its history entry, so a reload or Back shows the same path. Going to a
// page already on the path cuts it back there. A top page (data-top) keeps the path the server gave it.
const bar = document.querySelector('.top');
if (bar) trail(bar);
function trail(nav) {
  const KEY = 'overpass-path', LONGEST = 4;
  const page = (path) => path.split('?')[0];
  const here = { path: location.pathname + location.search, name: nav.dataset.page };
  let { path, came } = history.state ?? {}, last = null;
  try { last = JSON.parse(sessionStorage.getItem(KEY)); } catch {}
  if (!path) {
    path = [...nav.querySelectorAll('.crumb a')].map((link) => ({ path: link.getAttribute('href'), name: link.textContent }));
    const from = document.referrer ? new URL(document.referrer) : null;
    if (last?.here && from?.origin === location.origin && from.pathname === page(last.here.path) && from.pathname !== location.pathname) {
      came = last.here.path;
      const before = [...last.path, last.here].filter((step) => step.path !== '/');
      const at = before.findIndex((step) => page(step.path) === location.pathname);
      if (at >= 0) path = before.slice(0, at);
      else if (!('top' in nav.dataset)) path = before.slice(-LONGEST);
    }
    try { history.replaceState({ ...history.state, path, came }, ''); } catch {}
  }
  try { sessionStorage.setItem(KEY, JSON.stringify({ path, here })); } catch {}

  const steps = nav.querySelector('.trail');
  steps.querySelectorAll('.crumb').forEach((crumb) => crumb.remove());
  for (const [index, step] of path.entries()) {
    const crumb = document.createElement('span'), link = document.createElement('a');
    crumb.className = 'crumb';
    link.href = step.path;
    link.textContent = link.title = step.name;
    if (index === path.length - 1) link.className = 'up';
    crumb.append(link);
    steps.append(crumb);
  }
  if (location.pathname !== '/') {
    const crumb = document.createElement('span'), name = document.createElement('span');
    crumb.className = 'crumb here';
    crumb.setAttribute('aria-current', 'page');
    name.textContent = name.title = here.name;
    crumb.append(name);
    steps.append(crumb);
  }
  // The page just before, by Back rather than a new visit: a list keeps its place, filters and scroll.
  steps.querySelector('.up')?.addEventListener('click', (event) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button || event.currentTarget.getAttribute('href') !== came) return;
    event.preventDefault();
    history.back();
  });
}
