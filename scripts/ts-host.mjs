#!/usr/bin/env node
/** Experimental explicit-path pi extension host. stdout is bounded JSONL only.
 * No discovery, package installation, or session/auth file access is performed.
 * The caller supplies a trusted installed pi SDK directory and extension paths.
 */
import { readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { AsyncLocalStorage } from 'node:async_hooks';
import { format } from 'node:util';
import { loadPiAi } from './pi-sdk.mjs';

const MAX_LINE = 1024 * 1024;
const MAX_DEPTH = 64;
const MAX_NODES = 100000;
const MAX_INPUT_TEXT = 256 * 1024;
const requests = new AsyncLocalStorage();
const output = process.stdout.write.bind(process.stdout);
// Ordinary extension logs must never corrupt protocol stdout. A trusted
// extension can still write fd 1 directly; that is a protocol violation.
for (const method of ['log', 'info', 'debug', 'warn', 'error']) {
  console[method] = (...args) => process.stderr.write(format(...args).slice(0, 8192) + '\n');
}
function encode(record) {
  const bytes = JSON.stringify(record) + '\n';
  if (Buffer.byteLength(bytes) > MAX_LINE) throw new Error('HostResponseTooLarge');
  // Bound the queue even for an extension that emits updates without yielding.
  if (process.stdout.writableLength + Buffer.byteLength(bytes) > 4 * MAX_LINE) {
    process.stderr.write('zpi TS host: OutputBackpressureExceeded\n');
    process.exit(1);
  }
  return bytes;
}
function send(record) { output(encode(record)); }
function sendThenExit(record) {
  const bytes = encode(record);
  output(bytes, () => process.exit(1));
}
function validate(value, depth = 0, state = { nodes: 0 }, seen = new Set()) {
  if (depth > MAX_DEPTH || ++state.nodes > MAX_NODES) throw new Error('HostValueTooComplex');
  if (value && typeof value === 'object') {
    if (seen.has(value)) throw new Error('HostValueCycle');
    seen.add(value);
    for (const child of Object.values(value)) validate(child, depth + 1, state, seen);
    seen.delete(value);
  }
}
function unsupported(name) { return () => { throw new Error(`UnsupportedHostAction: ${name}`); }; }
function unavailable(name) {
  return new Proxy(Object.create(null), { get(_target, key) {
    if (key === 'then' || key === 'toJSON') return undefined;
    return unsupported(`${name}.${String(key)}`);
  } });
}
let sdk;
let loader;
let validateToolArguments;
let sdkInfo;
let runtime;
let runner;
let cwd;
let closing = false;
let lifecycle = false;
const controllers = new Map();
let activeOperation;
let loaded = false;
const log = (...args) => process.stderr.write(format(...args).slice(0, 8192) + '\n');

function specs() {
  return runner.getAllRegisteredTools().map(({ definition: t }) => ({
    name: t.name, description: t.description, parameters: t.parameters,
  }));
}
function currentSignal() {
  return ['tool_exec', 'tool_call', 'tool_result'].includes(activeOperation?.op) ? activeOperation.controller.signal : undefined;
}
function checkRegistrations(extensions) {
  // Fail visibly instead of silently dropping requested semantics.
  const allowedEvents = new Set(['input', 'tool_call', 'tool_result', 'session_start', 'session_shutdown']);
  for (const ext of extensions) {
    for (const key of ['commands', 'flags', 'shortcuts', 'messageRenderers', 'entryRenderers']) {
      if (ext[key]?.size) throw new Error(`UnsupportedHostRegistration: ${key}`);
    }
    for (const event of ext.handlers.keys()) if (!allowedEvents.has(event)) throw new Error(`UnsupportedHostEvent: ${event}`);
    for (const { definition: t } of ext.tools.values()) {
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(t.name)) throw new Error('InvalidExtensionToolName');
      for (const key of ['prepareArguments', 'outputSchema', 'prepareLoadout', 'reachesTools', 'terminate']) {
        if (t[key] !== undefined) throw new Error(`UnsupportedToolCapability: ${key}`);
      }
      if (t.defaultActive === false || (t.exposure && t.exposure !== 'direct')) throw new Error('UnsupportedToolExposure');
      if (t.renderCall || t.renderResult || t.renderShell || t.promptSnippet || t.promptGuidelines?.length ||
          t.annotations || t.namespace || t.constrainedSampling || t.executionMode) throw new Error('UnsupportedToolMetadata');
    }
  }
  if (runtime.pendingProviderRegistrations.length || runtime.pendingNativeProviderRegistrations.length ||
      runtime.pendingVirtualModelRegistrations.length || runtime.mcpServers.list().length) {
    throw new Error('UnsupportedProviderOrMcpRegistration');
  }
}
async function load(payload) {
  if (loaded) throw new Error('HostAlreadyLoaded');
  if (!Array.isArray(payload.paths) || !payload.paths.length || payload.paths.length > 64) throw new Error('ExplicitExtensionPathsRequired');
  if (payload.paths.some(p => typeof p !== 'string')) throw new Error('InvalidExtensionPath');
  cwd = resolve(payload.cwd);
  runtime = sdk.createExtensionRuntime();
  const result = await loader.loadExtensions(payload.paths.map(p => resolve(cwd, p)), cwd, sdk.createEventBus(), runtime);
  if (result.errors.length) throw new Error(`ExtensionLoadFailed: ${result.errors.map(e => e.error).join('; ')}`);
  checkRegistrations(result.extensions);
  runner = new sdk.ExtensionRunner(result.extensions, runtime, cwd, unavailable('sessionManager'), unavailable('modelRegistry'));
  const names = [
    'sendMessage', 'sendUserMessage', 'appendEntry', 'setSessionName', 'getSessionName', 'setLabel',
    'setActiveTools', 'getSettings', 'setModel', 'setThinkingLevel', 'getCommands',
  ];
  const actions = Object.fromEntries(names.map(name => [name, unsupported(name)]));
  Object.assign(actions, {
    getActiveTools: () => specs().map(t => t.name), getAllTools: specs,
    getThinkingLevel: () => 'off', refreshTools: unsupported('dynamic tool registration'),
  });
  runner.bindCore(actions, {
    getModel: () => undefined, getScopedModels: () => [],
    isIdle: () => !['tool_exec', 'tool_call', 'tool_result'].includes(activeOperation?.op), isProjectTrusted: () => false,
    getSignal: currentSignal,
    abort: unsupported('abort: agent cancellation is not connected'),
    hasPendingMessages: () => false,
    shutdown: unsupported('shutdown'), compact: unsupported('compact'),
    getContextUsage: unsupported('getContextUsage'), getSystemPrompt: unsupported('getSystemPrompt'),
    getCallableTools: () => [], executeTool: unsupported('nested executeTool'),
  });
  // The real runner's print mode has hasUI=false and no-op UI methods.
  runner.setUIContext(undefined, 'print');
  runner.onError(error => {
    try {
      send({ type: 'extension_error', id: requests.getStore() ?? null,
        error: { extensionPath: error.extensionPath, event: error.event, message: String(error.error).slice(0, 8192) } });
    } catch (sendError) { log('extension error report failed:', sendError.message); }
  });
  loaded = true;
  lifecycle = true;
  await runner.emit({ type: 'session_start', reason: 'startup' });
  return { ...sdkInfo, tools: specs(), extensions: runner.getExtensionPaths(),
    capabilities: ['input', 'tool_call', 'tool_result', 'tool_exec', 'cancel', 'session_start', 'session_shutdown'],
    context: { mode: 'print', hasUI: false, projectTrusted: false, sessionManager: 'unsupported', modelRegistry: 'unsupported' } };
}
async function dispatch(request) {
  const p = request.payload ?? {};
  if (request.op === 'load') return load(p);
  if (!loaded) throw new Error('HostNotLoaded');
  if (request.op === 'input') {
    if (typeof p.text !== 'string' || Buffer.byteLength(p.text, 'utf8') > MAX_INPUT_TEXT) throw new Error('InvalidInput');
    return runner.emitInput(p.text, undefined, p.source ?? 'interactive');
  }
  if (request.op === 'tool_call') {
    const registered = runner.getToolDefinition(p.name);
    const schema = registered ?? { name: p.name, parameters: p.schema };
    if (!schema?.parameters) throw new Error('ToolSchemaUnavailable');
    const event = { type: 'tool_call', toolName: p.name, toolCallId: p.callId,
      input: validateToolArguments(schema, { id: p.callId, name: p.name, arguments: p.arguments }) };
    // Runner rejects throwing gates; preserving that failure prevents execution.
    const verdict = await runner.emitToolCall(event);
    if (verdict?.terminate) throw new Error('UnsupportedToolTermination');
    return { ...verdict, input: event.input };
  }
  if (request.op === 'tool_result') {
    const event = { type: 'tool_result', toolName: p.name,
      toolCallId: p.callId, input: p.arguments, content: p.content, details: p.details, isError: p.isError === true };
    const result = await runner.emitToolResult(event);
    return result ?? null;
  }
  if (request.op === 'tool_exec') {
    const tool = runner.getToolDefinition(p.name);
    if (!tool) throw new Error('UnknownExtensionTool');
    const call = { id: p.callId, name: p.name, arguments: p.arguments };
    const args = validateToolArguments(tool, call);
    const signal = currentSignal();
    const result = await tool.execute(p.callId, args, signal,
      partial => send({ type: 'tool_update', id: request.id, result: partial }),
      runner.createToolContext(p.callId, signal));
    signal?.throwIfAborted();
    if (result?.terminate) throw new Error('UnsupportedToolTermination');
    return result;
  }
  if (request.op === 'shutdown') {
    closing = true;
    if (lifecycle) { lifecycle = false; await runner.emit({ type: 'session_shutdown', reason: 'quit' }); }
    runner.invalidate();
    return { closed: true };
  }
  throw new Error('UnknownHostOperation');
}
async function handle(request) {
  if (!request || !Number.isSafeInteger(request.id) || request.id < 1 || typeof request.op !== 'string') throw new Error('InvalidHostRequest');
  if (request.op === 'cancel') {
    const controller = controllers.get(request.payload?.id);
    controller?.abort(new Error('CanceledByHost'));
    send({ id: request.id, ok: true, result: { canceled: !!controller } });
    return;
  }
  if (closing || activeOperation) { send({ id: request.id, ok: false, kind: 'rejected', error: closing ? 'HostClosing' : 'HostBusy' }); return; }
  const timeout = request.timeoutMs ?? 30000;
  if (!Number.isInteger(timeout) || timeout < 1 || timeout > 300000) {
    send({ id: request.id, ok: false, kind: 'rejected', error: 'InvalidHostTimeout' });
    return;
  }
  const controller = new AbortController();
  controllers.set(request.id, controller);
  activeOperation = { id: request.id, op: request.op, controller };
  // Uncooperative JS must not keep running after a timeout reply, because it
  // could still mutate shared extension state. Terminate this host on deadline.
  let replied = false;
  const timer = setTimeout(() => {
    controller.abort(new Error('HostDeadlineExceeded'));
    // Write one terminal frame, then exit only after stdout flushes. The
    // dispatcher may observe abort but must not send a second response.
    replied = true;
    closing = true;
    try { sendThenExit({ id: request.id, ok: false, kind: 'fatal', error: 'HostDeadlineExceeded' }); }
    catch { process.exit(1); }
  }, timeout);
  try {
    const result = await requests.run(request.id, () => dispatch(request));
    controller.signal.throwIfAborted();
    validate(result);
    if (!replied) send({ id: request.id, ok: true, result: result ?? null });
  } catch (error) {
    // Expected extension/tool errors are ordinary failed operations. Protocol
    // and transport fatality are separate records and invalidate the process.
    const message = String(error.message ?? error).slice(0, 8192);
    const toolError = request.op === 'tool_exec' && !['HostDeadlineExceeded', 'CanceledByHost', 'HostDisconnected'].includes(error.message);
    if (!replied) send({ id: request.id, ok: false, kind: toolError ? 'tool_error' : 'rejected', error: message });
  } finally {
    clearTimeout(timer); controllers.delete(request.id); activeOperation = undefined;
  }
  if (closing && !replied) process.exit(0);
}
async function main() {
  const [packagePath] = process.argv.slice(2);
  if (!packagePath) throw new Error('Usage: ts-host.mjs SDK_PACKAGE_DIRECTORY');
  const root = resolve(packagePath);
  const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  if (manifest.name !== '@earendil-works/pi-coding-agent' || !['1.5.2', '1.6.0'].includes(manifest.version)) throw new Error('UnsupportedPiSdkVersion');
  sdkInfo = { sdk: manifest.name, version: manifest.version, protocol: 'zpi-ts-host', protocolVersion: 1 };
  sdk = await import(pathToFileURL(join(root, 'dist/index.js')).href);
  // loadExtensions is exported from this internal entry but not the package's
  // public root; the exact package version is required for that dependency.
  loader = await import(pathToFileURL(join(root, 'dist/core/extensions/index.js')).href);
  const { api: ai } = await loadPiAi(root, manifest.version);
  if (typeof ai.validateToolArguments !== 'function') throw new Error('PiSdkToolValidationUnavailable');
  validateToolArguments = ai.validateToolArguments;
  let pending = Buffer.alloc(0);
  process.stdin.on('data', bytes => {
    try {
      pending = Buffer.concat([pending, bytes]);
      let newline;
      while ((newline = pending.indexOf(10)) !== -1) {
        if (newline > MAX_LINE) throw new Error('HostRequestTooLarge');
        const raw = pending.subarray(0, newline); pending = pending.subarray(newline + 1);
        const request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
        validate(request);
        void handle(request).catch(error => { console.error(error.message); process.exit(1); });
      }
      if (pending.length > MAX_LINE) throw new Error('HostRequestTooLarge');
    } catch (error) { console.error(error.message); process.exit(1); }
  });
  process.stdin.on('end', () => {
    for (const controller of controllers.values()) controller.abort(new Error('HostDisconnected'));
    // EOF is a process disconnect, not an implicit successful shutdown.
    process.exit(0);
  });
}
main().catch(error => { console.error(`zpi TS host: ${error.message}`); process.exit(1); });
