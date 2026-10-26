import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  PRODUCTION_UPLOADS_DIRECTORY,
  createUploadFileName,
  resolveUploadsDirectory,
  storeUploadedWebp,
} from '../lib/upload-storage';
import { MAX_DOCUMENT_BYTES } from '../lib/document-storage';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('production uploads require the exact durable shared directory', () => {
  assert.throws(
    () => resolveUploadsDirectory({ nodeEnv: 'production', configuredDirectory: '' }),
    /UPLOADS_DIR must be exactly/u,
  );
  assert.throws(
    () => resolveUploadsDirectory({
      nodeEnv: 'production',
      configuredDirectory: '/opt/uten-website/current/public/uploads',
    }),
    /UPLOADS_DIR must be exactly/u,
  );
  assert.equal(
    resolveUploadsDirectory({
      nodeEnv: 'production',
      configuredDirectory: PRODUCTION_UPLOADS_DIRECTORY,
    }),
    PRODUCTION_UPLOADS_DIRECTORY,
  );
});

test('development keeps public/uploads fallback and accepts only absolute overrides', () => {
  assert.equal(
    resolveUploadsDirectory({ nodeEnv: 'development', cwd: projectRoot, configuredDirectory: '' }),
    path.join(projectRoot, 'public', 'uploads'),
  );
  assert.throws(
    () => resolveUploadsDirectory({
      nodeEnv: 'development',
      configuredDirectory: 'relative/uploads',
    }),
    /must be an absolute path/u,
  );
  assert.equal(
    resolveUploadsDirectory({
      nodeEnv: 'development',
      configuredDirectory: path.join(projectRoot, '.runtime', 'uploads'),
    }),
    path.join(projectRoot, '.runtime', 'uploads'),
  );
});

test('generated upload filenames are opaque immutable WebP names', () => {
  const names = new Set(Array.from({ length: 100 }, () => createUploadFileName()));
  assert.equal(names.size, 100);
  for (const name of names) assert.match(name, /^[a-f0-9]{32}\.webp$/u);
});

test('storage creates one exclusive durable file and never overwrites a collision', async () => {
  const temporaryRoot = await mkdtemp(path.join(tmpdir(), 'uten-website-uploads-'));
  const uploadsDirectory = path.join(temporaryRoot, 'uploads');
  const fileName = '0123456789abcdef0123456789abcdef.webp';
  const contents = Buffer.from('reviewed-webp-fixture');

  try {
    const url = await storeUploadedWebp(contents, {
      nodeEnv: 'test',
      configuredDirectory: uploadsDirectory,
      fileNameFactory: () => fileName,
    });
    assert.equal(url, `/uploads/${fileName}`);
    assert.deepEqual(await readFile(path.join(uploadsDirectory, fileName)), contents);
    assert.deepEqual(await readdir(uploadsDirectory), [fileName]);
    if (process.platform !== 'win32') {
      const info = await stat(path.join(uploadsDirectory, fileName));
      assert.equal(info.mode & 0o777, 0o640);
    }

    await assert.rejects(
      storeUploadedWebp(Buffer.from('replacement'), {
        nodeEnv: 'test',
        configuredDirectory: uploadsDirectory,
        fileNameFactory: () => fileName,
      }),
      (error: NodeJS.ErrnoException) => error.code === 'EEXIST',
    );
    assert.deepEqual(await readFile(path.join(uploadsDirectory, fileName)), contents);
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }
});

test('storage rejects traversal, legacy names and empty content before publishing', async () => {
  const temporaryRoot = await mkdtemp(path.join(tmpdir(), 'uten-website-uploads-'));
  const uploadsDirectory = path.join(temporaryRoot, 'uploads');

  try {
    await assert.rejects(
      storeUploadedWebp(Buffer.from('data'), {
        nodeEnv: 'test',
        configuredDirectory: uploadsDirectory,
        fileNameFactory: () => '../escape.webp',
      }),
      /outside the reviewed contract/u,
    );
    await assert.rejects(
      storeUploadedWebp(Buffer.alloc(0), {
        nodeEnv: 'test',
        configuredDirectory: uploadsDirectory,
      }),
      /empty image/u,
    );
    assert.deepEqual(await readdir(uploadsDirectory), []);
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  }
});

