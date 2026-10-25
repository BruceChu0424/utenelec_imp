#!/usr/bin/python3
"""Restore a sealed paired backup into an isolated, disposable, memory-only PostgreSQL.

Runs on a trusted recovery workstation. GPG passphrase arrives on stdin; no
private key or plaintext backup is sent to either production or archive hosts.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import shutil
import stat
import resource
import fcntl
import re
import shlex
import struct
import subprocess
import sys
import tarfile
import time
import uuid
import tempfile
from contextlib import contextmanager

PHASE = "INITIALIZING"
SAFE_COUNTS = {}
MAX_METADATA_BYTES = 64 * 1024**2
MAX_PLAIN_BYTES = 2 * 1024**3
MAX_ARCHIVE_CIPHER_BYTES = 3 * 1024**3
MAX_RECOVERY_WORKSPACES = 4


def remaining_budget(deadline):
    if deadline is None:return None
    remaining = deadline - time.monotonic()
    if remaining <= 0:raise TimeoutError('Recovery job budget exceeded')
    return remaining


def phase_timeout(deadline, maximum):
    remaining = remaining_budget(deadline)
    return maximum if remaining is None else min(maximum, remaining)


class DeadlineReader:
    def __init__(self, stream, deadline):
        self.stream, self.deadline = stream, deadline

    def read(self, size=-1):
        remaining_budget(self.deadline)
        return self.stream.read(size)

    def __getattr__(self, key):
        return getattr(self.stream, key)


@contextmanager
def content_stream(value):
    if isinstance(value, (bytes, bytearray)):
        with io.BytesIO(value) as stream:
            yield stream
    elif isinstance(value, Path):
        if value.is_symlink() or not value.is_file():
            raise ValueError('Recovery input must be a regular file')
        with value.open('rb') as stream:
            yield stream
    else:
        raise ValueError('Unsupported recovery input')


def content_bytes(value, maximum=MAX_METADATA_BYTES):
    with content_stream(value) as stream:
        raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise ValueError('Recovery metadata exceeds its bounded budget')
    return raw


def content_identity(value, maximum=MAX_PLAIN_BYTES, *, deadline=None):
    size, digest = 0, hashlib.sha256()
    with content_stream(value) as stream:
        while block := stream.read(1024 * 1024):
            remaining_budget(deadline)
            size += len(block)
            if size > maximum:
                raise ValueError('Recovery file exceeds the plaintext budget')
            digest.update(block)
    return size, digest.hexdigest()


def json_lines(value, *, deadline=None):
    total = 0
    with content_stream(value) as stream:
        while line := stream.readline(1024 * 1024 + 1):
            remaining_budget(deadline)
            total += len(line)
            if total > MAX_METADATA_BYTES or len(line) > 1024 * 1024:
                raise ValueError('Recovery inventory exceeds its metadata budget')
            yield json.loads(line)


def private_directory(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:raise ValueError('Recovery spool must be absolute')
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError('Linked recovery spool is forbidden')
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Recovery spool is not private')
    return path


def process_start_token(pid):
    try:return Path('/proc').joinpath(str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
    except FileNotFoundError:return None


def remove_abandoned_recovery_spools(parent):
    """Only stale, inode-bound leases created by this recovery implementation."""
    retained = 0
    for directory in parent.iterdir():
        if not re.fullmatch(r'\.uten-(?:full-)?recovery-[a-z0-9_]+',directory.name):continue
        private_directory(directory)
        marker=directory/'.recovery-lease.json'
        if not marker.exists():
            if any(directory.iterdir()):
                raise ValueError('Unknown nonempty recovery spool prevents new allocation')
            retained += 1
            continue
        if marker.is_symlink():raise ValueError('Linked recovery lease is forbidden')
        info=marker.stat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o077:raise ValueError('Recovery lease is not private')
        lease=json.loads(content_bytes(marker,16384));current=directory.stat()
        if (set(lease)!={'format','pid','start','uid','device','inode'}
                or lease['format']!='uten-private-recovery-spool-v1' or lease['uid']!=os.geteuid()
                or (lease['device'],lease['inode'])!=(current.st_dev,current.st_ino)
                or type(lease['pid']) is not int or lease['pid']<=0
                or not isinstance(lease['start'],str) or not lease['start'].isdigit()):
            raise ValueError('Recovery lease identity is invalid')
        if process_start_token(lease['pid'])==lease['start']:
            retained += 1
            continue
        shutil.rmtree(directory)
    return retained


@contextmanager
def recovery_workspace(parent, *, required_bytes=0, prefix='.uten-recovery-'):
    parent=private_directory(parent)
    if prefix not in ('.uten-recovery-','.uten-full-recovery-'):raise ValueError('Invalid recovery namespace')
    temporary = None
    # Lock the existing directory itself, leaving no persistent lock file. The
    # count, cleanup, mkdir and lease publication form one bounded allocation.
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:fcntl.flock(parent_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Recovery spool allocation is already in progress') from None
        if remove_abandoned_recovery_spools(parent) >= MAX_RECOVERY_WORKSPACES:
            raise ValueError('Recovery workspace concurrency limit reached')
        if required_bytes<0 or shutil.disk_usage(parent).free < required_bytes+1024**3:
            raise ValueError('Recovery spool free-space reserve would be crossed')
        temporary = tempfile.TemporaryDirectory(prefix=prefix,dir=parent)
        root=Path(temporary.name);root.chmod(0o700);info=root.stat()
        marker=root/'.recovery-lease.json'
        fd=os.open(marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w',encoding='utf-8') as output:
            json.dump({'format':'uten-private-recovery-spool-v1','pid':os.getpid(),
                'start':process_start_token(os.getpid()),'uid':os.geteuid(),
                'device':info.st_dev,'inode':info.st_ino},output)
            output.flush();os.fsync(output.fileno())
    except BaseException:
        if temporary is not None:temporary.cleanup()
        raise
    finally:
        os.close(parent_fd)
    with temporary:
        yield root


def extract_verified_tar(path, directory, *, deadline=None):
    """Called only after the sealed inventory and GPG authentication are verified."""
    directory = private_directory(directory)
    if any(directory.iterdir()):raise ValueError('Recovery target must be empty')
    result, total = {}, 0
    with tarfile.open(path, mode='r|') as archive:
        for member in archive:
            remaining_budget(deadline)
            name = member.name;relative = PurePosixPath(name)
            if (member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or name in result
                    or relative.is_absolute() or str(relative) != name or '..' in relative.parts
                    or '\\' in name or ':' in name or len(name.encode('utf-8')) > 4096
                    or any(ord(char) < 32 or ord(char) == 127 for char in name)
                    or any(part.endswith(('.', ' ')) for part in relative.parts)
                    or not 0 <= member.size <= MAX_PLAIN_BYTES or len(result) >= 201024):
                raise ValueError('Invalid verified plaintext tar member')
            total += member.size
            # The export inventory is metadata in addition to the paired payload.
            if total > MAX_PLAIN_BYTES + MAX_METADATA_BYTES:
                raise ValueError('Verified plaintext tar exceeds its spool budget')
            target = directory
            for part in relative.parts[:-1]:
                target = target / part
                if not target.exists():target.mkdir(mode=0o700)
                private_directory(target)
            target = target / relative.name
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            size = 0
            with os.fdopen(fd, 'wb') as output, archive.extractfile(member) as original:
                while block := original.read(1024 * 1024):
                    remaining_budget(deadline)
                    size += len(block)
                    if size > member.size:raise ValueError('Plaintext tar member grew')
                    output.write(block)
            if size != member.size:raise ValueError('Plaintext tar member is truncated')
            result[name] = target
    return result


def run_isolated_command(arguments, data=None, timeout=180, spool_directory=None, *, deadline=None):
    """Stream file input; cap private command output before it can fill a volume."""
    maximum = 2 * 1024**2
    timeout = phase_timeout(deadline, timeout)
    def output_limit():
        inherited = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
        limit = maximum + 1 if inherited == resource.RLIM_INFINITY else min(maximum + 1,inherited)
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
    with tempfile.TemporaryFile(dir=spool_directory) as output:
        if isinstance(data, Path):
            with content_stream(data) as stream:
                result = subprocess.run(arguments, stdin=stream, stdout=output,
                    stderr=subprocess.DEVNULL, timeout=timeout, preexec_fn=output_limit)
        else:
            result = subprocess.run(arguments, input=data, stdout=output,
                stderr=subprocess.DEVNULL, timeout=timeout, preexec_fn=output_limit)
        if result.returncode:
            raise RuntimeError('Isolated restore command failed')
        output.seek(0);raw = output.read(maximum + 1)
        if len(raw) > maximum:raise ValueError('Isolated query output exceeds its bounded budget')
        return raw


def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


def parse_env(raw):
    result = {}
    for line in raw.decode("utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        tokens = shlex.split(line, comments=False)
        if len(tokens) != 1 or "=" not in tokens[0]:
            raise ValueError("Recovery environment syntax is unsupported")
        key, value = tokens[0].split("=", 1)
        if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) or key in result:
            raise ValueError("Recovery environment key is invalid")
        result[key] = value
    return result


def validate_media(contents, prefix, manifest, *, deadline=None):
    objects = list(json_lines(contents[prefix + "objects.jsonl"], deadline=deadline))
    references = list(json_lines(contents[prefix + "references.jsonl"], deadline=deadline))
    if content_identity(contents[prefix + "objects.jsonl"],deadline=deadline)[1] != manifest["objects_manifest_sha256"]:
        raise ValueError("Object inventory binding failed")
    if content_identity(contents[prefix + "references.jsonl"],deadline=deadline)[1] != manifest["references_manifest_sha256"]:
        raise ValueError("Reference inventory binding failed")
    identities = lambda values: {tuple(row.get(k) for k in ("storage_provider", "storage_key", "storage_version",
        "sha256", "size_bytes")) for row in values}
    if identities(objects) != identities(references):
        raise ValueError("Logical original references are incomplete")
    for row in objects:
        folder = "media/local/final/" if row["storage_provider"] == "local" else "media/final/"
        value = contents[prefix + folder + row["relative_path"]]
        stored_size, stored_digest = content_identity(value,deadline=deadline)
        if stored_digest != row["storage_sha256"] or stored_size != row["stored_size_bytes"]:
            raise ValueError("Stored original binding failed")
        original_size, original_digest = 0, hashlib.sha256()
        with content_stream(value) as stream:
            decoded = stream
            expected = None
            if row["storage_provider"] == "internal":
                header = stream.read(57)
                if len(header) != 57:raise ValueError('Internal original header is truncated')
                magic, codec, declared_size, encoded_size, expected = struct.unpack('>8sBqq32s', header)
                if (magic != b'UTENINT\x01' or codec not in (0, 1) or encoded_size != stored_size - 57
                        or not 0 <= declared_size <= MAX_PLAIN_BYTES):
                    raise ValueError('Internal original envelope is invalid')
                if codec:decoded = gzip.GzipFile(fileobj=stream)
            try:
                while block := decoded.read(1024 * 1024):
                    remaining_budget(deadline)
                    original_size += len(block)
                    if original_size > row['size_bytes'] or original_size > MAX_PLAIN_BYTES:
                        raise ValueError('Decoded original exceeds its bounded size')
                    original_digest.update(block)
            finally:
                if decoded is not stream:decoded.close()
        if expected is not None and (original_size != declared_size or original_digest.digest() != expected):
            raise ValueError('Decoded original binding failed')
        if original_size != row["size_bytes"] or original_digest.hexdigest() != row["sha256"]:
            raise ValueError("Original plaintext binding failed")
    return {"mediaObjectsVerified": len(objects), "logicalReferencesVerified": len(references)}


def restore_contents(contents, source_set_id, docker, candidate_options=None, *, spool_directory=None, deadline=None):
    """Consume verified bytes or private disk files without buffering the dump."""
    global PHASE, SAFE_COUNTS
    started = time.monotonic()
    PHASE = "DATABASE_ARCHIVE_BINDING"
    prefix = "paired/" + source_set_id + "/"
    manifest = json.loads(content_bytes(contents[prefix + "manifest.json"]))
    dump = contents[prefix + "database.dump"]
    with content_stream(dump) as stream:
        magic = stream.read(5)
    if magic != b"PGDMP" or content_identity(dump,deadline=deadline)[1] != manifest["database_dump_sha256"]:
        raise ValueError("PostgreSQL archive binding failed")
    PHASE = "MEDIA_REFERENCE_BINDING"
    media = validate_media(contents, prefix, manifest,deadline=deadline)
    PHASE = "RECOVERY_ENVIRONMENT_PARSING"
    environment = parse_env(content_bytes(contents["recovery/etc/uten-imp/server.env"]))
    current_version = environment.get("UTEN_PGP_KEY_VERSION", "1")
    keyring = {match.group(1): value for key, value in environment.items()
               if (match := re.fullmatch(r"UTEN_CRYPTO_PGPLEGACYKEYS_([A-Za-z0-9_.-]+)", key))}
    keyring[current_version] = environment.get("UTEN_PGP_MASTER_KEY") or environment.get("UTEN_CRYPTO_PGPMASTERKEY", "")
    hmac_key = environment.get("UTEN_HMAC_KEY") or environment.get("UTEN_CRYPTO_HMACKEY", "")
    unversioned = environment.get("UTEN_PGP_UNVERSIONED_KEY_VERSION", "1")
    PHASE = "CORE_KEY_MATERIAL_CHECK"
    if not all(keyring.values()) or not hmac_key:
        raise ValueError("Core recovery key material is missing")
    name = "uten-drill-" + uuid.uuid4().hex[:12]
    common = [str(docker)]
    def command(arguments, data=None, timeout=180):
        # Error output can contain database values: discard it, and bound the
        # deliberate query results independently of the size of the dump.
        return run_isolated_command(common + arguments, data, timeout, spool_directory,deadline=deadline)
    try:
        PHASE = "ISOLATED_CONTAINER_START"
        command(["run", "--pull", "never", "--detach", "--rm", "--name", name,
            "--network", "none", "--read-only", "--user", "999:999", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--memory", "3g", "--pids-limit", "100",
            "--tmpfs", "/var/lib/postgresql/data:rw,nosuid,nodev,size=2048m,uid=999,gid=999,mode=0700",
            "--tmpfs", "/var/run/postgresql:rw,nosuid,nodev,size=16m,uid=999,gid=999,mode=0700",
            "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m,uid=999,gid=999,mode=0700",
            "--env", "POSTGRES_HOST_AUTH_METHOD=trust", "--env", "POSTGRES_DB=drill", "postgres:16",
            "-c", "listen_addresses=", "-c", "shared_buffers=64MB", "-c", "max_connections=20",
            "-c", "max_wal_size=256MB", "-c", "log_statement=none", "-c", "log_min_error_statement=panic"])
        startup_deadline = time.monotonic() + phase_timeout(deadline,90)
        while time.monotonic() < startup_deadline:
            result = subprocess.run(common + ["exec", name, "pg_isready", "-q", "-U", "postgres", "-d", "drill"],
                                    capture_output=True, timeout=phase_timeout(deadline,10))
            if result.returncode == 0:
                break
            time.sleep(.5)
        else:
            raise TimeoutError("Isolated database startup failed")
        psql = ["exec", "--interactive", name, "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                "-U", "postgres", "-d", "drill"]
        PHASE = "RESTORE_ROLES"
        command(psql, b"CREATE ROLE uten NOLOGIN; CREATE ROLE uten_migrator NOLOGIN; CREATE ROLE uten_repl NOLOGIN;\n")
        PHASE = "ACTUAL_DATABASE_RESTORE"
        command(["exec", "--interactive", name, "pg_restore", "--exit-on-error", "--no-owner", "--no-privileges",
                 "--username", "postgres", "--dbname", "drill"], dump, timeout=600)
        PHASE = "RESTORED_DATABASE_ORIGINAL_REFERENCES"
        references = list(json_lines(contents[prefix + "references.jsonl"],deadline=deadline))
        allowed_tables = {"attachments", "goods_cost_imports", "sales_quote_template_candidates",
            "sales_quote_template_versions", "sales_quote_template_candidate_history", "ai_input_originals"}
        for row in references:
            table = row["source_table"]
            if table not in allowed_tables:
                raise ValueError("Unreviewed original reference producer")
            identifier = row["id"]
            if table == "sales_quote_template_versions":
                template, version = identifier.split(":")
                uuid.UUID(template)
                if not re.fullmatch(r"[1-9][0-9]*", version):raise ValueError("Invalid original version identity")
                predicate = "template_id=" + sql_literal(template) + "::uuid AND version=" + version
            elif table == "sales_quote_template_candidate_history":
                if not re.fullmatch(r"[1-9][0-9]*", identifier):raise ValueError("Invalid original history identity")
                predicate = "id=" + identifier
            else:
                uuid.UUID(identifier)
                column = "job_id" if table in ("sales_quote_template_candidates", "ai_input_originals") else "id"
                predicate = column + "=" + sql_literal(identifier) + "::uuid"
            size, digest = ("size_bytes", "sha256") if table == "attachments" else ("storage_size", "storage_sha256")
            if table == "sales_quote_template_candidate_history":
                size, digest = "(payload->>'storage_size')::bigint", "payload->>'storage_sha256'"
            query = "SELECT json_build_object('storage_provider',storage_provider,'storage_key',storage_key," \
                "'storage_version',storage_version,'size_bytes'," + size + ",'sha256'," + digest + ") FROM public." + table + " WHERE " + predicate + ";"
            raw = command(psql, query.encode()).decode().strip()
            actual = json.loads(raw)
            if any(actual[key] != row[key] for key in ("storage_provider", "storage_key", "storage_version", "size_bytes", "sha256")):
                raise ValueError("Restored database does not bind its original bytes")
        media["restoredDatabaseOriginalBindingsVerified"] = len(references)
        # Private keys/ciphertexts and decrypted values never leave this isolated DB process.
        verify_sql = """
