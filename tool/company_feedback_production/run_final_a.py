"""Prepare or execute A's complete backend acceptance on one pinned checkout.

The default is a read-only plan. --execute requires a clean, exact candidate and
a new evidence directory. All databases, compiled classes and temporary files
belong to that invocation; Root's runtime configuration is never accepted.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

from attest_candidate import BASELINE, attest

TESTS = (
    'ProductionPartialReportQuantityEndToEndTest',
    'ProductionQuantityAdversarialEndToEndTest',
    'WorkshopPublicSurplusEndToEndTest',
    'ProductionMaterialKitProofsTest',
    'DailyReportExecutionSegmentGuardTest',
    'ReportablePlanLinePostgresTest',
    'ReportablePlanLineQuerySecurityContractTest',
    'ProductionExecutionSegmentServiceTest',
    'ProductionExecutionWorkbenchProjectionTest',
    'ProductionExecutionWorkbenchSecurityContractTest',
    'ProductionWorkshopTaskStageContractTest',
    'ProductionMaterialSettlementServiceTest',
    'ProductionMaterialStockLedgerCancellationPolicyTest',
    'ProductionMaterialStockLedgerRoutingTest',
    'PartialMaterialReportCapacityPostgresTest',
)


def python_executable():
    # Embedded installations can report their runtime directory as executable.
    path = Path(sys.executable)
    if not path.is_file():
        path = Path(shutil.which('python.exe') or shutil.which('python') or '')
    if not path.is_file():
        raise RuntimeError('An existing Python executable is required; nothing is installed')
    return str(path)


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root).decode('utf8').strip()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf8')


def fingerprint(directory):
    entries = []
    aggregate = hashlib.sha256()
    for path in sorted(directory.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(directory).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        aggregate.update(relative.encode('utf8') + b'\0' + digest.encode('ascii') + b'\n')
        entries.append({'path': relative, 'bytes': path.stat().st_size, 'sha256': digest})
    return {'files': len(entries), 'aggregateSha256': aggregate.hexdigest(), 'entries': entries}


def java_args(path, args):
    # Java's argument-file grammar, not shell interpolation; no secrets in args.
    path.write_text('\n'.join('"' + str(x).replace('\\', '/') + '"' for x in args), encoding='utf8')


def backend_results(build):
    suites = []
    for path in sorted((build / 'surefire-reports').glob('TEST-*.xml')):
        node = ET.parse(path).getroot()
        simple = node.attrib.get('name', '').rsplit('.', 1)[-1]
        if simple not in TESTS:
            continue
        suites.append({'class': node.attrib['name'], 'xml': str(path),
                       **{key: int(node.attrib.get(key, 0))
                          for key in ['tests', 'failures', 'errors', 'skipped']}})
    assert {s['class'].rsplit('.', 1)[-1] for s in suites} == set(TESTS), 'Missing original test class'
    assert sum(s['tests'] for s in suites) == 209, 'Original 15-class test count changed; review explicitly'
    assert all(not s['failures'] and not s['errors'] and not s['skipped'] for s in suites)
    owning = [s for s in suites if s['class'].rsplit('.', 1)[-1] in {
        'PartialMaterialReportCapacityPostgresTest'}]
    assert sum(s['tests'] for s in owning) == 26, 'Owning PG subset must remain 26'
    return {'classes': suites, 'tests': 209, 'owningPgSubset': 26, 'failures': 0, 'skips': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    source = Path(__file__).resolve().parent
    if source.parents[1] != root:
        raise SystemExit('Invoke the runner from the selected candidate checkout')
    candidate = git(root, 'rev-parse', args.candidate)
    if git(root, 'rev-parse', 'HEAD') != candidate:
        raise SystemExit('Selected checkout is not at the exact candidate')
    output = args.output.resolve()
    if output == root or not output.is_relative_to(root) or output.exists():
        raise SystemExit('Choose a new output directory inside this worktree')
    comparison = attest(root, candidate, BASELINE)
    plan = {'candidate': candidate, 'baseline': BASELINE, 'execute': args.execute,
            'output': str(output), 'tests': TESTS, 'expectedTestCount': 209,
            'legacyRevision': '86dffb9dbcb52b248ade1f2b3ea4a7c72db738a2',
            'owningPgSubset': 26, 'upgrade': '1128/1129 x CAP/three-material x create/edit/approve = 12 clones; 19 launchers',
            'proof': 'SQL probe: 513/1025/2049 and EXPLAIN; owning 26-case class also runs 20k prefix / 1000 capture',
            'projection': 'correct -> assertion-failing mutant -> restored',
            'directLot': 'two unchanged public-service cases',
            'rootRuntimeAccess': False, 'priorRunRelabelled': False,
            'changedSourceGroups': comparison['groups']}
    if not args.execute:
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return 0
    if git(root, 'rev-parse', '86dffb9db') != plan['legacyRevision']:
        raise SystemExit('The legacy V1128 source pin changed')
    if git(root, 'status', '--porcelain', '--untracked-files=no'):
        raise SystemExit('Tracked source must be clean before final acceptance')
    output.mkdir(parents=True)
    temporary = output / 'private' / 'tmp'
    temporary.mkdir(parents=True)
    build = output / 'maven-a'
    compiled = output / 'compiled'
    deps_file = output / 'deps-cp.txt'
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('AUDIT_') and key not in {'SPRING_DATASOURCE_URL', 'SPRING_DATASOURCE_USERNAME', 'SPRING_DATASOURCE_PASSWORD'}}
    env.update(TMP=str(temporary), TEMP=str(temporary), UTEN_RUN_DB_TESTS='true',
               MAVEN_OPTS='-Xmx1900m -Djava.io.tmpdir=' + str(temporary))
    result = {'plan': plan, 'stages': [], 'accepted': False, 'actualWebOrWindows': False}
    write_json(output / 'source-before.json', {'head': candidate, 'tree': git(root, 'rev-parse', 'HEAD^{tree}'),
                                               'mainObserved': git(root, 'rev-parse', 'main')})
    write_json(output / 'source-vs-7b-per-file.json', comparison)

    def run(name, command, cwd=root):
        start = time.time()
        print('START ' + name, flush=True)
        with (output / (name + '.log')).open('wb') as log:
            code = subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                                  stdout=log, stderr=log).returncode
        stage = {'name': name, 'command': [str(x) for x in command], 'exitCode': code,
                 'seconds': round(time.time() - start, 3)}
        result['stages'].append(stage)
        write_json(output / 'result.json', result)
        print('END ' + name + ' exit=' + str(code), flush=True)
        if code:
            raise RuntimeError(name + ' failed; original output retained')

    def python(name, *arguments):
        run(name, [python_executable(), '-X', 'utf8', source / (name + '.py'), *arguments])

    try:
        maven = shutil.which('mvn')
        if not maven:
            raise RuntimeError('Maven is not available')
        run('compile', [maven, '-B', '-ntp', '-Duten.build.directory=' + str(build), '-DskipTests',
                        'test-compile', 'dependency:build-classpath', '-Dmdep.includeScope=test',
                        '-Dmdep.outputFile=' + str(deps_file)], root / 'server')
        compiled.mkdir()
        for directory in ['classes', 'test-classes']:
            shutil.copytree(build / directory, compiled / directory)
        compiled_before = fingerprint(compiled)
        write_json(output / 'compiled-provenance.json', compiled_before)
        dependencies = deps_file.read_text(encoding='utf-8-sig').strip()
        jars = dependencies.split(';')
        assert all(Path(jar).is_file() and jar.endswith('.jar') for jar in jars)
        dependency_hashes = {jar: hashlib.sha256(Path(jar).read_bytes()).hexdigest() for jar in jars}
        write_json(output / 'dependency-provenance.json', dependency_hashes)
        run('a-backend', [maven, '-B', '-ntp', '-Duten.build.directory=' + str(build),
                          '-Dtest=' + ','.join(TESTS), 'test'], root / 'server')
        result['backend15'] = backend_results(build)
        result['mavenClassesMatchFixedSnapshot'] = all(
            fingerprint(build / directory) == fingerprint(compiled / directory)
            for directory in ['classes', 'test-classes'])
        assert result['mavenClassesMatchFixedSnapshot'], 'Maven test phase changed the compiled candidate'
        direct = output / 'direct-return'
        direct.mkdir()
        classpath = ';'.join(str(x) for x in [direct, compiled / 'test-classes', compiled / 'classes']) + ';' + dependencies
        arguments = direct / 'compile.args'
        java_args(arguments, ['-proc:none', '-encoding', 'UTF-8', '-cp', classpath, '-d', direct,
                              source / 'FeedbackDirectReturnRunner.java'])
        run('direct-javac', ['javac', '@' + str(arguments)], root / 'server')
        arguments = direct / 'run.args'
        java_args(arguments, ['-Xshare:off', '-javaagent:' + next(jar for jar in jars if '/mockito-core/' in jar.replace('\\', '/')),
                              '-Xmx1500m', '-Dfile.encoding=UTF-8', '-Djava.io.tmpdir=' + str(temporary),
                              '-Dlogging.file.name=' + str(direct / 'spring.log'), '-cp', classpath,
                              'FeedbackDirectReturnRunner'])
        run('direct-return', ['java', '@' + str(arguments)], root / 'server')
        python('compile_legacy', '--root', root, '--output', output / 'legacy')
        python('proof_probe', '--root', root, '--output', output / 'proof')
        python('upgrade_probe', '--root', root, '--output', output / 'upgrade', '--build-dir', compiled,
               '--legacy-build', output / 'legacy' / 'legacy-build', '--deps', deps_file)
        private_config = output / 'private' / 'projection-runtime.json'
        python('prepare_projection_database', '--upgrade-output', output / 'upgrade', '--output', private_config)
        python('projection_mutation', '--root', root, '--output', output / 'projection', '--build-dir', compiled,
               '--deps', deps_file, '--runtime-config', private_config)
        result['compiledSnapshotUnchanged'] = fingerprint(compiled) == compiled_before
        assert result['compiledSnapshotUnchanged'], 'Acceptance classpath changed during the run'
        result['dependencyJarsUnchanged'] = all(
            hashlib.sha256(Path(jar).read_bytes()).hexdigest() == before
            for jar, before in dependency_hashes.items())
        assert result['dependencyJarsUnchanged'], 'Dependency jar bytes changed during the run'
        assert not git(root, 'status', '--porcelain', '--untracked-files=no'), 'Tracked source changed'
        assert git(root, 'rev-parse', 'HEAD') == candidate
        result['accepted'] = True
    except Exception as error:
        result['failure'] = str(error)
        raise
    finally:
        result['afterSource'] = git(root, 'rev-parse', 'HEAD')
        result['mainObservedAfter'] = git(root, 'rev-parse', 'main')
        write_json(output / 'result.json', result)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
