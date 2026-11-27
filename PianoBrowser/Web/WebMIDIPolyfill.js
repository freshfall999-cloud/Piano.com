// Web MIDI API for WKWebView. Injected at document start into every frame.
// Native side: Browser.swift and Tab.swift (message handler "pianoMIDI") + MIDIManager.swift (CoreMIDI).
(function () {
  'use strict';

  // Keep Web Audio audible when the ring/silent switch is on (iOS 16.4+).
  try {
    if (window.top === window && navigator.audioSession && navigator.audioSession.type === 'auto') {
      navigator.audioSession.type = 'playback';
    }
  } catch (e) {}

  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pianoMIDI;
  if (!bridge || window.__pianoBrowserMIDI || typeof navigator.requestMIDIAccess === 'function') return;

  var access = null;
  var ports = { input: {}, output: {} }; // every port ever seen, by id (reused on reconnect)

  function post(message) {
    try {
      var p = bridge.postMessage(message);
      if (p && p.catch) p.catch(function () {});
    } catch (e) {}
  }

  function defineHandler(proto, type) {
    var key = '_on' + type;
    Object.defineProperty(proto, 'on' + type, {
      configurable: true,
      enumerable: true,
      get: function () { return this[key] || null; },
      set: function (fn) {
        if (this[key]) this.removeEventListener(type, this[key]);
        this[key] = typeof fn === 'function' ? fn : null;
        if (this[key]) this.addEventListener(type, this[key]);
      }
    });
  }

  class MIDIMessageEvent extends Event {
    constructor(type, init) {
      super(type, init);
      this.data = init && init.data ? init.data : null;
    }
  }

  class MIDIConnectionEvent extends Event {
    constructor(type, init) {
      super(type, init);
      this.port = init && init.port ? init.port : null;
    }
  }

  function fireState(port) {
    port.dispatchEvent(new MIDIConnectionEvent('statechange', { port: port }));
    if (access) access.dispatchEvent(new MIDIConnectionEvent('statechange', { port: port }));
  }

  class MIDIPort extends EventTarget {
    constructor(info, type) {
      super();
      this.id = info.id;
      this.name = info.name || '';
      this.manufacturer = info.manufacturer || '';
      this.version = '';
      this.type = type;
      this.state = 'connected';
      this.connection = 'closed';
    }
    open() {
      var self = this;
      var target = this.state === 'connected' ? 'open' : 'pending';
      if (this.connection !== target) {
        this.connection = target;
        Promise.resolve().then(function () { fireState(self); });
      }
      return Promise.resolve(this);
    }
    close() {
      var self = this;
      if (this.connection !== 'closed') {
        this.connection = 'closed';
        Promise.resolve().then(function () { fireState(self); });
      }
      return Promise.resolve(this);
    }
  }
  defineHandler(MIDIPort.prototype, 'statechange');

  class MIDIInput extends MIDIPort {
    constructor(info) {
      super(info, 'input');
      this._sysex = null;
      this._running = 0;
    }
    addEventListener(type) {
      EventTarget.prototype.addEventListener.apply(this, arguments);
      if (type === 'midimessage') this.open(); // listening opens the port, as in Chrome
    }
  }
  defineHandler(MIDIInput.prototype, 'midimessage');

  class MIDIOutput extends MIDIPort {
    constructor(info) {
      super(info, 'output');
    }
    send(data, timestamp) {
      var bytes = Array.from(data || []);
      if (!bytes.length) throw new TypeError('MIDI message is empty.');
      for (var i = 0; i < bytes.length; i++) {
        var b = bytes[i];
        if (typeof b !== 'number' || b < 0 || b > 255 || Math.floor(b) !== b) {
          throw new TypeError('Invalid MIDI byte at index ' + i + '.');
        }
      }
      if (bytes[0] < 0x80) throw new TypeError('MIDI message must start with a status byte.');
      if (bytes.indexOf(0xF0) !== -1 && !(access && access.sysexEnabled)) {
        throw new DOMException('System exclusive messages need requestMIDIAccess({ sysex: true }).', 'InvalidAccessError');
      }
      if (this.state !== 'connected') throw new DOMException('MIDI port is disconnected.', 'InvalidStateError');
      if (this.connection !== 'open') this.open();
      var delay = timestamp ? Math.max(0, timestamp - performance.now()) : 0;
      post({ type: 'send', id: this.id, data: bytes, delay: delay });
    }
    clear() {
      post({ type: 'clear', id: this.id });
    }
  }

  class MIDIAccess extends EventTarget {
    constructor() {
      super();
      this.inputs = new Map();
      this.outputs = new Map();
      this.sysexEnabled = false;
    }
  }
  defineHandler(MIDIAccess.prototype, 'statechange');

  function syncPorts(type, list, Port, map, announce) {
    var seen = {};
    (list || []).forEach(function (info) {
      seen[info.id] = true;
      var port = ports[type][info.id];
      if (!port) port = ports[type][info.id] = new Port(info);
      port.name = info.name || port.name;
      port.manufacturer = info.manufacturer || port.manufacturer;
      if (map.get(info.id) === port) return;
      port.state = 'connected';
      if (port.connection === 'pending') port.connection = 'open';
      map.set(info.id, port);
      if (announce) fireState(port);
    });
    Array.from(map.keys()).forEach(function (id) {
      if (seen[id]) return;
      var port = map.get(id);
      map.delete(id);
      port.state = 'disconnected';
      if (port.connection === 'open') port.connection = 'pending';
      if (announce) fireState(port);
    });
  }

  function applyDevices(devices, announce) {
    if (!access || !devices) return;
    syncPorts('input', devices.inputs, MIDIInput, access.inputs, announce);
    syncPorts('output', devices.outputs, MIDIOutput, access.outputs, announce);
  }

  function messageLength(status) {
    if (status < 0xC0) return 3;
    if (status < 0xE0) return 2;
    if (status < 0xF0) return 3;
    if (status === 0xF1 || status === 0xF3) return 2;
    if (status === 0xF2) return 3;
    return 1;
  }

  function emit(port, bytes) {
    port.dispatchEvent(new MIDIMessageEvent('midimessage', { data: new Uint8Array(bytes) }));
  }

  // Splits a raw CoreMIDI packet (possibly several messages, or a piece of a
  // long sysex) into one event per MIDI message.
  function parse(port, bytes) {
    var i = 0;
    var n = bytes.length;
    while (i < n) {
      var b = bytes[i];
      if (b >= 0xF8) { emit(port, [b]); i++; continue; } // real-time, may interleave anywhere
      if (port._sysex) {
        if (b < 0x80) { port._sysex.push(b); i++; continue; }
        if (b === 0xF7) {
          port._sysex.push(b);
          if (access && access.sysexEnabled) emit(port, port._sysex);
          port._sysex = null;
          i++;
          continue;
        }
        port._sysex = null; // interrupted by another status byte
      }
      if (b === 0xF0) { port._sysex = [b]; port._running = 0; i++; continue; }
      var status = b;
      var start = i + 1;
      if (b < 0x80) { // data byte with no status: running status
        if (!port._running) { i++; continue; }
        status = port._running;
        start = i;
      }
      var message = [status];
      var need = messageLength(status);
      var j = start;
      while (message.length < need && j < n) {
        if (bytes[j] >= 0xF8) emit(port, [bytes[j]]);
        else if (bytes[j] >= 0x80) break; // new status cuts this message short
        else message.push(bytes[j]);
        j++;
      }
      if (message.length === need) {
        port._running = status < 0xF0 ? status : 0;
        emit(port, message);
      }
      i = j;
    }
  }

  Object.defineProperty(window, '__pianoBrowserMIDI', {
    value: {
      receive: function (id, bytes) {
        var port = access && access.inputs.get(id);
        if (port) parse(port, bytes);
      },
      devices: function (devices) { applyDevices(devices, true); }
    }
  });

  function requestMIDIAccess(options) {
    var sysex = !!(options && options.sysex);
    return bridge.postMessage({ type: 'request', sysex: sysex }).then(function (devices) {
      var first = !access;
      if (first) access = new MIDIAccess();
      if (sysex) access.sysexEnabled = true;
      applyDevices(devices, !first);
      return access;
    }, function () {
      throw new DOMException('MIDI access was denied.', 'NotAllowedError');
    });
  }

  Object.defineProperty(Navigator.prototype, 'requestMIDIAccess', {
    configurable: true,
    enumerable: true,
    writable: true,
    value: requestMIDIAccess
  });

  window.MIDIAccess = MIDIAccess;
  window.MIDIPort = MIDIPort;
  window.MIDIInput = MIDIInput;
  window.MIDIOutput = MIDIOutput;
  window.MIDIMessageEvent = MIDIMessageEvent;
  window.MIDIConnectionEvent = MIDIConnectionEvent;

  // Sites that check navigator.permissions before asking should not see an error.
  try {
    if (navigator.permissions && navigator.permissions.query) {
      var originalQuery = navigator.permissions.query.bind(navigator.permissions);
      navigator.permissions.query = function (descriptor) {
        if (descriptor && descriptor.name === 'midi') {
          var status = new EventTarget();
          status.name = 'midi';
          status.state = 'prompt';
          status.onchange = null;
          return Promise.resolve(status);
        }
        return originalQuery(descriptor);
      };
    }
  } catch (e) {}
})();
