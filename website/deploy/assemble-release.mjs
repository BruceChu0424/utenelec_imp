import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  readdir,
  rm,
  stat,
} from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const deployDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.dirname(deployDirectory);
const standaloneRoot = path.join(projectRoot, '.next', 'standalone');
const staticRoot = path.join(projectRoot, '.next', 'static');
const publicRoot = path.join(projectRoot, 'public');
const prismaSchema = path.join(projectRoot, 'prisma', 'schema.prisma');
const prismaMigrations = path.join(projectRoot, 'prisma', 'migrations');
const sqliteSchemaContract = process.env.SQLITE_SCHEMA_CONTRACT_PATH
  ? path.resolve(process.env.SQLITE_SCHEMA_CONTRACT_PATH)
  : '';
const prismaRuntimePackages = [
  'prisma',
  '@prisma/debug',
  '@prisma/engines',
  '@prisma/engines-version',
  '@prisma/fetch-engine',
  '@prisma/get-platform',
];

const targetArgument = process.argv[2];
if (!targetArgument) {
  throw new Error('Usage: npm run deploy:assemble -- <new-empty-release-directory>');
}

const targetRoot = path.resolve(process.cwd(), targetArgument);
const targetParent = path.dirname(targetRoot);
const filesystemRoot = path.parse(targetRoot).root;

if (targetRoot === filesystemRoot || targetRoot === projectRoot || targetRoot === standaloneRoot) {
  throw new Error(`Refusing unsafe release target: ${targetRoot}`);
}

function isSameOrDescendant(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === '' || (
    relative !== '..'
    && !relative.startsWith(`..${path.sep}`)
    && !path.isAbsolute(relative)
  );
}

for (const sourceRoot of [standaloneRoot, staticRoot, publicRoot]) {
  if (isSameOrDescendant(targetRoot, sourceRoot) || isSameOrDescendant(sourceRoot, targetRoot)) {
    throw new Error(`Release target must not overlap a release source: ${targetRoot}`);
  }
}

await stat(path.join(standaloneRoot, 'server.js'));
await stat(staticRoot);
await stat(publicRoot);
await stat(prismaSchema);
await stat(prismaMigrations);
if (!sqliteSchemaContract) {
  throw new Error('SQLITE_SCHEMA_CONTRACT_PATH must identify the fresh migrated database contract');
}
await stat(sqliteSchemaContract);
for (const packageName of prismaRuntimePackages) {
  await stat(path.join(projectRoot, 'node_modules', ...packageName.split('/')));
}
const parentInfo = await lstat(targetParent);
if (!parentInfo.isDirectory()) throw new Error(`Release parent is not a directory: ${targetParent}`);
if (parentInfo.isSymbolicLink()) throw new Error(`Release parent must not be a symbolic link: ${targetParent}`);

try {
  await lstat(targetRoot);
  throw new Error(`Release target already exists; refusing to overwrite: ${targetRoot}`);
} catch (error) {
  if (error?.code !== 'ENOENT') throw error;
}

function isDatabaseFile(relativePath) {
  return /(?:^|[/\\])[^/\\]+\.(?:db|sqlite|sqlite3)(?:-(?:journal|wal|shm))?$/iu.test(relativePath);
}

function isSecretFile(relativePath) {
  const basename = path.basename(relativePath).toLowerCase();
  if (basename === '.env' || basename.startsWith('.env.')) return true;
  if (['.npmrc', '.pypirc', '.yarnrc', 'credentials.json', 'service-account.json'].includes(basename)) {
    return true;
  }
  return /\.(?:jks|key|keystore|p12|pfx|pem)$/iu.test(basename);
}

