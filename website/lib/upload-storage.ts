import { createHash, randomBytes } from 'node:crypto';
import { constants } from 'node:fs';
import { access, link, lstat, mkdir, open, rm, unlink } from 'node:fs/promises';
import path from 'node:path';

export const PRODUCTION_UPLOADS_DIRECTORY = '/var/lib/uten-website/runtime/uploads';
export const PRODUCTION_UPLOAD_STAGING_DIRECTORY = '/var/lib/uten-website/runtime/upload-staging';

const GENERATED_UPLOAD_FILE_NAME = /^[a-f0-9]{32}\.webp$/u;

type UploadDirectoryOptions = {
  nodeEnv?: string;
  configuredDirectory?: string;
  cwd?: string;
};

type StoreUploadedWebpOptions = UploadDirectoryOptions & {
  fileNameFactory?: () => string;
};

export type UploadDescriptor = {
  fileName: string;
  publicPath: string;
  sha256: string;
  sizeBytes: number;
};

export function resolveUploadsDirectory(options: UploadDirectoryOptions = {}): string {
  const nodeEnv = options.nodeEnv ?? process.env.NODE_ENV ?? 'development';
  const configuredDirectory = options.configuredDirectory ?? process.env.UPLOADS_DIR;

  if (nodeEnv === 'production') {
    if (configuredDirectory !== PRODUCTION_UPLOADS_DIRECTORY) {
      throw new Error(
        `UPLOADS_DIR must be exactly ${PRODUCTION_UPLOADS_DIRECTORY} in production`,
      );
    }
    return PRODUCTION_UPLOADS_DIRECTORY;
  }

  if (!configuredDirectory?.trim()) {
    return path.resolve(options.cwd ?? process.cwd(), 'public', 'uploads');
  }
  if (!path.isAbsolute(configuredDirectory)) {
    throw new Error('UPLOADS_DIR must be an absolute path when configured');
  }
  return path.resolve(configuredDirectory);
}

export async function assertUploadsDirectoryReady(
  options: UploadDirectoryOptions = {},
): Promise<string> {
  const nodeEnv = options.nodeEnv ?? process.env.NODE_ENV ?? 'development';
  const directory = resolveUploadsDirectory(options);

  // Local development keeps the existing public/uploads behavior. Production
  // provisioning is root-controlled, so the application must never create or
  // silently replace its durable directory there.
  if (nodeEnv !== 'production') {
    await mkdir(directory, { recursive: true, mode: 0o750 });
  }

  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`Uploads path is not a real directory: ${directory}`);
  }
  if (nodeEnv === 'production' && (info.mode & 0o7777) !== 0o2750) {
    throw new Error('Production uploads directory must have mode 2750');
  }
  await access(directory, constants.R_OK | constants.W_OK);
  return directory;
}

async function resolveUploadStagingDirectory(
  uploadsDirectory: string,
  options: UploadDirectoryOptions,
): Promise<string> {
  const nodeEnv = options.nodeEnv ?? process.env.NODE_ENV ?? 'development';
  const directory = nodeEnv === 'production'
    ? PRODUCTION_UPLOAD_STAGING_DIRECTORY
    : path.join(path.dirname(uploadsDirectory), '.upload-staging');
  if (nodeEnv !== 'production') await mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Upload staging path is not a real directory');
  if (nodeEnv === 'production' && (info.mode & 0o7777) !== 0o2700) {
    throw new Error('Production upload staging directory must have mode 2700');
  }
  await access(directory, constants.R_OK | constants.W_OK);
  return directory;
}

export function createUploadFileName(): string {
  return `${randomBytes(16).toString('hex')}.webp`;
}

export function isGeneratedUploadFileName(value: string): boolean {
  return GENERATED_UPLOAD_FILE_NAME.test(value);
}

export function createUploadDescriptor(
  contents: Buffer,
  fileNameFactory: () => string = createUploadFileName,
): UploadDescriptor {
  if (contents.length === 0) throw new Error('Refusing to reserve an empty image');
  const fileName = fileNameFactory();
  if (!isGeneratedUploadFileName(fileName)) {
    throw new Error('Generated upload filename is outside the reviewed contract');
  }
  return {
    fileName,
    publicPath: `/uploads/${fileName}`,
    sha256: createHash('sha256').update(contents).digest('hex'),
    sizeBytes: contents.length,
  };
}

export async function storeUploadedWebp(
  contents: Buffer,
  options: StoreUploadedWebpOptions = {},
): Promise<string> {
  if (contents.length === 0) throw new Error('Refusing to store an empty image');

  const directory = await assertUploadsDirectoryReady(options);
  const stagingDirectory = await resolveUploadStagingDirectory(directory, options);
  const descriptor = createUploadDescriptor(contents, options.fileNameFactory);
  const { fileName } = descriptor;

  const absolutePath = path.join(directory, fileName);
  const stagingPath = path.join(stagingDirectory, `${fileName}.pending`);
  const handle = await open(stagingPath, 'wx', 0o640);
  try {
    await handle.writeFile(contents);
    await handle.chmod(0o640);
    await handle.sync();
  } catch (error) {
    await handle.close().catch(() => undefined);
    throw error;
  }
  await handle.close();

  // The URL is published to CMS content immediately after this function
  // returns.  Verify the final path is readable and persist the parent
  // directory entry so a successful response cannot point at a name that was
  // only present in volatile filesystem metadata. Linux is the production
  // runtime; Windows does not support opening a directory as a file handle.
  try {
    // Hard-link is an atomic no-overwrite publish: an unexpected existing
    // final name fails with EEXIST rather than replacing untracked bytes.
    await link(stagingPath, absolutePath);
    await unlink(stagingPath);
    const finalHandle = await open(absolutePath, 'r');
    try {
      await finalHandle.chmod(0o640);
      // The staging inode was fsynced before the atomic hard-link publish.
      // Windows rejects fsync on this read-only verification handle; Linux is
      // the production runtime and repeats the inode sync plus both directory
      // fsyncs below.
      if (process.platform !== 'win32') await finalHandle.sync();
    } finally {
      await finalHandle.close();
    }
    await access(absolutePath, constants.R_OK);
    if (process.platform !== 'win32') {
      for (const durableDirectory of [stagingDirectory, directory]) {
        const directoryHandle = await open(durableDirectory, 'r');
        try {
          await directoryHandle.sync();
        } finally {
          await directoryHandle.close();
        }
      }
    }
  } catch (error) {
    throw error;
  }

  return descriptor.publicPath;
}


export async function removeExactStoredUpload(
  descriptor: UploadDescriptor,
  options: UploadDirectoryOptions = {},
): Promise<boolean> {
  const directory = await assertUploadsDirectoryReady(options);
  const absolutePath = path.join(directory, descriptor.fileName);
  let info;
  try {
    info = await lstat(absolutePath);
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') return false;
    throw error;
  }
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || info.size !== descriptor.sizeBytes) {
    throw new Error('Refusing to remove upload whose file identity differs from its reservation');
  }
  const handle = await open(absolutePath, 'r');
  let digest;
  try {
    digest = createHash('sha256').update(await handle.readFile()).digest('hex');
  } finally {
    await handle.close();
  }
  if (digest !== descriptor.sha256) {
    throw new Error('Refusing to remove upload whose bytes differ from its reservation');
  }
  await rm(absolutePath);
  if (process.platform !== 'win32') {
    const directoryHandle = await open(directory, 'r');
    try {
      await directoryHandle.sync();
    } finally {
      await directoryHandle.close();
    }
  }
  return true;
}
