"""Isolated Linux-root regression: SGID publication between distinct unprivileged UIDs.

Run under sudo on a disposable CI runner or in the documented local test container.
Only temporary fixture files are created. The actual stdlib writer/lock functions
are loaded without importing the forecasting dependency environment.
"""
from __future__ import annotations

import ast
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import traceback


def publication_functions() -> dict:
    """Load the actual stdlib publication/locking closure, without model imports."""
    worker = Path(__file__).resolve().parents[1] / 'forecast_worker'
    locking_path = worker / 'locking.py'
    spec = importlib.util.spec_from_file_location('_publication_permission_locking', locking_path)
    assert spec is not None and spec.loader is not None
    locking = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = locking
    spec.loader.exec_module(locking)
    namespace = {'os': os, 'json': json, 'tempfile': tempfile, 'Path': Path,
                 'contextmanager': contextmanager, 'os_file_lock': locking.os_file_lock,
                 'write_barrier': locking.write_barrier,
                 'register_write_barrier': locking.register_write_barrier}
    data_path = worker / 'data.py'
    data = ast.parse(data_path.read_text(encoding='utf-8'))
    errors = [node for node in data.body if isinstance(node, ast.ClassDef) and node.name == 'InputError']
    assert len(errors) == 1
    exec(compile(ast.Module(body=errors, type_ignores=[]), str(data_path), 'exec'), namespace)
    source = worker / 'cli.py'
    parsed = ast.parse(source.read_text(encoding='utf-8'))
    names = {'atomic_json', 'atomic_health_json', '_atomic_json', 'series_lock'}
    functions = [node for node in parsed.body if isinstance(node, ast.FunctionDef) and node.name in names]
    assert {node.name for node in functions} == names
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), 'exec'), namespace)
    return namespace


def fail_child() -> None:
    # os._exit deliberately skips Python buffering; preserve the real cause.
    os.write(2, traceback.format_exc().encode('utf-8', errors='replace'))
    os._exit(1)


def unprivileged(uid: int, gid: int) -> None:
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
    status = Path('/proc/self/status').read_text(encoding='ascii')
    effective = next(line.split()[1] for line in status.splitlines() if line.startswith('CapEff:'))
    assert int(effective, 16) == 0, 'fixture reader must not retain root capabilities'


def child(action) -> None:
    pid = os.fork()
    if pid == 0:
        try:
            action()
        except BaseException:
            fail_child()
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 0, 'unprivileged permission assertion failed'


def denied(action) -> None:
    try:
        action()
    except PermissionError:
        return
    raise AssertionError('unprivileged identity unexpectedly accessed a protected object')


def main() -> None:
    if os.name != 'posix' or os.geteuid() != 0:
        raise SystemExit('Run this check only as root in an isolated Linux runner/container')
    namespace = publication_functions()

    writer_uid, writer_gid, reader_uid, shared_gid = 50001, 50001, 50002, 50003
    with tempfile.TemporaryDirectory(prefix='material-permission-check-') as temporary:
        root = Path(temporary)
        os.chown(root, writer_uid, shared_gid)
        os.chmod(root, 0o2750)
        assert stat.S_IMODE(root.stat().st_mode) == 0o2750, 'isolated runner must retain CAP_FSETID to create the SGID fixture'
        namespace['register_write_barrier'](root)
        ready_read, ready_write = os.pipe()
        finish_read, finish_write = os.pipe()
        writer = os.fork()
        if writer == 0:
            os.close(ready_read)
            os.close(finish_write)
            try:
                unprivileged(writer_uid, writer_gid)
                os.umask(0o077)
                with namespace['series_lock'](root / 'collector.lock'):
                    namespace['atomic_json'](root / 'snapshot.json', {'public_market_fixture': True}, public=True)
                    namespace['atomic_json'](root / 'private-state.json', {'private_fixture': True})
                    namespace['atomic_health_json'](root / 'auto-feed-health.json', {'live_run_fixture': True})
                    os.write(ready_write, b'1')
                    os.read(finish_read, 1)
            except BaseException:
                fail_child()
            os._exit(0)
        os.close(ready_write)
        os.close(finish_read)
        try:
            assert os.read(ready_read, 1) == b'1', 'writer failed before publishing fixture'
            assert stat.S_IMODE((root / 'snapshot.json').stat().st_mode) == 0o640
            assert (root / 'snapshot.json').stat().st_gid == shared_gid
            assert stat.S_IMODE((root / 'auto-feed-health.json').stat().st_mode) == 0o640
            assert (root / 'auto-feed-health.json').stat().st_gid == shared_gid
            assert stat.S_IMODE((root / 'private-state.json').stat().st_mode) == 0o600
            assert stat.S_IMODE((root / 'collector.lock').stat().st_mode) == 0o600
            assert stat.S_IMODE((root / '.market-write.lock').stat().st_mode) == 0o600

            def reader() -> None:
                unprivileged(reader_uid, shared_gid)
                assert json.loads((root / 'snapshot.json').read_text()) == {'public_market_fixture': True}
                assert json.loads((root / 'auto-feed-health.json').read_text()) == {'live_run_fixture': True}
                denied(lambda: (root / 'snapshot.json').open('a'))
                denied(lambda: (root / 'auto-feed-health.json').open('a'))
                denied(lambda: (root / 'private-state.json').read_bytes())
                denied(lambda: (root / 'collector.lock').read_bytes())
                denied(lambda: (root / '.market-write.lock').read_bytes())
                denied(lambda: (root / 'unexpected.json').write_text('{}'))

            def unrelated() -> None:
                unprivileged(50004, 50004)
                denied(lambda: (root / 'snapshot.json').read_bytes())

            def competing_writer() -> None:
                unprivileged(writer_uid, writer_gid)
                try:
                    with namespace['series_lock'](root / 'collector.lock'):
                        raise AssertionError('a second writer acquired an already held OS lock')
                except namespace['InputError'] as error:
                    assert str(error) == 'COLLECTOR_BUSY'

            child(reader)
            child(unrelated)
            child(competing_writer)
        finally:
            try:
                os.write(finish_write, b'1')
            except BrokenPipeError:
                pass
            os.close(finish_write)
            os.close(ready_read)
            _, status = os.waitpid(writer, 0)
            assert os.waitstatus_to_exitcode(status) == 0, 'writer did not release the fixture lock cleanly'
        # Crash-released locks intentionally keep the inode: unlinking a live
        # POSIX lock path can let a second writer lock a different inode.
        assert stat.S_IMODE((root / 'collector.lock').stat().st_mode) == 0o600

        def released_writer() -> None:
            unprivileged(writer_uid, writer_gid)
            with namespace['series_lock'](root / 'collector.lock'):
                with namespace['write_barrier'](root / 'snapshot.json'):
                    assert json.loads((root / 'private-state.json').read_text()) == {'private_fixture': True}

        child(released_writer)
    print(json.dumps({'state': 'LINUX_SGID_DISTINCT_UID_PUBLICATION_PASSED',
                      'writerAndReaderAreDifferent': True, 'readerCapabilities': 0,
                      'readerCanReadPublicOnly': True, 'readerCannotWrite': True,
                      'privateStateAndLockRemainOwnerOnly': True,
                      'competingWriterDenied': True,
                      'persistentLocksReleasedAndReacquired': True}))


if __name__ == '__main__':
    main()
