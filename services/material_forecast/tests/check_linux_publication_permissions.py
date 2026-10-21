"""Isolated Linux-root regression: SGID publication between distinct unprivileged UIDs.

Run under sudo on a disposable CI runner or in the documented local test container.
Only temporary fixture files are created. The actual stdlib writer/lock functions
are loaded without importing the forecasting dependency environment.
"""
from __future__ import annotations

import ast
from contextlib import contextmanager
import json
import os
from pathlib import Path
import stat
import tempfile


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
            os._exit(1)
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
    source = Path(__file__).resolve().parents[1] / 'forecast_worker/cli.py'
    parsed = ast.parse(source.read_text(encoding='utf-8'))
    functions = [node for node in parsed.body if isinstance(node, ast.FunctionDef)
                 and node.name in {'atomic_json', 'series_lock'}]
    assert len(functions) == 2
    namespace = {'os': os, 'json': json, 'tempfile': tempfile, 'Path': Path,
                 'contextmanager': contextmanager}
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), 'exec'), namespace)

    writer_uid, writer_gid, reader_uid, shared_gid = 50001, 50001, 50002, 50003
    with tempfile.TemporaryDirectory(prefix='material-permission-check-') as temporary:
        root = Path(temporary)
        os.chown(root, writer_uid, shared_gid)
        os.chmod(root, 0o2750)
        assert stat.S_IMODE(root.stat().st_mode) == 0o2750, 'isolated runner must retain CAP_FSETID to create the SGID fixture'
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
                    os.write(ready_write, b'1')
                    os.read(finish_read, 1)
            except BaseException:
                os._exit(1)
            os._exit(0)
        os.close(ready_write)
        os.close(finish_read)
        try:
            assert os.read(ready_read, 1) == b'1', 'writer failed before publishing fixture'
            assert stat.S_IMODE((root / 'snapshot.json').stat().st_mode) == 0o640
            assert (root / 'snapshot.json').stat().st_gid == shared_gid
            assert stat.S_IMODE((root / 'private-state.json').stat().st_mode) == 0o600
            assert stat.S_IMODE((root / 'collector.lock').stat().st_mode) == 0o600

            def reader() -> None:
                unprivileged(reader_uid, shared_gid)
                assert json.loads((root / 'snapshot.json').read_text()) == {'public_market_fixture': True}
                denied(lambda: (root / 'snapshot.json').open('a'))
                denied(lambda: (root / 'private-state.json').read_bytes())
                denied(lambda: (root / 'collector.lock').read_bytes())
                denied(lambda: (root / 'unexpected.json').write_text('{}'))

            def unrelated() -> None:
                unprivileged(50004, 50004)
                denied(lambda: (root / 'snapshot.json').read_bytes())

            child(reader)
            child(unrelated)
        finally:
            try:
                os.write(finish_write, b'1')
            except BrokenPipeError:
                pass
            os.close(finish_write)
            os.close(ready_read)
            _, status = os.waitpid(writer, 0)
            assert os.waitstatus_to_exitcode(status) == 0, 'writer did not release the fixture lock cleanly'
        assert not (root / 'collector.lock').exists()
    print(json.dumps({'state': 'LINUX_SGID_DISTINCT_UID_PUBLICATION_PASSED',
                      'writerAndReaderAreDifferent': True, 'readerCapabilities': 0,
                      'readerCanReadPublicOnly': True, 'readerCannotWrite': True,
                      'privateStateAndLockRemainOwnerOnly': True}))


if __name__ == '__main__':
    main()
