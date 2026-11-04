// Executes the actual dart2js method, with only UI/router primitives stubbed.
// This catches the generated try/catch temporary bug that a VM widget test misses.
import fs from 'node:fs';
import crypto from 'node:crypto';

const file = process.argv[2];
if (!file) throw new Error('Pass the debug dart2js main.dart.js artifact');
const bytes = fs.readFileSync(file);
const source = bytes.toString('utf8');
const checks = [
  ['__ExpenseClaimEditPageState_ConsumerState_FormDraftMixin', true],
  ['__PaymentRecordPickerState_ConsumerState_FormDraftMixin', false],
];
const results = [];
for (const [name, usesRouter] of checks) {
  const classAt = source.indexOf(`A.${name}.prototype = {`);
  const start = source.indexOf('withFormDraft$1(child) {', classAt);
  const end = source.indexOf('\n    dispose$', start);
  if (classAt < 0 || start < 0 || end < 0 || end - start > 18000) {
    throw new Error(`Unsupported or missing compiled method: ${name}`);
  }
  const method = 'function' + source.slice(start + 'withFormDraft$1'.length, end).trim().replace(/,$/, '');
  for (const router of [false, true]) for (const ready of [false, true]) for (const unknown of [false, true]) {
    const registry = { registerServerReloadCheckpoint$2() {}, changed$0() {} };
    const construct = function () { return {}; };
    const A = new Proxy({
      goRouterPageStateOrNull: () => null,
      GoRouter_maybeOf: () => router ? {} : null,
      assertTest: value => !value,
      assertThrow: () => { throw new Error('No router'); },
      FormDraftNavigation_registerReloadSafety() {},
      _setArrayType: values => values,
      PopScope$: canPop => ({ canPop }),
    }, { get: (target, key) => key in target ? target[key] : construct });
    const B = new Proxy({ JSArray_methods: { addAll$1: (target, values) => target.push(...values) } },
      { get: (target, key) => key in target ? target[key] : {} });
    const globals = { $get$webUpdateSafety: () => registry };
    const state = new Proxy({
      _widget: { claimId: null },
      get$context: () => ({}),
      get$formDraftEnabled: () => true,
      get$formDraftSpec: () => ({ route: '/demo' }),
      get$formDraftUsesRouterGuard: () => usesRouter,
      get$formDraftSubmissionRecoveryAction: () => null,
      get$_canReloadDraftSource: () => false,
      FormDraftMixin__draftReady: ready,
      FormDraftMixin__draftSubmissionBlocked: unknown,
    }, { get: (target, key) => key in target ? target[key] : String(key).startsWith('get$') ? () => null : false });
    const actualMethod = new Function('A', 'B', '$', 'type$', `return (${method});`)(A, B, globals, {});
    const result = actualMethod.call(state, {});
    const expected = usesRouter && router || !ready;
    results.push({ name, router, ready, unknown, expected, actualType: typeof result.canPop,
      ok: typeof result.canPop === 'boolean' && result.canPop === expected });
  }
}
const failed = results.filter(result => !result.ok);
console.log(JSON.stringify({ artifactSha256: crypto.createHash('sha256').update(bytes).digest('hex'),
  tested: results.length, passed: results.length - failed.length, failed }, null, 2));
if (failed.length) process.exitCode = 1;
