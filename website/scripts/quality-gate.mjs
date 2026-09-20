import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { chmod, copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== '--schema-contract')) {
  throw new Error('Usage: node scripts/quality-gate.mjs [--schema-contract <output.json>]');
}
if (Number(process.versions.node.split('.')[0]) !== 22) throw new Error('Website quality gate requires Node 22');
const npmCli = [process.env.npm_execpath,
  path.join(path.dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js'),
  path.join(path.dirname(process.execPath), 'npm'),
].filter(Boolean).filter((candidate) => existsSync(candidate)).map((candidate) => realpathSync(candidate))
  .find((candidate) => path.basename(candidate) === 'npm-cli.js');
if (!npmCli) throw new Error('Cannot locate npm CLI beside the selected Node runtime');
const temporaryRoot = await mkdtemp(path.join(os.tmpdir(), 'uten-website-quality-'));
await chmod(temporaryRoot, 0o700);
const database = path.join(temporaryRoot, 'validation.db');
const environment = { ...process.env,
  DATABASE_URL: `file:${database.replaceAll('\\', '/')}`,
  AUTH_SECRET: randomBytes(48).toString('base64url'),
  SITE_URL: 'https://www.ch-uten.com',
  UPLOADS_DIR: path.join(temporaryRoot, 'uploads'),
  NODE_ENV: 'test', NEXT_TELEMETRY_DISABLED: '1',
  ...(process.platform === 'win32' ? { RUST_LOG: 'info' } : {}),
};
const prismaCli = path.join(projectRoot, 'node_modules/prisma/build/index.js');
function run(command, parameters, env = environment) {
  process.stdout.write(`\n[website gate] ${path.basename(command)} ${parameters.join(' ')}\n`);
  const result = spawnSync(command, parameters, {
    cwd: projectRoot, env, stdio: 'inherit', windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Website gate failed: ${parameters.join(' ')} (exit ${result.status})`);
}
const npm = (parameters, env) => run(process.execPath, [realpathSync(npmCli), ...parameters], env);

try {
  // All following code, including Next configuration redirects, sees only this fresh DB.
  npm(['ci', '--ignore-scripts=false']);
  run(process.execPath, [prismaCli, 'generate', '--schema', 'prisma/schema.prisma']);
  run(process.execPath, [prismaCli, 'migrate', 'deploy', '--schema', 'prisma/schema.prisma']);
  await mkdir(environment.UPLOADS_DIR, { mode: 0o700 });
  npm(['run', 'lint']);
  run(process.execPath, ['node_modules/typescript/bin/tsc', '--noEmit']);
  npm(['run', 'test:all']);
  npm(['run', 'test:prisma-migrations']);
  // Installation mirrors need not implement npm's vulnerability API.
  npm(['audit', '--audit-level=low', '--registry=https://registry.npmjs.org']);
  // Do not let a future test that writes the validation DB seed production build output.
  const buildDatabase = path.join(temporaryRoot, 'empty-build.db');
  const buildEnvironment = { ...environment,
    DATABASE_URL: `file:${buildDatabase.replaceAll('\\', '/')}`,
    NODE_ENV: 'production', UPLOADS_DIR: '/var/lib/uten-website/runtime/uploads' };
  run(process.execPath, [prismaCli, 'migrate', 'deploy', '--schema', 'prisma/schema.prisma'], buildEnvironment);
  const contract = path.join(temporaryRoot, 'sqlite-schema-contract.json');
  run(process.platform === 'win32' ? 'python' : 'python3', [
    'deploy/paired_state.py', 'schema-contract', '--database', buildDatabase, '--output', contract,
  ]);
  // This is the existing production contract, not a new location or writable build fixture.
  // Next build resolves this setting but performs no uploads and never creates the path.
  npm(['run', 'build'], buildEnvironment);
  if (args.length) {
    const output = path.resolve(args[1]);
    await mkdir(path.dirname(output), { recursive: true });
    await copyFile(contract, output);
  }
  process.stdout.write('\nWEBSITE_QUALITY_GATE_OK\n');
} finally {
  const resolved = path.resolve(temporaryRoot);
  if (path.dirname(resolved) !== path.resolve(os.tmpdir()) || !path.basename(resolved).startsWith('uten-website-quality-')) {
    throw new Error(`Refusing unexpected quality-gate cleanup: ${resolved}`);
  }
  await rm(resolved, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}
