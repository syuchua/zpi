// Compare pi's projection of the synthetic CLI fixture with the converted file.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { loadPiAi } from './pi-sdk.mjs';

const [source, converted] = process.argv.slice(2);
const sdkPath = process.env.ZPI_PI_SESSION_SDK || process.env.ZPI_PI_SDK;
if (!sdkPath || !source || !converted || process.argv.length !== 4) {
  throw new Error('Usage: ZPI_PI_SESSION_SDK=PACKAGE_DIR node scripts/test-pi-session-parity.mjs SOURCE CONVERTED');
}
const sdkRoot = resolve(sdkPath);
const manifestPath = join(sdkRoot, 'package.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
assert.equal(manifest.name, '@earendil-works/pi-coding-agent');
assert.ok(manifest.version === '1.5.2' || manifest.version === '1.6.0', `Unsupported pi SDK version ${manifest.version}`);
const { buildSessionContext, convertToLlm, parseSessionEntries } = await import(pathToFileURL(join(sdkRoot, 'dist/index.js')).href);
const { api: ai } = await loadPiAi(sdkRoot, manifest.version);
const { getSystemMessageText } = ai;

function textBlock(block) {
  assert.equal(block.type, 'text');
  return { text: block.text };
}

function projectMessage(message) {
  const { role, content } = message;
  switch (role) {
    case 'system':
      return { role, content: [{ text: getSystemMessageText(message) }] };
    case 'user': {
      const text = typeof content === 'string' ? content : content.map(block => textBlock(block).text).join('\n');
      return { role, content: [{ text }] };
    }
    case 'assistant':
      return {
        role,
        content: content.map(block => block.type === 'toolCall'
          ? { tool_call: { id: block.id, name: block.name, arguments: block.arguments } }
          : textBlock(block)),
      };
    case 'toolResult':
      return {
        role: 'tool_result',
        content: content.map(textBlock),
        tool_call_id: message.toolCallId,
        tool_name: message.toolName,
        is_error: message.isError,
        details: message.details,
      };
    default:
      throw new Error(`Unexpected fixture role ${role}`);
  }
}

const [header, ...entries] = parseSessionEntries(readFileSync(source, 'utf8'));
assert.equal(header.version, 3);
const context = buildSessionContext(entries);
const expectedMessages = convertToLlm(context.messages);
const [convertedHeader, ...records] = readFileSync(converted, 'utf8').trimEnd().split('\n').map(line => JSON.parse(line));
assert.equal(convertedHeader.format, 'zpi');
assert.equal(convertedHeader.cwd, header.cwd);
const actual = records.map(({ message }) => {
  const { role, content, tool_call_id, tool_name, is_error, details } = message;
  if (role === 'tool_result') return { role, content, tool_call_id, tool_name, is_error, details };
  return { role, content };
});
assert.deepEqual(actual, expectedMessages.map(projectMessage));
console.log(`Zpi import matches installed pi ${manifest.version} active-branch projection for the text, branch-summary and tool fixture`);
