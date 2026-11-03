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

// The path in the header goes back to the page someone came from, by name. Each page leaves its address and name
// behind for the next one; the page that takes it keeps it in its history entry, so a reload or Back keeps the path.
const bar = document.querySelector('.top');
if (bar) trail(bar);
function trail(nav) {
  const here = location.pathname + location.search, key = 'overpass-last';
  let back = history.state?.back, last = null;
  try { last = JSON.parse(sessionStorage.getItem(key)); } catch {}
  try { sessionStorage.setItem(key, JSON.stringify({ path: here, name: nav.dataset.page })); } catch {}
  if (!back && last?.name && last.path !== here && document.referrer) {
    const came = new URL(document.referrer);
    if (came.origin === location.origin && came.pathname + came.search === last.path) back = last;
  }
  if (!back || 'top' in nav.dataset) return;
  try { history.replaceState({ ...history.state, back }, ''); } catch {}

  let up = nav.querySelector('.up');
  if (!up) {
    const path = nav.querySelector('.trail');
    path.insertAdjacentHTML('beforeend', '<span class="crumb"><a class="up"></a></span><span class="crumb here" aria-current="page"></span>');
    path.querySelector('.here').textContent = nav.dataset.page;
    up = path.querySelector('.up');
    up.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15.700 4.300a1 1 0 0 1 0 1.400L9.400 12l6.300 6.300a1 1 0 0 1-1.400 1.400l-7-7a1 1 0 0 1 0-1.400l7-7a1 1 0 0 1 1.400 0Z"/></svg>';
    nav.classList.add('deep');
  }
  up.lastChild.nodeType === Node.TEXT_NODE ? (up.lastChild.textContent = back.name) : up.append(back.name);
  up.href = back.path;
  // Back, not a new visit: the list keeps its place, filters and scroll.
  up.addEventListener('click', (event) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button) return;
    event.preventDefault();
    history.back();
  });
}
