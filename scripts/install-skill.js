import { copyFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const skillsRoot = fileURLToPath(new URL('../skills/', import.meta.url));
const destinationRoot = path.join(process.env.CODEX_HOME || path.join(homedir(), '.codex'), 'skills');
const stamp = Date.now();
for (const [name, files] of Object.entries({
  'apple-planner': ['SKILL.md', 'agents/openai.yaml', 'references/advanced.md', 'references/extensions.md'],
  'apple-notes': ['SKILL.md', 'agents/openai.yaml'],
})) {
  const source = path.join(skillsRoot, name), destination = path.join(destinationRoot, name);
  for (const relative of files) {
    const from = path.join(source, relative), to = path.join(destination, relative);
    mkdirSync(path.dirname(to), { recursive: true });
    if (existsSync(to)) {
      if (readFileSync(from).equals(readFileSync(to))) continue;
      copyFileSync(to, `${to}.backup-${stamp}`);
    }
    copyFileSync(from, to);
  }
  console.log(`Installed skill ${name} at ${destination}`);
}
