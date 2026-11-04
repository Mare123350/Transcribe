// Renders the congregation screen. Used by the display window, the operator's preview, and the hidden
// copy that measures pagination, so all three always agree.
import { paginate } from '/shared/pagination.js';

export const STAGE_WIDTH = 1920;
export const STAGE_HEIGHT = 1080;

export function createStage(container) {
  const stage = document.createElement('div');
  stage.className = 'stage';
  stage.dataset.blank = 'true';
  stage.innerHTML = `
    <div class="stage-reference"></div>
    <div class="stage-body"><div class="stage-text"></div></div>
    <div class="stage-lyrics"></div>
    <div class="stage-foot">
      <div class="stage-translation"><span class="stage-translation-name"></span><span class="stage-copyright"></span></div>
      <div class="stage-page"></div>
    </div>
    <div class="stage-demo" hidden>DEMO</div>`;
  container.append(stage);
  return stage;
}

// Keeps the fixed-size stage scaled and centred inside its container.
export function fitStage(container, stage) {
  const fit = () => {
    const scale = Math.min(container.clientWidth / STAGE_WIDTH, container.clientHeight / STAGE_HEIGHT);
    const left = (container.clientWidth - STAGE_WIDTH * scale) / 2;
    const top = (container.clientHeight - STAGE_HEIGHT * scale) / 2;
    stage.style.transform = `translate(${left}px, ${top}px) scale(${scale})`;
  };
  new ResizeObserver(fit).observe(container);
  fit();
}

function fillText(textElement, verses) {
  textElement.replaceChildren();
  const numbered = verses.length > 1 || verses.some((v) => v.numbered);
  verses.forEach((verse, index) => {
    if (index > 0) textElement.append(' ');
    if (numbered && !verse.continued) {
      const number = document.createElement('sup');
      number.textContent = verse.verse;
      textElement.append(number);
    }
    textElement.append(verse.text);
  });
}

export function renderStage(stage, state) {
  const blank = !state || state.blank;
  stage.dataset.blank = String(blank);
  stage.dataset.theme = state?.theme ?? 'black';
  if (state?.fontPx) stage.style.setProperty('--scripture-size', `${state.fontPx}px`);
  stage.querySelector('.stage-demo').hidden = !state?.demo || blank;
  stage.dataset.kind = state?.kind === 'lyrics' && !blank ? 'lyrics' : 'passage';
  if (blank) return;
  if (state.kind === 'lyrics') {
    renderLyrics(stage, state);
    return;
  }

  const pages = state.pages ?? [];
  const page = Math.min(state.page ?? 0, Math.max(pages.length - 1, 0));
  stage.querySelector('.stage-reference').textContent = state.reference;
  fillText(stage.querySelector('.stage-text'), pages[page] ?? []);
  stage.querySelector('.stage-translation-name').textContent = `${state.translation.name} (${state.translation.abbreviation})`;
  stage.querySelector('.stage-copyright').textContent = state.copyright ?? '';
  stage.querySelector('.stage-page').textContent = pages.length > 1 ? `${page + 1} / ${pages.length}` : '';
}

function renderLyrics(stage, state) {
  const box = stage.querySelector('.stage-lyrics');
  const signature = JSON.stringify(state.lines);
  stage.dataset.highlight = String(state.highlight !== false);
  stage.querySelector('.stage-translation-name').textContent = state.credit ?? '';
  stage.querySelector('.stage-copyright').textContent = '';
  stage.querySelector('.stage-page').textContent = '';
  if (box.dataset.signature === signature) return;
  box.dataset.signature = signature;

  box.replaceChildren(...state.lines.map((line) => {
    const element = document.createElement('p');
    element.className = line.current ? 'lyric-line lyric-current' : 'lyric-line';
    element.textContent = line.text;
    return element;
  }));

  // Long lines shrink to fit rather than running off the screen.
  let size = (state.fontPx ?? 68) * 1.25;
  box.style.setProperty('--lyric-size', `${size}px`);
  while (box.scrollHeight > box.clientHeight && size > 28) {
    size *= 0.94;
    box.style.setProperty('--lyric-size', `${size}px`);
  }
  if (!globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
    box.animate?.([{ opacity: 0.15 }, { opacity: 1 }], { duration: 220, easing: 'ease-out' });
  }
}

// Splits a passage to fit at the given font size, using a hidden stage for real text measurement.
export function createPaginator() {
  const holder = document.createElement('div');
  holder.className = 'stage-measure';
  document.body.append(holder);
  const stage = createStage(holder);
  stage.dataset.blank = 'false';
  const body = stage.querySelector('.stage-body');
  const text = stage.querySelector('.stage-text');

  return ({ passage, reference, fontPx }) => {
    stage.style.setProperty('--scripture-size', `${fontPx}px`);
    stage.querySelector('.stage-reference').textContent = reference;
    stage.querySelector('.stage-translation-name').textContent = `${passage.translation.name} (${passage.translation.abbreviation})`;
    stage.querySelector('.stage-copyright').textContent = passage.copyright ?? '';
    stage.querySelector('.stage-page').textContent = '1 / 2';
    const numbered = passage.verses.length > 1;
    const fits = (page) => {
      fillText(text, page.map((verse) => ({ ...verse, numbered })));
      return text.offsetHeight <= body.clientHeight;
    };
    return paginate(passage.verses, fits).map((page) => page.map((verse) => ({ ...verse, numbered })));
  };
}
