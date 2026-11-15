import { mkdirSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
if (process.platform !== 'darwin') throw new Error('Apple Helper MCP requires macOS 14 or later.');
mkdirSync(path.join(root, 'bin'), { recursive: true });
const testing = process.argv.includes('--test');
const output = path.join(root, testing ? 'bin/eventkit-test-bridge' : 'bin/eventkit-bridge');
execFileSync('/usr/bin/xcrun', [
  'swiftc', '-swift-version', '5', '-parse-as-library', '-O',
  '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx14.0`,
  ...(testing ? ['-D', 'TESTING'] : []),
  ...readdirSync(path.join(root, 'native')).filter(f => f.endsWith('.swift')).sort().map(f => path.join(root, 'native', f)), '-o', output,
  '-framework', 'EventKit', '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT',
  '-Xlinker', '__info_plist', '-Xlinker', path.join(root, 'native/Info.plist'),
], { stdio: 'inherit' });
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--identifier', 'local.apple-helper.eventkit', output], { stdio: 'inherit' });
console.log(`Built ${output}`);