CREATE TEMP TABLE dr_keyring(version text PRIMARY KEY, secret text NOT NULL);
INSERT INTO dr_keyring VALUES KEY_VALUES;
CREATE TEMP TABLE dr_crypto_results(verified bigint, failed bigint, hmac_verified bigint, hmac_failed bigint);
DO $dr$
DECLARE c record; r record; value text; body text; key_version text; secret text; plain text;
 good bigint := 0; bad bigint := 0; hg bigint := 0; hb bigint := 0;
BEGIN
 FOR c IN SELECT table_name,column_name FROM information_schema.columns
   WHERE table_schema='public' AND data_type IN ('text','character varying') AND column_name LIKE '%\\_enc' ESCAPE '\\'
 LOOP
   FOR r IN EXECUTE format('SELECT %I AS cipher FROM public.%I WHERE %I IS NOT NULL AND btrim(%I) <> ''''%s',
     c.column_name,c.table_name,c.column_name,c.column_name,
     CASE WHEN c.table_name='profile_change_requests' THEN ' AND value_encoding <> ''PLAIN''' ELSE '' END)
   LOOP
    value := r.cipher;
    IF value ~ '^[A-Za-z0-9_.-]+:' THEN key_version := split_part(value,':',1); body := substr(value,strpos(value,':')+1);
    ELSE key_version := UNVERSIONED; body := value; END IF;
    SELECT k.secret INTO secret FROM dr_keyring k WHERE k.version=key_version;
    BEGIN
     IF secret IS NULL THEN RAISE EXCEPTION 'Missing version'; END IF;
     plain := pgp_sym_decrypt(decode(body,'base64'),secret); good := good+1;
    EXCEPTION WHEN OTHERS THEN bad := bad+1;
    END;
   END LOOP;
 END LOOP;
 FOR r IN SELECT id_card_enc AS cipher,id_card_hash AS digest FROM employee_sensitive
   WHERE id_card_enc IS NOT NULL AND id_card_hash IS NOT NULL
   UNION ALL SELECT phone_enc,phone_hash FROM employee_sensitive WHERE phone_enc IS NOT NULL AND phone_hash IS NOT NULL
 LOOP
  value := r.cipher;
  IF value ~ '^[A-Za-z0-9_.-]+:' THEN key_version := split_part(value,':',1); body := substr(value,strpos(value,':')+1);
  ELSE key_version := UNVERSIONED; body := value; END IF;
  SELECT k.secret INTO secret FROM dr_keyring k WHERE k.version=key_version;
  BEGIN
   plain := pgp_sym_decrypt(decode(body,'base64'),secret);
   IF encode(hmac(plain,HMAC_KEY,'sha256'),'hex')=r.digest THEN hg:=hg+1; ELSE hb:=hb+1; END IF;
  EXCEPTION WHEN OTHERS THEN hb:=hb+1;
  END;
 END LOOP;
 INSERT INTO dr_crypto_results VALUES(good,bad,hg,hb);
