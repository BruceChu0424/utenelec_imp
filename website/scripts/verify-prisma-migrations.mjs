import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';

const projectRoot = path.resolve(import.meta.dirname, '..');
const prismaCli = path.join(projectRoot, 'node_modules', 'prisma', 'build', 'index.js');
const maximumAttempts = process.platform === 'win32' ? 4 : 1;

async function run(arguments_, databaseUrl) {
  return new Promise((resolve, reject) => {
    const childEnvironment = {
      ...process.env,
      DATABASE_URL: databaseUrl,
    };
    // Prisma 5.22's Windows schema engine can otherwise exit at startup with
    // only an empty "Schema engine error". The info logger avoids that engine
    // bootstrap defect and is scoped to this disposable verification process.
    if (process.platform === 'win32') {
      childEnvironment.RUST_LOG = 'info';
    }
    const child = spawn(process.execPath, [prismaCli, ...arguments_], {
      cwd: projectRoot,
      env: childEnvironment,
      windowsHide: true,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('close', (status) => {
      if (status !== 0) {
        const output = [stdout, stderr].filter(Boolean).join('\n');
        reject(new Error(
          `Prisma migration verification failed (${arguments_.join(' ')}):\n${output}`,
        ));
        return;
      }
      resolve(`${stdout}${stderr}`);
    });
  });
}

async function verifyInFreshDatabase() {
  const temporaryDirectory = await mkdtemp(
    path.join(projectRoot, '.prisma-migration-test-'),
  );
  const temporaryName = path.basename(temporaryDirectory);
  const deployDatabaseUrl = `file:../${temporaryName}/website.db`;
  const diffDatabaseUrl = `file:${temporaryName}/website.db`;

  try {
    const deployOutput = await run(
      ['migrate', 'deploy', '--schema', 'prisma/schema.prisma'],
      deployDatabaseUrl,
    );
    if (!deployOutput.includes('All migrations have been successfully applied.')) {
      throw new Error('Prisma did not report a successful clean migration deployment');
    }

    const statusOutput = await run(
      ['migrate', 'status', '--schema', 'prisma/schema.prisma'],
      deployDatabaseUrl,
    );
    if (!statusOutput.includes('Database schema is up to date!')) {
      throw new Error('Prisma migration history is not up to date after clean deployment');
    }

    const diffOutput = await run(
      [
        'migrate',
        'diff',
        '--from-url',
        diffDatabaseUrl,
        '--to-schema-datamodel',
        'prisma/schema.prisma',
        '--exit-code',
      ],
      deployDatabaseUrl,
    );
    if (!diffOutput.includes('No difference detected.')) {
      throw new Error('Prisma migrations do not reproduce the current schema exactly');
    }

  } finally {
    await rm(temporaryDirectory, {
      force: true,
      maxRetries: 10,
      recursive: true,
      retryDelay: 100,
    });
  }
}

function isEmptyWindowsSchemaEngineStartupFailure(error) {
  return process.platform === 'win32'
    && error instanceof Error
    && /Error: Schema engine error:\s*$/u.test(error.message);
}

let lastError;
for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
  try {
    await verifyInFreshDatabase();
    process.stdout.write('PRISMA_MIGRATION_HISTORY_OK\n');
    lastError = undefined;
    break;
  } catch (error) {
    lastError = error;
    if (!isEmptyWindowsSchemaEngineStartupFailure(error)
        || attempt === maximumAttempts) {
      throw error;
    }
    process.stderr.write(
      `Prisma schema engine startup failed without diagnostics; retrying with a fresh database (${attempt}/${maximumAttempts})\n`,
    );
    await new Promise((resolve) => setTimeout(resolve, attempt * 300));
  }
}

if (lastError) {
  throw lastError;
}
