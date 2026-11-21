// Feasibility probe, not a production compatibility host.
// Node >=22.19 supports type stripping. The chosen upstream examples have no
// runtime imports. This proves only factory/callback execution with API stubs.
import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const examples = path.resolve(process.argv[2] ?? '.reference/pi/packages/coding-agent/examples/extensions');
const results = [];

async function load(name) {
  const events = new Map();
  const notifications = [];
  const statuses = new Map();
  const api = {
    on(event, callback) {
      const callbacks = events.get(event) ?? [];
      callbacks.push(callback);
      events.set(event, callbacks);
      return () => callbacks.splice(callbacks.indexOf(callback), 1);
    },
  };
  const ctx = {
    hasUI: true,
    ui: {
      notify: (text, level) => notifications.push({ text, level }),
      setStatus: (key, text) => statuses.set(key, text),
      confirm: async () => false,
      select: async () => undefined,
    },
    sessionManager: { getEntries: () => [] },
  };
  const mod = await import(pathToFileURL(path.join(examples, name)).href);
  await mod.default(api);
  return { events, notifications, statuses, ctx };
}

const input = await load('input-transform.ts');
const transform = input.events.get('input')[0];
assert.deepEqual(await transform({ source: 'interactive', text: '?quick explain Zig' }, input.ctx), {
  action: 'transform', text: 'Respond briefly in 1-2 sentences: explain Zig',
});
assert.deepEqual(await transform({ source: 'interactive', text: 'ping' }, input.ctx), { action: 'handled' });
assert.equal(input.notifications.at(-1).text, 'pong');
assert.deepEqual(await transform({ source: 'extension', text: 'ping' }, input.ctx), { action: 'continue' });
results.push({ example: 'input-transform.ts', checks: ['transform', 'handled notification', 'extension source bypass'] });

const confirm = await load('confirm-destructive.ts');
assert.deepEqual(await confirm.events.get('session_before_switch')[0]({ reason: 'new' }, confirm.ctx), { cancel: true });
assert.deepEqual(await confirm.events.get('session_before_fork')[0]({ entryId: '12345678' }, confirm.ctx), { cancel: true });
assert.equal(await confirm.events.get('session_before_switch')[0]({ reason: 'new' }, { ...confirm.ctx, hasUI: false }), undefined);
results.push({ example: 'confirm-destructive.ts', checks: ['switch veto', 'fork veto', 'headless branch'] });

const status = await load('model-status.ts');
const originalLog = console.log;
try {
  console.log = () => {}; // Upstream example logs model changes; keep probe stdout JSON.
  await status.events.get('model_select')[0]({ model: { provider: 'fixture', id: 'demo' }, source: 'restore' }, status.ctx);
} finally {
  console.log = originalLog;
}
assert.equal(status.statuses.get('model'), '🤖 demo');
assert.equal(status.notifications.length, 0);
results.push({ example: 'model-status.ts', checks: ['status callback', 'restore suppresses notification'] });

console.log(JSON.stringify({
  node: process.version,
  passed: results,
  limitations: [
    'Type-only imports are erased; runtime imports/SDK packages were not exercised.',
    'API and UI are test stubs; no Zig IPC, real TUI, providers, tool dispatch or session mutation.',
    'No extension compatibility or sandboxing claim follows from this probe.',
  ],
}, null, 2));
