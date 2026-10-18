import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const source = await readFile(path.join(root, 'prisma/schema.prisma'), 'utf8');
if (!source.includes('provider = "sqlite"')) throw new Error('SQLite compatibility schema was not found');
const postgres = '// Generated from ../schema.prisma by scripts/generate-clients.mjs. Do not edit independently.\n'
  + source.replace('provider = "prisma-client-js"', 'provider = "prisma-client-js"\n  output = "../../generated/postgresql"')
    .replace('provider = "sqlite"', 'provider = "postgresql"');
await mkdir(path.join(root, 'prisma/postgresql'), { recursive: true });
await writeFile(path.join(root, 'prisma/postgresql/schema.prisma'), postgres);
for (const schema of ['prisma/schema.prisma', 'prisma/postgresql/schema.prisma']) {
  const result = spawnSync(process.execPath, [path.join(root, 'node_modules/prisma/build/index.js'), 'generate', '--schema', schema], {
    cwd: root, stdio: 'inherit', windowsHide: true,
    env: { ...process.env, DATABASE_URL: schema.includes('/postgresql/') ? 'postgresql://unused:unused@127.0.0.1:5432/unused' : 'file:./unused.db' },
  });
  if (result.status !== 0) process.exit(result.status || 1);
}
