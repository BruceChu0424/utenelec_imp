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
import re
import shlex
import struct
import subprocess
import sys
import tarfile
import time
import uuid

PHASE = "INITIALIZING"
SAFE_COUNTS = {}


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


def validate_media(contents, prefix, manifest):
    objects = [json.loads(line) for line in contents[prefix + "objects.jsonl"].splitlines()]
    references = [json.loads(line) for line in contents[prefix + "references.jsonl"].splitlines()]
    if hashlib.sha256(contents[prefix + "objects.jsonl"]).hexdigest() != manifest["objects_manifest_sha256"]:
        raise ValueError("Object inventory binding failed")
    if hashlib.sha256(contents[prefix + "references.jsonl"]).hexdigest() != manifest["references_manifest_sha256"]:
        raise ValueError("Reference inventory binding failed")
    identities = lambda values: {tuple(row.get(k) for k in ("storage_provider", "storage_key", "storage_version",
        "sha256", "size_bytes")) for row in values}
    if identities(objects) != identities(references):
        raise ValueError("Logical original references are incomplete")
    for row in objects:
        folder = "media/local/final/" if row["storage_provider"] == "local" else "media/final/"
        raw = contents[prefix + folder + row["relative_path"]]
        if hashlib.sha256(raw).hexdigest() != row["storage_sha256"] or len(raw) != row["stored_size_bytes"]:
            raise ValueError("Stored original binding failed")
        if row["storage_provider"] == "internal":
            magic, codec, original_size, stored_size, expected = struct.unpack(">8sBqq32s", raw[:57])
            if magic != b"UTENINT\x01" or codec not in (0, 1) or stored_size != len(raw) - 57:
                raise ValueError("Internal original envelope is invalid")
            original = gzip.decompress(raw[57:]) if codec else raw[57:]
            if len(original) != original_size or hashlib.sha256(original).digest() != expected:
                raise ValueError("Decoded original binding failed")
        else:
            original = raw
        if len(original) != row["size_bytes"] or hashlib.sha256(original).hexdigest() != row["sha256"]:
            raise ValueError("Original plaintext binding failed")
    return {"mediaObjectsVerified": len(objects), "logicalReferencesVerified": len(references)}


def restore_contents(contents, source_set_id, docker, candidate_options=None):
    """All plaintext remains in memory, stdin pipes, and disposable container tmpfs."""
    global PHASE, SAFE_COUNTS
    started = time.monotonic()
    PHASE = "DATABASE_ARCHIVE_BINDING"
    prefix = "paired/" + source_set_id + "/"
    manifest = json.loads(contents[prefix + "manifest.json"])
    dump = contents[prefix + "database.dump"]
    if not dump.startswith(b"PGDMP") or hashlib.sha256(dump).hexdigest() != manifest["database_dump_sha256"]:
        raise ValueError("PostgreSQL archive binding failed")
    PHASE = "MEDIA_REFERENCE_BINDING"
    media = validate_media(contents, prefix, manifest)
    PHASE = "RECOVERY_ENVIRONMENT_PARSING"
    environment = parse_env(contents["recovery/etc/uten-imp/server.env"])
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
        result = subprocess.run(common + arguments, input=data, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError("Isolated restore command failed")
        return result.stdout
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
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            result = subprocess.run(common + ["exec", name, "pg_isready", "-q", "-U", "postgres", "-d", "drill"],
                                    capture_output=True, timeout=10)
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
        references = [json.loads(line) for line in contents[prefix + "references.jsonl"].splitlines()]
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
            "isolated": True, "sideEffectsDisabled": True, "plaintextWrittenOutsideTmpfs": False,
            "durationSeconds": round(time.monotonic() - started, 3), **media, **stats,
            "knownAncillaryCredentialIssuesCleared": False,
            "reasonCode": "CORE_PGP_HMAC_VERIFIED" if hmac_verified else "HISTORICAL_HMAC_MISMATCH"}
        report['sourceManifestSha256']=hashlib.sha256(contents[prefix+'manifest.json']).hexdigest()
        inventory=[{'path':path,'size':len(value),'sha256':hashlib.sha256(value).hexdigest()}
                   for path,value in sorted(contents.items())]
        report['pairedRecoveryInputBindingSha256']=hashlib.sha256(json.dumps(inventory,sort_keys=True,
            separators=(',',':')).encode()).hexdigest()
        if candidate_options is not None:
            PHASE = "ISOLATED_HISTORICAL_INTEGRITY_CANDIDATE"
            spec=importlib.util.spec_from_file_location('uten_clone_integrity_candidate',
                Path(__file__).with_name('clone_integrity_candidate.py'))
            candidate=importlib.util.module_from_spec(spec);spec.loader.exec_module(candidate)
            inspection=json.loads(command(['inspect',name]))[0]
            def run_sql(query):return command(psql,query.encode(),timeout=120)
            def seal_proposal(raw):
                output=candidate_options['preimage']
                result=subprocess.run(['/usr/bin/gpg','--no-options','--batch','--no-tty','--homedir',
                    str(candidate_options['gpg_home']),'--trust-model','always','--recipient',
                    candidate_options['recipient'],'--compress-algo','zlib','--encrypt'],
                    input=raw,capture_output=True,timeout=60)
                if result.returncode or not result.stdout:raise ValueError('Candidate preimage encryption failed')
                with output.open('xb') as stream:
                    stream.write(result.stdout);stream.flush();os.fsync(stream.fileno())
                return hashlib.sha256(result.stdout).hexdigest()
            report['integrityCandidate']=candidate.exercise(run_sql,inspection,name,environment,
                candidate_options['legacy_hmac'],candidate_options['node'],
                hashlib.sha256(contents['recovery/etc/uten-imp/server.env']).hexdigest(),seal_proposal,
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
    args = parser.parse_args()
    os.umask(0o077)
    secret = sys.stdin.buffer.read(256).strip()
    PHASE = "CIPHERTEXT_BINDING"
    source_receipt = json.loads(args.source_receipt.read_text())
    if hashlib.sha256(args.archive.read_bytes()).hexdigest() != source_receipt["ciphertextSha256"]:
        raise ValueError("Ciphertext receipt mismatch")
    PHASE = "AUTHENTICATED_DECRYPTION"
    key_fd = os.memfd_create("uten-drill-passphrase", os.MFD_CLOEXEC)
    try:
        os.write(key_fd, secret + b"\n"); os.lseek(key_fd, 0, os.SEEK_SET)
        result = subprocess.run(["/usr/bin/gpg", "--no-options", "--batch", "--no-tty", "--homedir", str(args.gpg_home),
            "--pinentry-mode", "loopback", "--passphrase-fd", str(key_fd), "--decrypt", str(args.archive)],
            capture_output=True, pass_fds=(key_fd,), timeout=120)
        if result.returncode or len(result.stdout) > 512 * 1024**2:
            raise ValueError("Authenticated archive decryption failed")
    finally:
        os.close(key_fd)
    helper = Path(__file__).resolve().parents[1] / "postgres/backup/sealed_paired_export.py"
    spec = importlib.util.spec_from_file_location("uten_drill_sealed_verify", helper)
    sealed = importlib.util.module_from_spec(spec); spec.loader.exec_module(sealed)
    PHASE = "DECRYPTED_INVENTORY_VALIDATION"
    sealed.verify_plaintext_tar(io.BytesIO(result.stdout), source_receipt)
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
        contents = {member.name: archive.extractfile(member).read() for member in archive.getmembers()}
    report = restore_contents(contents, source_receipt["sourceSetId"], args.docker)
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