END $dr$;
SELECT json_build_object('tables',(SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'),
 'flywayVersion',(SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1),
 'piiVerified',verified,'piiFailed',failed,'hmacIndexesVerified',hmac_verified,'hmacIndexesFailed',hmac_failed) FROM dr_crypto_results;
"""
        verify_sql = verify_sql.replace("KEY_VALUES", ",".join("(" + sql_literal(key) + "," + sql_literal(value) + ")"
                                                                for key, value in keyring.items()))
        verify_sql = verify_sql.replace("UNVERSIONED", sql_literal(unversioned)).replace("HMAC_KEY", sql_literal(hmac_key))
        PHASE = "PII_AND_HMAC_VALIDATION"
        stats = json.loads(command(psql, verify_sql.encode(), timeout=120).decode().strip().splitlines()[-1])
        SAFE_COUNTS = stats
        if stats["piiFailed"] or stats["piiVerified"] < 1:
            raise ValueError("Restored PGP cryptography verification failed")
        hmac_verified = stats["hmacIndexesFailed"] == 0
        report = {"state": ("ISOLATED_DATABASE_AND_ORIGINALS_RESTORED" if hmac_verified else
                          "ISOLATED_RESTORE_WITH_HISTORICAL_HMAC_GAPS"), "sourceSetId": source_set_id,
            "databaseRestored": True, "attachmentsVerified": True, "corePgpVerified": True,
            "corePgpAndHmacVerified": hmac_verified, "keysVerified": hmac_verified,
            "isolated": True, "sideEffectsDisabled": True,
            "plaintextWrittenOutsideTmpfs": any(isinstance(value, Path) for value in contents.values()),
            "durationSeconds": round(time.monotonic() - started, 3), **media, **stats,
            "knownAncillaryCredentialIssuesCleared": False,
            "reasonCode": "CORE_PGP_HMAC_VERIFIED" if hmac_verified else "HISTORICAL_HMAC_MISMATCH"}
        report['sourceManifestSha256']=content_identity(contents[prefix+'manifest.json'],deadline=deadline)[1]
        inventory=[]
        for path,value in sorted(contents.items()):
            size,digest=content_identity(value,deadline=deadline);inventory.append({'path':path,'size':size,'sha256':digest})
        report['pairedRecoveryInputBindingSha256']=hashlib.sha256(json.dumps(inventory,sort_keys=True,
            separators=(',',':')).encode()).hexdigest()
        if candidate_options is not None:
            PHASE = "ISOLATED_HISTORICAL_INTEGRITY_CANDIDATE"
            spec=importlib.util.spec_from_file_location('uten_clone_integrity_candidate',
                Path(__file__).with_name('clone_integrity_candidate.py'))
            candidate=importlib.util.module_from_spec(spec);spec.loader.exec_module(candidate)
            inspection=json.loads(command(['inspect',name]))[0]
            def run_sql(query):
                # The optional candidate performs one bounded Node step (30s,
                # plus at most 5s for wslpath) after collecting its SQL inputs.
                # Preserve that remaining budget without changing its module.
                remaining = remaining_budget(deadline)
                if remaining is not None and remaining <= 35:
                    raise TimeoutError('Insufficient integrity-candidate budget')
                timeout = 120 if remaining is None else min(120, remaining - 35)
                return command(psql,query.encode(),timeout=timeout)
            def seal_proposal(raw):
                output=candidate_options['preimage']
                result=subprocess.run(['/usr/bin/gpg','--no-options','--batch','--no-tty','--homedir',
                    str(candidate_options['gpg_home']),'--trust-model','always','--recipient',
                    candidate_options['recipient'],'--compress-algo','zlib','--encrypt'],
                    input=raw,capture_output=True,timeout=phase_timeout(deadline,60))
                if result.returncode or not result.stdout:raise ValueError('Candidate preimage encryption failed')
                with output.open('xb') as stream:
                    stream.write(result.stdout);stream.flush();os.fsync(stream.fileno())
                return hashlib.sha256(result.stdout).hexdigest()
            report['integrityCandidate']=candidate.exercise(run_sql,inspection,name,environment,
                candidate_options['legacy_hmac'],candidate_options['node'],
                content_identity(contents['recovery/etc/uten-imp/server.env'],deadline=deadline)[1],seal_proposal,
                ai_only=candidate_options.get('ai_only',False))
        clone=json.loads(command(psql,b"SELECT json_build_object('cloneDatabaseSystemIdentifier',"
            b"(pg_control_system()).system_identifier::text,'cloneRestoredLsn',pg_current_wal_lsn()::text);").decode().strip())
        report.update(clone)
        report['cloneIdentityRepresentsSourceWalPosition']=False
        return report
    finally:
        subprocess.run(common + ["rm", "--force", name], capture_output=True, timeout=30)


def main():
    global PHASE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--source-receipt", required=True, type=Path)
    parser.add_argument("--gpg-home", required=True, type=Path)
    parser.add_argument("--docker", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument('--spool-directory', required=True, type=Path,
                        help='Existing private recovery-workstation directory with at least 6GiB available')
    parser.add_argument('--budget-seconds',type=int,default=3600,
                        help='One total 60..3600 second recovery budget with 30 seconds reserved for cleanup')
    args = parser.parse_args()
    if not 60 <= args.budget_seconds <= 3600:raise ValueError('Recovery budget must be 60..3600 seconds')
    deadline = time.monotonic() + args.budget_seconds - 30
    os.umask(0o077)
    secret = sys.stdin.buffer.read(256).strip()
    PHASE = "CIPHERTEXT_BINDING"
    source_receipt = json.loads(args.source_receipt.read_text())
    cipher_size, cipher_digest = content_identity(args.archive, MAX_ARCHIVE_CIPHER_BYTES,deadline=deadline)
    if cipher_digest != source_receipt["ciphertextSha256"] or cipher_size != source_receipt['ciphertextBytes']:
        raise ValueError("Ciphertext receipt mismatch")
    PHASE = "AUTHENTICATED_DECRYPTION"
    parent = private_directory(args.spool_directory)
    with recovery_workspace(parent,required_bytes=MAX_ARCHIVE_CIPHER_BYTES+MAX_PLAIN_BYTES,
                            prefix='.uten-full-recovery-') as workspace:
        plaintext_tar = workspace / 'authenticated.tar'
        key_fd = os.memfd_create("uten-drill-passphrase", os.MFD_CLOEXEC)
        try:
            os.write(key_fd, secret + b"\n"); os.lseek(key_fd, 0, os.SEEK_SET)
            with plaintext_tar.open('xb') as output:
                result = subprocess.run(["/usr/bin/gpg", "--no-options", "--batch", "--no-tty", "--homedir", str(args.gpg_home),
                    "--pinentry-mode", "loopback", "--passphrase-fd", str(key_fd), '--max-output', str(MAX_ARCHIVE_CIPHER_BYTES),
                    "--decrypt", str(args.archive)], stdout=output, stderr=subprocess.DEVNULL,
                    pass_fds=(key_fd,), timeout=phase_timeout(deadline,120))
            if result.returncode or plaintext_tar.stat().st_size > MAX_ARCHIVE_CIPHER_BYTES:
                raise ValueError("Authenticated archive decryption failed")
        finally:
            os.close(key_fd)
        helper = Path(__file__).resolve().parents[1] / "postgres/backup/sealed_paired_export.py"
        spec = importlib.util.spec_from_file_location("uten_drill_sealed_verify", helper)
        sealed = importlib.util.module_from_spec(spec); spec.loader.exec_module(sealed)
        PHASE = "DECRYPTED_INVENTORY_VALIDATION"
        with plaintext_tar.open('rb') as stream:sealed.verify_plaintext_tar(DeadlineReader(stream,deadline), source_receipt)
        plain_root = workspace / 'plain';plain_root.mkdir(mode=0o700)
        contents = extract_verified_tar(plaintext_tar, plain_root,deadline=deadline)
        report = restore_contents(contents, source_receipt["sourceSetId"], args.docker,
                                  spool_directory=workspace,deadline=deadline)
        report['restoreInputMode'] = 'PRIVATE_DISK'
        report.update(recoveryBudgetSeconds=args.budget_seconds,cleanupReservedSeconds=30)
    report["ciphertextSha256"] = source_receipt["ciphertextSha256"]
    with args.report.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2); stream.write("\n")
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"state": "RESTORE_DRILL_FAILED", "errorType": type(error).__name__,
                          "phase": PHASE, "counts": SAFE_COUNTS}), file=sys.stderr)
        raise SystemExit(1)
