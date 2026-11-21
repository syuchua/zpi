// Zpi-authored compatibility fixture: real pi SDK imports, hooks and cancellation.
import { Type } from '@earendil-works/pi-ai';
import { defineTool, type ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { setTimeout as delay } from 'node:timers/promises';

export default function (pi: ExtensionAPI) {
  pi.on('input', async (event, ctx) => {
    if (ctx.mode !== 'print' || ctx.hasUI || ctx.isProjectTrusted()) throw new Error('IncorrectHostContext');
    if (event.text === 'throw-input') throw new Error('fixture input failure');
    if (event.text === 'handled') return { action: 'handled' };
    if (event.text.startsWith('prefix ')) return { action: 'transform', text: `transformed ${event.text.slice(7)}` };
  });
  pi.on('tool_call', async event => {
    if (event.toolName === 'write' && event.input.path === 'throw-gate.txt') throw new Error('fixture gate failure');
    if (event.toolName === 'write' && event.input.path === 'denied.txt') return { block: true, reason: 'fixture denied' };
    if (event.toolName === 'write' && event.input.path === 'mutated.txt') event.input.content = 'changed by extension';
    if (event.toolName === 'denied') return { block: true, reason: 'fixture denied' };
    if (event.toolName === 'throw-gate') throw new Error('fixture gate failure');
    if (event.toolName === 'mutate') event.input.value = 'changed';
  });
  pi.on('tool_result', async event => {
    if (event.toolName === 'hello') return { details: { greeted: 'Zig', transformed: true } };
    if (event.toolName === 'write' && event.input.path === 'mutated.txt') throw new Error('fixture result handler failure');
  });
  pi.registerTool(defineTool({
    name: 'throw_fixture', label: 'Throw', description: 'Tool failure fixture',
    parameters: Type.Object({}),
    async execute() { throw new Error('fixture tool failure'); },
  }));
  pi.registerTool(defineTool({
    name: 'wait_fixture', label: 'Wait', description: 'Cancellable fixture',
    parameters: Type.Object({}),
    async execute(id, _params, signal, onUpdate, ctx) {
      if (signal !== ctx.signal || !id || typeof ctx.executeTool !== 'function') throw new Error('IncorrectToolContext');
      console.log('fixture log stays off stdout');
      onUpdate?.({ content: [{ type: 'text', text: 'waiting' }], details: {} });
      await delay(30000, undefined, { signal });
      return { content: [{ type: 'text', text: 'finished' }], details: {} };
    },
  }));
}
