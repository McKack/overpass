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
