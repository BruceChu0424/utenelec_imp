from pathlib import Path
import argparse, json, os, re, subprocess as sp, difflib

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--deps', type=Path, required=True)
parser.add_argument('--runtime-config', type=Path, required=True)
a = parser.parse_args()
root = a.root.resolve()
out = a.output.resolve()
source = Path(__file__).resolve().parent
out.mkdir(parents=True, exist_ok=True)
if (out / 'projection-baseline.log').exists():
    raise SystemExit('Choose a fresh output directory; prior results must be retained')
config = json.loads(a.runtime_config.read_text(encoding='utf-8-sig'))
url = config['jdbcUrl']
assert url.startswith('jdbc:postgresql://127.0.0.1:')
port = re.search(r':(\d+)/', url).group(1)
classes = out / 'classes'
classes.mkdir(exist_ok=True)
mutated = out / 'mutated'
mutated.mkdir(exist_ok=True)
tmp = out / 'tmp'
tmp.mkdir(exist_ok=True)
deps = a.deps.read_text(encoding='utf-8-sig').strip()
assert all(Path(x).is_file() and x.endswith('.jar') for x in deps.split(';'))
cp = ';'.join(str(x.resolve()) for x in [classes, a.build_dir / 'test-classes', a.build_dir / 'classes']) + ';' + deps
env = dict(os.environ, TMP=str(tmp), TEMP=str(tmp), UTEN_RUN_DB_TESTS='true',
           AUDIT_LEGACY_DIR=str(out), AUDIT_KIT_PG_PORT=port, AUDIT_KIT_JDBC=url,
           AUDIT_KIT_USERNAME=config['username'], AUDIT_KIT_PASSWORD=config['password'])


def run(cmd, args, label, expect=0):
    arg = out / (label + '.args')
    arg.write_text('\n'.join('"' + str(x).replace('\\', '/') + '"' for x in args), encoding='utf8')
    with (out / (label + '.log')).open('wb') as stream:
        ret = sp.run([cmd, '@' + str(arg)], cwd=root / 'server', env=env, stdout=stream, stderr=stream)
    if ret.returncode != expect:
        raise SystemExit(label + ' returned ' + str(ret.returncode) + '; expected ' + str(expect) + '; raw output retained')


run('javac', ['-proc:none', '-encoding', 'UTF-8', '-cp', cp, '-d', classes,
              source / 'FeedbackLegacyMaterialUpgradeFixture.java',
              source / 'FeedbackWorkbenchProjectionFixture.java', source / 'FeedbackProjectionRunner.java'],
    'projection-fixture-javac')
service = root / 'server/src/main/java/com/uten/imp/features/production/execution/ProductionExecutionWorkbenchService.java'
text = service.read_text(encoding='utf8')
before = '''+ segmentSelect("readiness.split_empty_issued", "readiness.supplement_ready", "readiness.discovery_pending")
                + ", ("+actionScope+") AS original_task_scope,"'''
after = '''+ segmentSelect("readiness.split_empty_issued", "readiness.supplement_ready", "readiness.discovery_pending")
                    .replace("(fn_execution_partial_material_report_room(task.segment_id,NULL) IS NOT NULL)", "(" + actionScope + ")")
                + ", (fn_execution_partial_material_report_room(task.segment_id,NULL) IS NOT NULL) AS original_task_scope,"'''
assert text.count(before) == 1
bad = text.replace(before, after)
java = out / service.name
java.write_text(bad, encoding='utf8')
(out / 'projection-mutation.diff').write_text(''.join(difflib.unified_diff(text.splitlines(True), bad.splitlines(True))), encoding='utf8')
run('javac', ['-proc:full', '-encoding', 'UTF-8', '-cp', cp, '-d', mutated, java], 'projection-mutant-javac')
for label, overlay, code in [('projection-baseline', '', 0), ('projection-mutant', str(mutated.resolve()) + ';', 1), ('projection-restored', '', 0)]:
    run('java', ['-Xshare:off', '-javaagent:' + next(x for x in deps.split(';') if '/mockito-core/' in x.replace('\\', '/')), '-Xmx1500m', '-Djava.io.tmpdir=' + str(tmp),
                 '-Dlogging.file.name=' + str(out / (label + '-spring.log')), '-cp', overlay + cp,
                 'FeedbackProjectionRunner', 'realWorkbenchSqlKeepsPartialMaterialAndWorkshopAuthorityIndependent'], label, code)
    if code:
        result = (out / (label + '.log')).read_text(encoding='utf8', errors='replace')
        assert 'AssertionFailedError' in result and re.search(r'1 tests failed', result), 'The mutant must fail the real SQL business assertion, not an unrelated execution error'
print('PASS correct SQL; EXPECTED assertion failure with swapped boolean projection; PASS restored SQL. Product source was never mutated.')
