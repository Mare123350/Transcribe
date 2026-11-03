import { WebSocket } from 'ws';

// Holds what's on the congregation screen and pushes it to every display window, so a window that
// reloads or reconnects shows the current passage straight away.
export class DisplayHub {
  constructor() {
    this.state = { blank: true };
    this.displays = new Set();
    this.operators = new Set();
  }

  add(socket, role) {
    const group = role === 'operator' ? this.operators : this.displays;
    group.add(socket);
    socket.isAlive = true;
    socket.on('pong', () => { socket.isAlive = true; });
    socket.on('error', () => socket.terminate());
    socket.on('close', () => {
      group.delete(socket);
      this.announceScreens();
    });
    send(socket, { type: 'state', state: this.state });
    this.announceScreens();
  }

  publish(state) {
    this.state = state;
    for (const socket of this.displays) send(socket, { type: 'state', state });
    return this.displays.size;
  }

  announceScreens() {
    for (const socket of this.operators) send(socket, { type: 'screens', count: this.displays.size });
  }

  // Drops connections that died without closing, such as a projector laptop that went to sleep.
  sweep() {
    for (const socket of [...this.displays, ...this.operators]) {
      if (!socket.isAlive) { socket.terminate(); continue; }
      socket.isAlive = false;
      socket.ping();
    }
  }
}

function send(socket, message) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}
