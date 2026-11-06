// A small helper for building elements. Text always goes in as text, never as HTML.
export function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === 'class') node.className = value;
    else if (key === 'on') for (const [name, handler] of Object.entries(value)) node.addEventListener(name, handler);
    else if (key.startsWith('aria-') || key.startsWith('data-')) node.setAttribute(key, value);
    else node[key] = value;
  }
  node.append(...children.filter((child) => child != null));
  return node;
}