test('runtime templates pin application and Nginx to the same non-release path', async () => {
  const [nginx, service, validator, runtimeEnvironment, nextConfig] = await Promise.all([
    readFile(path.join(projectRoot, 'deploy', 'nginx-website.conf.example'), 'utf8'),
    readFile(path.join(projectRoot, 'deploy', 'uten-website.service.example'), 'utf8'),
    readFile(path.join(projectRoot, 'deploy', 'validate-runtime.sh'), 'utf8'),
    readFile(path.join(projectRoot, 'deploy', 'website.env.example'), 'utf8'),
    readFile(path.join(projectRoot, 'next.config.mjs'), 'utf8'),
  ]);

  const uploadsLocation = nginx.slice(
    nginx.indexOf('location ^~ /uploads/'),
    nginx.indexOf('location / {', nginx.indexOf('location ^~ /uploads/')),
  );
  assert.match(uploadsLocation, /alias \/var\/lib\/uten-website\/runtime\/uploads\/;/u);
  assert.match(uploadsLocation, /disable_symlinks on/u);
  assert.doesNotMatch(uploadsLocation, /proxy_pass/u);
  const readWritePaths = service.split('\n').find((line) => line.startsWith('ReadWritePaths='));
  assert.ok(readWritePaths);
  const writableTokens = readWritePaths.slice('ReadWritePaths='.length).trim().split(/\s+/u);
  assert.ok(writableTokens.includes('/var/lib/uten-website'));
  assert.ok(writableTokens.includes('/var/backups/uten-website'));
  assert.equal(writableTokens.some((entry) => entry.startsWith('/var/lib/uten-website/')), false);
  assert.equal(writableTokens.some((entry) => entry.startsWith('/var/backups/uten-website/')), false);
  assert.match(validator, /UPLOADS_DIR/u);
  assert.match(validator, /immutable release must not contain or link a runtime uploads path/u);
  assert.match(validator, /uten-website:uten-website-media:2750/u);
  assert.match(validator, /group:uten-website-media:--x/u);
  assert.match(runtimeEnvironment, /^UPLOADS_DIR=\/var\/lib\/uten-website\/runtime\/uploads$/mu);
  assert.match(runtimeEnvironment, /^DOCUMENTS_DIR=\/var\/lib\/uten-website\/runtime\/documents$/mu);
  assert.doesNotMatch(nginx, /alias\s+[^;]*\/documents\/?\s*;/u);
  assert.match(nextConfig, /images:\s*\{\s*unoptimized:\s*true\s*\}/u);
  assert.doesNotMatch(runtimeEnvironment, /^[A-Z][A-Z0-9_]*=["']/mu);
});

test('all authenticated admin upload routes allow the full PDF envelope without enlarging public forms', async () => {
  const [nginx, nextConfig] = await Promise.all([
    readFile(path.join(projectRoot, 'deploy', 'nginx-website.conf.example'), 'utf8'),
    readFile(path.join(projectRoot, 'next.config.mjs'), 'utf8'),
  ]);
  const actionLimit = nextConfig.match(/bodySizeLimit:\s*['"](\d+)mb['"]/u);
  assert.ok(actionLimit);
  assert.equal(Number(actionLimit[1]), MAX_DOCUMENT_BYTES / 1024 / 1024 + 2);
  const routes = Array.from(nginx.matchAll(/location\s+(=|\^~)\s+(\/admin\/?)\s*\{([^{}]*)\}/gu));
  assert.deepEqual(routes.map(route => `${route[1]} ${route[2]}`).sort(), ['= /admin', '^~ /admin/']);
  for (const route of routes) {
    const edgeLimit = route[3].match(/client_max_body_size\s+(\d+)m;/u);
    assert.ok(edgeLimit, route[2]);
    assert.equal(Number(edgeLimit[1]), Number(actionLimit[1]), route[2]);
    assert.match(route[3], /proxy_pass http:\/\/uten_website_backend;/u);
  }
  assert.match(nginx.slice(0, nginx.indexOf('location = /api/health')), /client_max_body_size 256k;/u);
});
