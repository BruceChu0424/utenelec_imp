import path from 'node:path';
import { applyLegacyV2, dryRunLegacyV2 } from './lib/legacy-v2-importer';

type Command = 'dry-run' | 'apply';

function usage(): string {
  return `UTEN legacy catalog v2 importer

Dry-run (never writes the database):
  tsx scripts/import-legacy-v2.ts dry-run --input <crawler-output> --report <plan.json>

Apply (requires a passing expectFull dry-run plan):
  tsx scripts/import-legacy-v2.ts apply --input <crawler-output> --plan <plan.json> \\
    --database <sqlite.db> --public-dir <public> [--backup-dir <directory>]

Partial, live-smoke and fixture outputs are always blocked from apply.`;
}

function parseArguments(argv: string[]): { command: Command; options: Map<string, string> } {
  const [commandValue, ...rest] = argv;
  if (commandValue !== 'dry-run' && commandValue !== 'apply') throw new Error(usage());
  const options = new Map<string, string>();
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index];
    const value = rest[index + 1];
    if (!key?.startsWith('--') || !value || value.startsWith('--')) throw new Error(`Invalid option near ${key ?? '<end>'}.\n\n${usage()}`);
    if (options.has(key)) throw new Error(`Duplicate option ${key}.`);
    options.set(key, value);
  }
  return { command: commandValue, options };
}

function required(options: Map<string, string>, key: string): string {
  const value = options.get(key);
  if (!value) throw new Error(`Missing ${key}.\n\n${usage()}`);
  return path.resolve(value);
}

async function main(): Promise<void> {
  const { command, options } = parseArguments(process.argv.slice(2));
  if (command === 'dry-run') {
    const input = required(options, '--input');
    const report = options.get('--report') ? path.resolve(options.get('--report')!) : undefined;
    const plan = await dryRunLegacyV2(input, report);
    console.log(JSON.stringify({
      status: plan.status,
      applyEligible: plan.applyGate.eligible,
      reasons: plan.applyGate.reasons,
      summary: plan.summary,
      report: report ?? null,
      bundleSha256: plan.digests.bundleSha256,
    }, null, 2));
    if (plan.status !== 'pass') process.exitCode = 1;
    return;
  }

  const result = await applyLegacyV2({
    inputRoot: required(options, '--input'),
    planPath: required(options, '--plan'),
    databasePath: required(options, '--database'),
    publicDir: required(options, '--public-dir'),
    backupDir: options.get('--backup-dir') ? path.resolve(options.get('--backup-dir')!) : undefined,
  });
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error(`[legacy-v2-import] ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
