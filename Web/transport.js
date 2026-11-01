'use strict';

class InputSender {
  constructor(send, active, reportError) {
    this.send = send;
    this.active = active;
    this.reportError = reportError;
    this.queue = [];
    this.sending = false;
    this.generation = 0;
    this.encoder = new TextEncoder();
  }
  reset() {
    this.generation++;
    this.queue = [];
    this.sending = false;
  }
  enqueue(event) {
    if (!this.active()) return;
    if (event.type === 'move' && this.queue.at(-1)?.type === 'move') this.queue[this.queue.length - 1] = event;
    else if (this.queue.length < 80) this.queue.push(event);
    else {
      this.queue = [{type:'release'}];
      this.reportError(new Error('Input connection is too slow. Pending input was cleared; please try again.'));
    }
    this.pump();
  }
  takeBatch() {
    const events = [];
    while (this.queue.length && events.length < 64) {
      const candidate = [...events, this.queue[0]];
      if (this.encoder.encode(JSON.stringify({events:candidate})).length > 49152) {
        if (!events.length) throw new Error('Input exceeds the request size limit.');
        break;
      }
      events.push(this.queue.shift());
    }
    return {events};
  }
  async pump() {
    if (this.sending || !this.active() || !this.queue.length) return;
    this.sending = true;
    const generation = this.generation;
    try {
      while (this.active() && this.queue.length && generation === this.generation) await this.send(this.takeBatch());
    } catch (error) {
      if (generation === this.generation) {
        this.queue = [{type:'release'}];
        this.reportError(error);
      }
    } finally {
      if (generation === this.generation) this.sending = false;
    }
  }
}

class FramePlayer {
  constructor(image, reportError) {
    this.image = image;
    this.reportError = reportError;
    this.controller = null;
  }
  start() {
    this.stop();
    const controller = new AbortController();
    this.controller = controller;
    this.play(controller.signal);
  }
  stop() {
    this.controller?.abort();
    this.controller = null;
  }
  async play(signal) {
    let displayed = null;
    let revision = '';
    try {
      while (!signal.aborted) {
        let next = null;
        let interval = 33;
        const started = Date.now();
        try {
          const path = '/api/frame' + (revision ? '?after=' + encodeURIComponent(revision) : '');
          const response = await fetch(path, {cache:'no-store', signal});
          if (!response.ok) {
            const error = new Error(response.status === 401 ? 'Sign in to reconnect.' : 'Waiting for the Mac screen.');
            error.status = response.status;
            throw error;
          }
          if (response.status !== 204) {
            const frame = await response.blob();
            if (signal.aborted) break;
            next = URL.createObjectURL(frame);
            this.image.src = next;
            await this.image.decode();
            if (displayed) URL.revokeObjectURL(displayed);
            displayed = next;
            next = null;
            revision = response.headers.get('X-Frame-Serial') || '';
          }
          // One download/decode at a time: slow links cannot accumulate old frames.
        } catch (error) {
          if (next) URL.revokeObjectURL(next);
          if (signal.aborted) break;
          this.reportError(error);
          interval = 250;
        }
        const delay = Math.max(0, interval - (Date.now() - started));
        if (delay && !signal.aborted) await new Promise(resolve => setTimeout(resolve, delay));
      }
    } finally {
      if (displayed) URL.revokeObjectURL(displayed);
    }
  }
}
