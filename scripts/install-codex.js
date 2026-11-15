import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { existsSync, copyFileSync, chmodSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const server = fileURLToPath(new URL('../src/server.js', import.meta.url));
const binary = fileURLToPath(new URL('../bin/eventkit-bridge', import.meta.url));
if (!existsSync(binary)) throw new Error('Run npm run build first.');
const config = path.join(process.env.CODEX_HOME || path.join(homedir(), '.codex'), 'config.toml');
if (existsSync(config)) {
  const backup = `${config}.apple-helper-backup-${Date.now()}`;
  copyFileSync(config, backup); chmodSync(backup, 0o600);
  console.log(`Existing configuration backed up to ${backup}`);
}
execFileSync('codex', ['mcp', 'add', 'apple-helper', '--', process.execPath, server], { stdio: 'inherit' });
const contents = readFileSync(config, 'utf8');
// Edit only this server's timeouts; retain other servers and permission policies.
const header = '[mcp_servers.apple-helper]\n';
const index = contents.indexOf(header);
if (index < 0) throw new Error('MCP was added, but its configuration table could not be located.');
const next = contents.indexOf('\n[', index + header.length);
const end = next < 0 ? contents.length : next;
const body = contents.slice(index + header.length, end).replace(/^(?:startup_timeout_sec|tool_timeout_sec)\s*=.*\n?/gm, '');
writeFileSync(config, contents.slice(0, index) + header + 'startup_timeout_sec = 15\ntool_timeout_sec = 150\n' + body + contents.slice(end));
console.log('Installed apple-helper. Restart this MCP server in Codex settings, or start a new chat after reloading the app.');