async function copyTree(sourceRoot, destinationRoot, shouldSkip) {
  async function visit(source, destination, relativePath) {
    const sourceInfo = await lstat(source);
    if (sourceInfo.isSymbolicLink()) {
      throw new Error(`Symbolic links are not allowed in release sources: ${source}`);
    }
    if (shouldSkip(relativePath, sourceInfo)) return;

    if (sourceInfo.isDirectory()) {
      await mkdir(destination, { recursive: true, mode: sourceInfo.mode });
      const entries = await readdir(source, { withFileTypes: true });
      for (const entry of entries) {
        const childRelative = relativePath
          ? path.join(relativePath, entry.name)
          : entry.name;
        await visit(
          path.join(source, entry.name),
          path.join(destination, entry.name),
          childRelative,
        );
      }
      return;
    }

    if (!sourceInfo.isFile()) {
      throw new Error(`Unsupported release source entry: ${source}`);
    }
    await copyFile(source, destination);
    await chmod(destination, sourceInfo.mode);
  }

  await visit(sourceRoot, destinationRoot, '');
}

async function assertCleanRelease(directory) {
  async function visit(current, relativePath) {
    const info = await lstat(current);
    if (info.isSymbolicLink()) throw new Error(`Release contains a symbolic link: ${relativePath}`);
    if (isDatabaseFile(relativePath)) throw new Error(`Release contains a database file: ${relativePath}`);
    if (isSecretFile(relativePath)) throw new Error(`Release contains a secret-like file: ${relativePath}`);
    if (/^public[/\\]uploads(?:[/\\]|$)/iu.test(relativePath)) {
      throw new Error(`Release contains runtime media: ${relativePath}`);
    }
    if (!info.isDirectory()) return;
    for (const entry of await readdir(current)) {
      const childRelative = relativePath ? path.join(relativePath, entry) : entry;
      await visit(path.join(current, entry), childRelative);
    }
  }

  await visit(directory, '');
}

let targetCreated = false;
try {
  // Claim the destination atomically before copying. This prevents a
  // check-then-create race from turning cleanup into removal of someone
  // else's path.
  await mkdir(targetRoot, { recursive: false, mode: 0o750 });
  targetCreated = true;
  await copyTree(standaloneRoot, targetRoot, (relativePath) => {
    if (/^public(?:[/\\]|$)/iu.test(relativePath)) return true;
    return isDatabaseFile(relativePath) || isSecretFile(relativePath);
  });
  await copyTree(staticRoot, path.join(targetRoot, '.next', 'static'), () => false);
  await copyTree(publicRoot, path.join(targetRoot, 'public'), (relativePath) => {
    if (/^uploads(?:[/\\]|$)/iu.test(relativePath)) return true;
    return isDatabaseFile(relativePath) || isSecretFile(relativePath);
  });
  // `prisma migrate deploy` is a production gate, not an online server install.
  // Bundle the exact lock-resolved CLI runtime and immutable migration history
  // used by CI so root activation never invokes npm/npx or the public registry.
  const prismaRuntimeRoot = path.join(targetRoot, 'prisma-runtime');
  await mkdir(path.join(prismaRuntimeRoot, 'prisma'), { recursive: true, mode: 0o750 });
  await copyFile(prismaSchema, path.join(prismaRuntimeRoot, 'prisma', 'schema.prisma'));
  await copyFile(
    sqliteSchemaContract,
    path.join(prismaRuntimeRoot, 'prisma', 'sqlite-schema-contract.json'),
  );
  await copyTree(
    prismaMigrations,
    path.join(prismaRuntimeRoot, 'prisma', 'migrations'),
    (relativePath) => isDatabaseFile(relativePath) || isSecretFile(relativePath),
  );
  for (const packageName of prismaRuntimePackages) {
    await copyTree(
      path.join(projectRoot, 'node_modules', ...packageName.split('/')),
      path.join(prismaRuntimeRoot, 'node_modules', ...packageName.split('/')),
      (relativePath) => isDatabaseFile(relativePath) || isSecretFile(relativePath),
    );
  }
  await assertCleanRelease(targetRoot);
  process.stdout.write(`Clean standalone release assembled at ${targetRoot}\n`);
} catch (error) {
  if (targetCreated) await rm(targetRoot, { recursive: true, force: true });
  throw error;
}
