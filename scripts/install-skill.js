import { copyFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('../skills/apple-planner/', import.meta.url));
const destination = path.join(process.env.CODEX_HOME || path.join(homedir(), '.codex'), 'skills', 'apple-planner');
const stamp = Date.now();
for (const relative of ['SKILL.md', 'agents/openai.yaml', 'references/advanced.md']) {
  const from = path.join(source, relative), to = path.join(destination, relative);
  mkdirSync(path.dirname(to), { recursive: true });
  if (existsSync(to)) {
    if (readFileSync(from).equals(readFileSync(to))) continue;
    copyFileSync(to, `${to}.backup-${stamp}`);
  }
  copyFileSync(from, to);
}
console.log(`Installed skill apple-planner at ${destination}`);
