import { readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export async function loadPiAi(sdkRoot, sdkVersion) {
  const sdkManifest = join(realpathSync(sdkRoot), 'package.json');
  const packageName = '@earendil-works/pi-ai';
  // pi-ai has an ESM-only package entry. Search from the SDK and load the
  // first package found, including when npm has hoisted the dependency.
  const lookupPaths = createRequire(sdkManifest).resolve.paths(packageName);
  for (const directory of lookupPaths ?? []) {
    const packageRoot = join(directory, packageName);
    let manifestText;
    try {
      manifestText = readFileSync(join(packageRoot, 'package.json'), 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') continue;
      throw error;
    }
    const manifest = JSON.parse(manifestText);
    if (manifest.name !== packageName || manifest.version !== sdkVersion) {
      throw new Error('PiSdkDependencyVersionDrift');
    }
    const api = await import(pathToFileURL(join(packageRoot, manifest.exports['.'].import)).href);
    return { api, version: manifest.version };
  }
  throw new Error('PiSdkDependencyNotFound');
}
