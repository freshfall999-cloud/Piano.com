// Exercises WebMIDIPolyfill.js + start.html in Chromium with a fake native bridge.
// Run: node tests/polyfill.test.js   (needs the `playwright` package)
const path = require('path');
const fs = require('fs');
const assert = require('assert');
const { chromium } = require('playwright');

const web = path.join(__dirname, '..', 'PianoBrowser', 'Web');
const polyfill = fs.readFileSync(path.join(web, 'WebMIDIPolyfill.js'), 'utf8');

const fakeBridge = `
  delete Navigator.prototype.requestMIDIAccess;
  window.__sent = [];
  window.__deny = false;
  window.__devices = {
    inputs: [{ id: '11', name: 'Digital Piano', manufacturer: 'Acme' }],
    outputs: [{ id: '22', name: 'Digital Piano', manufacturer: 'Acme' }]
  };
  window.webkit = { messageHandlers: { pianoMIDI: { postMessage(m) {
    if (m.type === 'request') return window.__deny ? Promise.reject(new Error('denied')) : Promise.resolve(window.__devices);
    window.__sent.push(m);
    return Promise.resolve(null);
  } } } };
`;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.addInitScript(fakeBridge + polyfill);
  await page.goto('file://' + path.join(web, 'start.html'));
  await page.waitForFunction(() => document.querySelectorAll('#devices li .tag').length === 2);

  // Message splitting, running status, real-time interleave, sysex gating.
  const parsed = await page.evaluate(async () => {
    const access = await navigator.requestMIDIAccess();
    const input = access.inputs.get('11');
    const got = [];
    input.addEventListener('midimessage', e => got.push(Array.from(e.data)));
    const rx = window.__pianoBrowserMIDI.receive;
    rx('11', [0x90, 60, 100, 0x90, 64, 90]);        // two messages in one packet
    rx('11', [67, 80]);                              // running status
    rx('11', [0xB0, 64, 0xF8, 127]);                 // clock inside a message
    rx('11', [0xC0, 5, 0xE0, 0, 64]);
    rx('11', [0xF0, 1, 2]); rx('11', [3, 0xF7]);     // sysex, not enabled -> dropped
    rx('99', [0x90, 1, 1]);                          // unknown port
    const withSysex = await navigator.requestMIDIAccess({ sysex: true });
    rx('11', [0xF0, 1, 2]); rx('11', [3, 0xF7, 0x80, 60, 0]);
    return { got, same: withSysex === access, isEvent: got.length > 0 };
  });
  assert.deepStrictEqual(parsed.got, [
    [0x90, 60, 100], [0x90, 64, 90], [0x90, 67, 80], [0xF8], [0xB0, 64, 127],
    [0xC0, 5], [0xE0, 0, 64], [0xF0, 1, 2, 3, 0xF7], [0x80, 60, 0]
  ]);
  assert.ok(parsed.same);

  // Start page reacted: monitor shows the notes, C4 was released again.
  assert.match(await page.textContent("#log"), /note on\s+G4\s+vel 80/);
  assert.strictEqual(await page.locator('.on').count(), 2); // 64 and 67 still held

  // Output: send, validation, timestamps.
  const out = await page.evaluate(async () => {
    const access = await navigator.requestMIDIAccess();
    const o = access.outputs.get('22');
    window.__sent.length = 0;
    o.send([0x90, 60, 100]);
    o.send(new Uint8Array([0x80, 60, 0]), performance.now() + 500);
    const errs = [];
    for (const bad of [[], [60, 1], [0x90, 300, 1]]) { try { o.send(bad); errs.push('none'); } catch (e) { errs.push(e.name); } }
    return { sent: window.__sent, errs, connection: o.connection };
  });
  assert.deepStrictEqual(out.sent[0], { type: 'send', id: '22', data: [0x90, 60, 100], delay: 0 });
  assert.ok(out.sent[1].delay > 400 && out.sent[1].delay <= 500);
  assert.deepStrictEqual(out.errs, ['TypeError', 'TypeError', 'TypeError']);
  assert.strictEqual(out.connection, 'open');

  // Hot-plug: unplug, then plug back in; same port object, statechange fired.
  const plug = await page.evaluate(async () => {
    const access = await navigator.requestMIDIAccess();
    const input = access.inputs.get('11');
    const events = [];
    access.addEventListener('statechange', e => events.push(e.port.type + ':' + e.port.state));
    window.__pianoBrowserMIDI.devices({ inputs: [], outputs: [] });
    const sizeGone = access.inputs.size;
    window.__pianoBrowserMIDI.devices(window.__devices);
    const got = [];
    input.onmidimessage = e => got.push(Array.from(e.data));
    window.__pianoBrowserMIDI.receive('11', [0x90, 72, 1]);
    return { events, sizeGone, sameObject: access.inputs.get('11') === input, got };
  });
  assert.deepStrictEqual(plug.events, ['input:disconnected', 'output:disconnected', 'input:connected', 'output:connected']);
  assert.strictEqual(plug.sizeGone, 0);
  assert.ok(plug.sameObject);
  assert.deepStrictEqual(plug.got, [[0x90, 72, 1]]);
  await page.waitForFunction(() => document.querySelectorAll('#devices li .tag').length === 2);

  // On-screen key press goes to the output.
  await page.evaluate(() => { window.__sent.length = 0; });
  const box = await page.locator('.white').first().boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height - 10);
  await page.mouse.down(); await page.mouse.up();
  assert.deepStrictEqual((await page.evaluate(() => window.__sent)).map(m => m.data), [[0x90, 48, 90], [0x80, 48, 0]]);

  // Denied permission rejects with NotAllowedError.
  const denied = await page.evaluate(async () => {
    window.__deny = true;
    try { await navigator.requestMIDIAccess(); return 'resolved'; } catch (e) { return e.name; }
  });
  assert.strictEqual(denied, 'NotAllowedError');

  assert.deepStrictEqual(errors, []);
  await page.screenshot({ path: process.env.SHOT || '/dev/null', fullPage: true }).catch(() => {});
  await browser.close();
  console.log('polyfill tests passed');
})().catch(e => { console.error(e); process.exit(1); });
