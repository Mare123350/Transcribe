// Splits a passage into screens. `fits(page)` says whether a list of { verse, text, continued } fits
// on one screen; the browser measures with real layout, tests can use anything. Verses stay whole when
// they can. One too long for a whole screen gets split at a word boundary and marked `continued`.
export function paginate(verses, fits) {
  const pages = [];
  let page = [];
  const flush = () => {
    if (page.length) pages.push(page);
    page = [];
  };

  for (const verse of verses) {
    const piece = { verse: verse.verse, text: verse.text };
    if (fits([...page, piece])) {
      page.push(piece);
      continue;
    }
    if (page.length && fits([piece])) {
      flush();
      page.push(piece);
      continue;
    }

    flush();
    let words = verse.text.split(' ');
    let continued = false;
    while (words.length) {
      const pieceOf = (count) => ({ verse: verse.verse, text: words.slice(0, count).join(' '), ...(continued ? { continued } : {}) });
      let low = 1;
      let high = words.length;
      while (low < high) {
        const middle = Math.ceil((low + high) / 2);
        if (fits([pieceOf(middle)])) low = middle;
        else high = middle - 1;
      }
      page.push(pieceOf(low));
      words = words.slice(low);
      continued = true;
      if (words.length) flush();
    }
  }
  flush();
  return pages;
}
