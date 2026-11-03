// The congregation window. It only ever shows what the server sends, and keeps showing it through
// network trouble until told otherwise.
import { createStage, fitStage, renderStage } from '/js/stage.js';

const frame = document.getElementById('frame');
const stage = createStage(frame);
fitStage(frame, stage);

const connection = document.getElementById('connection');
const fullscreenButton = document.getElementById('fullscreen');

function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen().catch(() => {});
}
fullscreenButton.addEventListener('click', toggleFullscreen);
document.addEventListener('keydown', (event) => {
  if (event.key === 'f' || event.key === 'F') toggleFullscreen();
});

let idleTimer;
function wake() {
  document.body.classList.remove('idle');
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => document.body.classList.add('idle'), 3000);
}
document.addEventListener('mousemove', wake);
wake();

let retry = 500;
function connect() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const socket = new WebSocket(`${protocol}//${location.host}/ws/display?role=display`);
  socket.addEventListener('open', () => {
    retry = 500;
    connection.textContent = 'Connected to operator';
  });
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (message.type === 'state') renderStage(stage, message.state);
  });
  socket.addEventListener('close', () => {
    connection.textContent = 'Reconnecting… the current passage stays on screen';
    wake();
    setTimeout(connect, retry);
    retry = Math.min(retry * 2, 5000);
  });
}
connect();
