#!/usr/bin/env node
// Read-only probe of the locally installed, version-pinned pi SDK package.
// Never loads credentials, performs network IO, or scans extension locations.
import { readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { loadPiAi } from './pi-sdk.mjs';
const root = resolve(process.argv[2] ?? process.env.ZPI_PI_SDK ?? '');
if (!process.argv[2] && !process.env.ZPI_PI_SDK) throw new Error('Provide explicit SDK package directory');
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
if (manifest.name !== '@earendil-works/pi-coding-agent' || !['1.5.2', '1.6.0'].includes(manifest.version)) throw new Error('UnsupportedPiSdkVersion');
const sdk = await import(pathToFileURL(join(root, 'dist/index.js')).href);
const loader = await import(pathToFileURL(join(root, 'dist/core/extensions/index.js')).href);
const { api: ai, version: piAiVersion } = await loadPiAi(root, manifest.version);
for (const key of ['createExtensionRuntime', 'ExtensionRunner', 'createEventBus']) if (typeof sdk[key] !== 'function') throw new Error(`MissingSdkExport:${key}`);
if (typeof loader.loadExtensions !== 'function' || typeof ai.validateToolArguments !== 'function') throw new Error('MissingExtensionInternals');
process.stdout.write(JSON.stringify({ package: manifest.name, version: manifest.version, piAiVersion,
  loaderExportedInternally: true, sdkExports: ['createExtensionRuntime', 'ExtensionRunner', 'createEventBus'],
  validator: true, dependencies: ['jiti', 'typebox'] }) + '\n');
