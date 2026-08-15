#!/usr/bin/env python3
"""Read the one fixed production database identity for activation recovery.

This helper has no operator-supplied path, command, SQL, database or role.  It
must be installed root-owned and is executed as the local ``postgres`` OS
account through the recovery updater.  PostgreSQL peer authentication therefore
keeps credentials out of arguments, environment variables, receipts and logs.
"""

from __future__ import annotations

import json
import os
import pwd
import re
import subprocess
import sys
from typing import Any


MAX_OUTPUT_BYTES = 4 * 1024 * 1024
PSQL = "/usr/bin/psql"
SYSTEMCTL = "/usr/bin/systemctl"
SS = "/usr/bin/ss"
QUERY = r"""
SELECT json_build_object(
  'schemaVersion', 1,
  'databaseName', current_database(),
  'schemaName', 'public',
  'serverPort', current_setting('port')::integer,
  'serverVersionNum', current_setting('server_version_num')::integer,
  'dataDirectory', current_setting('data_directory'),
  'configFile', current_setting('config_file'),
  'hbaFile', current_setting('hba_file'),
  'listenAddresses', current_setting('listen_addresses'),
  'archiveMode', current_setting('archive_mode'),
  'archiveCommand', current_setting('archive_command'),
  'postmasterPid', split_part(pg_read_file('postmaster.pid', 0, 64), E'\n', 1)::integer,
  'inRecovery', pg_is_in_recovery(),
  'systemIdentifier', (SELECT system_identifier::text FROM pg_control_system()),
  'timeline', (SELECT timeline_id FROM pg_control_checkpoint()),
  'roleAclContract', json_build_object(
    'applicationRole', (SELECT rolname FROM pg_roles WHERE rolname = 'uten'),
    'applicationCanCreateDatabase', (SELECT rolcreatedb FROM pg_roles WHERE rolname = 'uten'),
    'applicationCanCreateRole', (SELECT rolcreaterole FROM pg_roles WHERE rolname = 'uten'),
    'applicationCanLogin', (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'uten'),
    'applicationCanReplicate', (SELECT rolreplication FROM pg_roles WHERE rolname = 'uten'),
    'applicationBypassRls', (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'uten'),
    'applicationSuperuser', (SELECT rolsuper FROM pg_roles WHERE rolname = 'uten'),
    'applicationMemberships', (
      SELECT COALESCE(json_agg(parent.rolname ORDER BY parent.rolname), '[]'::json)
      FROM pg_auth_members membership
      JOIN pg_roles member ON member.oid = membership.member
      JOIN pg_roles parent ON parent.oid = membership.roleid
      WHERE member.rolname = 'uten'
    ),
    'migratorRole', (SELECT rolname FROM pg_roles WHERE rolname = 'uten_migrator'),
    'migratorCanCreateDatabase', (SELECT rolcreatedb FROM pg_roles WHERE rolname = 'uten_migrator'),
    'migratorCanCreateRole', (SELECT rolcreaterole FROM pg_roles WHERE rolname = 'uten_migrator'),
    'migratorCanLogin', (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'uten_migrator'),
    'migratorCanReplicate', (SELECT rolreplication FROM pg_roles WHERE rolname = 'uten_migrator'),
    'migratorBypassRls', (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'uten_migrator'),
    'migratorSuperuser', (SELECT rolsuper FROM pg_roles WHERE rolname = 'uten_migrator'),
    'migratorMemberships', (
      SELECT COALESCE(json_agg(parent.rolname ORDER BY parent.rolname), '[]'::json)
      FROM pg_auth_members membership
      JOIN pg_roles member ON member.oid = membership.member
      JOIN pg_roles parent ON parent.oid = membership.roleid
      WHERE member.rolname = 'uten_migrator'
    ),
    'ownerRole', (SELECT rolname FROM pg_roles WHERE rolname = 'uten_owner'),
    'ownerCanLogin', (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'uten_owner'),
    'ownerCanCreateDatabase', (SELECT rolcreatedb FROM pg_roles WHERE rolname = 'uten_owner'),
    'ownerCanCreateRole', (SELECT rolcreaterole FROM pg_roles WHERE rolname = 'uten_owner'),
    'ownerCanReplicate', (SELECT rolreplication FROM pg_roles WHERE rolname = 'uten_owner'),
    'ownerBypassRls', (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'uten_owner'),
    'ownerSuperuser', (SELECT rolsuper FROM pg_roles WHERE rolname = 'uten_owner'),
    'ownerMemberships', (
      SELECT COALESCE(json_agg(parent.rolname ORDER BY parent.rolname), '[]'::json)
      FROM pg_auth_members membership
      JOIN pg_roles member ON member.oid = membership.member
      JOIN pg_roles parent ON parent.oid = membership.roleid
      WHERE member.rolname = 'uten_owner'
    ),
    'ownerGrantedToMembers', (
      SELECT COALESCE(json_agg(member.rolname ORDER BY member.rolname), '[]'::json)
      FROM pg_auth_members membership
      JOIN pg_roles parent ON parent.oid = membership.roleid
      JOIN pg_roles member ON member.oid = membership.member
      WHERE parent.rolname = 'uten_owner'
    ),
    'migratorGrantedToMembers', (
      SELECT COALESCE(json_agg(member.rolname ORDER BY member.rolname), '[]'::json)
      FROM pg_auth_members membership
      JOIN pg_roles parent ON parent.oid = membership.roleid
      JOIN pg_roles member ON member.oid = membership.member
      WHERE parent.rolname = 'uten_migrator'
    ),
    'applicationGrantedToMembers', (
      SELECT COALESCE(json_agg(member.rolname ORDER BY member.rolname), '[]'::json)
      FROM pg_auth_members membership
      JOIN pg_roles parent ON parent.oid = membership.roleid
      JOIN pg_roles member ON member.oid = membership.member
      WHERE parent.rolname = 'uten'
    ),
    'unexpectedNonBuiltinRoles', (
      SELECT COALESCE(json_agg(role.rolname ORDER BY role.rolname), '[]'::json)
      FROM pg_roles role
      WHERE role.rolname !~ '^pg_'
        AND role.rolname NOT IN ('postgres', 'uten_owner', 'uten_migrator', 'uten')
    ),
    'unexpectedPrivilegedRoles', (
      SELECT COALESCE(json_agg(role.rolname ORDER BY role.rolname), '[]'::json)
      FROM pg_roles role
      WHERE role.rolname NOT IN ('postgres', 'uten_owner', 'uten_migrator', 'uten')
        AND (
          role.rolsuper OR role.rolcreatedb OR role.rolcreaterole
          OR role.rolreplication OR role.rolbypassrls OR role.rolcanlogin
        )
    ),
    'databaseOwner', (SELECT datdba::regrole::text FROM pg_database WHERE datname = current_database()),
    'schemaOwner', (SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = 'public'),
    'publicDatabaseConnect', COALESCE((
      SELECT bool_or(acl.privilege_type = 'CONNECT')
      FROM pg_database database
      CROSS JOIN LATERAL aclexplode(COALESCE(database.datacl, acldefault('d', database.datdba))) acl
      WHERE database.datname = current_database() AND acl.grantee = 0
    ), false),
    'publicDatabaseCreate', COALESCE((
      SELECT bool_or(acl.privilege_type = 'CREATE')
      FROM pg_database database
      CROSS JOIN LATERAL aclexplode(COALESCE(database.datacl, acldefault('d', database.datdba))) acl
      WHERE database.datname = current_database() AND acl.grantee = 0
    ), false),
    'publicDatabaseTemporary', COALESCE((
      SELECT bool_or(acl.privilege_type = 'TEMPORARY')
      FROM pg_database database
      CROSS JOIN LATERAL aclexplode(COALESCE(database.datacl, acldefault('d', database.datdba))) acl
      WHERE database.datname = current_database() AND acl.grantee = 0
    ), false),
    'applicationDatabaseConnect', has_database_privilege('uten', current_database(), 'CONNECT'),
    'applicationDatabaseCreate', has_database_privilege('uten', current_database(), 'CREATE'),
    'applicationDatabaseTemporary', has_database_privilege('uten', current_database(), 'TEMPORARY'),
    'migratorDatabaseConnect', has_database_privilege('uten_migrator', current_database(), 'CONNECT'),
    'migratorDatabaseCreate', has_database_privilege('uten_migrator', current_database(), 'CREATE'),
    'migratorDatabaseTemporary', has_database_privilege('uten_migrator', current_database(), 'TEMPORARY'),
    'noUnexpectedDatabaseAcl', NOT EXISTS (
      SELECT 1
      FROM pg_database database
      CROSS JOIN LATERAL aclexplode(COALESCE(database.datacl, acldefault('d', database.datdba))) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE database.datname = current_database()
        AND acl.grantee <> database.datdba
        AND NOT (
          grantee.rolname IN ('uten', 'uten_migrator')
          AND acl.privilege_type = 'CONNECT'
          AND acl.is_grantable IS FALSE
        )
    ),
    'publicSchemaUsage', COALESCE((
      SELECT bool_or(acl.privilege_type = 'USAGE')
      FROM pg_namespace namespace
      CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl, acldefault('n', namespace.nspowner))) acl
      WHERE namespace.nspname = 'public' AND acl.grantee = 0
    ), false),
    'applicationSchemaCreate', has_schema_privilege('uten', 'public', 'CREATE'),
    'applicationSchemaUsage', has_schema_privilege('uten', 'public', 'USAGE'),
    'publicSchemaCreate', COALESCE((
      SELECT bool_or(acl.privilege_type = 'CREATE')
      FROM pg_namespace namespace
      CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl, acldefault('n', namespace.nspowner))) acl
      WHERE namespace.nspname = 'public' AND acl.grantee = 0
    ), false),
    'migratorSchemaCreate', has_schema_privilege('uten_migrator', 'public', 'CREATE'),
    'migratorSchemaUsage', has_schema_privilege('uten_migrator', 'public', 'USAGE'),
    'noUnexpectedSchemaAcl', NOT EXISTS (
      SELECT 1
      FROM pg_namespace namespace
      CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl, acldefault('n', namespace.nspowner))) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE namespace.nspname = 'public'
        AND acl.grantee <> namespace.nspowner
        AND NOT (
          grantee.rolname = 'uten'
          AND acl.privilege_type = 'USAGE'
          AND acl.is_grantable IS FALSE
        )
    ),
    'migratorMemberOfOwner', pg_has_role('uten_migrator', 'uten_owner', 'MEMBER'),
    'allPublicObjectsOwnedByOwner', NOT EXISTS (
      SELECT 1 FROM pg_class object
      JOIN pg_namespace namespace ON namespace.oid = object.relnamespace
      WHERE namespace.nspname = 'public'
        AND object.relkind IN ('r','p','v','m','S','f')
        AND object.relowner <> 'uten_owner'::regrole
    ) AND NOT EXISTS (
      SELECT 1 FROM pg_proc object
      JOIN pg_namespace namespace ON namespace.oid = object.pronamespace
      WHERE namespace.nspname = 'public'
        AND object.proowner <> 'uten_owner'::regrole
    ),
    'applicationOwnsNoPublicObject', NOT EXISTS (
      SELECT 1 FROM pg_class object
      JOIN pg_namespace namespace ON namespace.oid = object.relnamespace
      WHERE namespace.nspname = 'public' AND object.relowner = 'uten'::regrole
    ) AND NOT EXISTS (
      SELECT 1 FROM pg_proc object
      JOIN pg_namespace namespace ON namespace.oid = object.pronamespace
      WHERE namespace.nspname = 'public' AND object.proowner = 'uten'::regrole
    ),
    'allPublicTypesOwnedByOwner', NOT EXISTS (
      SELECT 1 FROM pg_type object
      JOIN pg_namespace namespace ON namespace.oid = object.typnamespace
      WHERE namespace.nspname = 'public'
        AND object.typisdefined
        AND object.typowner <> 'uten_owner'::regrole
    ),
    'applicationOwnsNoPublicType', NOT EXISTS (
      SELECT 1 FROM pg_type object
      JOIN pg_namespace namespace ON namespace.oid = object.typnamespace
      WHERE namespace.nspname = 'public'
        AND object.typisdefined
        AND object.typowner = 'uten'::regrole
    ),
    'applicationHasNoElevatedTablePrivilege', NOT EXISTS (
      SELECT 1 FROM pg_class object
      JOIN pg_namespace namespace ON namespace.oid = object.relnamespace
      WHERE namespace.nspname = 'public'
        AND object.relkind IN ('r','p','v','m','f')
        AND (
          has_table_privilege('uten', object.oid, 'TRUNCATE')
          OR has_table_privilege('uten', object.oid, 'REFERENCES')
          OR has_table_privilege('uten', object.oid, 'TRIGGER')
        )
    ),
    'applicationHasAllRequiredTablePrivileges', NOT EXISTS (
      SELECT 1 FROM pg_class object
      JOIN pg_namespace namespace ON namespace.oid = object.relnamespace
      WHERE namespace.nspname = 'public'
        AND object.relkind IN ('r','p','v','m','f')
        AND NOT (
          has_table_privilege('uten', object.oid, 'SELECT')
          AND has_table_privilege('uten', object.oid, 'INSERT')
          AND has_table_privilege('uten', object.oid, 'UPDATE')
          AND has_table_privilege('uten', object.oid, 'DELETE')
        )
    ),
    'applicationHasAllRequiredSequencePrivileges', NOT EXISTS (
      SELECT 1 FROM pg_class object
      JOIN pg_namespace namespace ON namespace.oid = object.relnamespace
      WHERE namespace.nspname = 'public'
        AND object.relkind = 'S'
        AND NOT (
          has_sequence_privilege('uten', object.oid, 'USAGE')
          AND has_sequence_privilege('uten', object.oid, 'SELECT')
          AND has_sequence_privilege('uten', object.oid, 'UPDATE')
        )
    ),
    'applicationHasAllRequiredFunctionPrivileges', NOT EXISTS (
      SELECT 1 FROM pg_proc object
      JOIN pg_namespace namespace ON namespace.oid = object.pronamespace
      WHERE namespace.nspname = 'public'
        AND NOT has_function_privilege('uten', object.oid, 'EXECUTE')
    ),
    'applicationHasAllRequiredTypePrivileges', NOT EXISTS (
      SELECT 1 FROM pg_type object
      JOIN pg_namespace namespace ON namespace.oid = object.typnamespace
      WHERE namespace.nspname = 'public'
        AND object.typisdefined
        AND NOT has_type_privilege('uten', object.oid, 'USAGE')
    ),
    'noUnexpectedExplicitPublicObjectAcl', NOT EXISTS (
      SELECT 1
      FROM pg_class object
      JOIN pg_namespace namespace ON namespace.oid = object.relnamespace
      CROSS JOIN LATERAL aclexplode(
        COALESCE(object.relacl, acldefault(CASE WHEN object.relkind = 'S' THEN 'S'::"char" ELSE 'r'::"char" END, object.relowner))
      ) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE namespace.nspname = 'public'
        AND object.relkind IN ('r','p','v','m','S','f')
        AND acl.grantee <> object.relowner
        AND NOT (
          grantee.rolname = 'uten'
          AND (
            (object.relkind = 'S' AND acl.privilege_type IN ('USAGE','SELECT','UPDATE'))
            OR (object.relkind <> 'S' AND acl.privilege_type IN ('SELECT','INSERT','UPDATE','DELETE'))
          )
          AND acl.is_grantable IS FALSE
        )
    ) AND NOT EXISTS (
      SELECT 1
      FROM pg_proc object
      JOIN pg_namespace namespace ON namespace.oid = object.pronamespace
      CROSS JOIN LATERAL aclexplode(COALESCE(object.proacl, acldefault('f', object.proowner))) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE namespace.nspname = 'public'
        AND acl.grantee <> object.proowner
        AND NOT (
          grantee.rolname = 'uten'
          AND acl.privilege_type = 'EXECUTE'
          AND acl.is_grantable IS FALSE
        )
    ),
    'noUnexpectedExplicitPublicTypeAcl', NOT EXISTS (
      SELECT 1
      FROM pg_type object
      JOIN pg_namespace namespace ON namespace.oid = object.typnamespace
      CROSS JOIN LATERAL aclexplode(COALESCE(object.typacl, acldefault('T', object.typowner))) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE namespace.nspname = 'public'
        AND object.typisdefined
        AND acl.grantee <> object.typowner
        AND NOT (
          grantee.rolname = 'uten'
          AND acl.privilege_type = 'USAGE'
          AND acl.is_grantable IS FALSE
        )
    ),
    'defaultTableAcl', (
      SELECT COALESCE(json_agg(((CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END) || ':' || acl.privilege_type || ':' || acl.is_grantable::text) ORDER BY (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END), acl.privilege_type, acl.is_grantable), '[]'::json)
      FROM pg_default_acl defaults
      JOIN pg_namespace namespace ON namespace.oid = defaults.defaclnamespace
      CROSS JOIN LATERAL aclexplode(defaults.defaclacl) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE defaults.defaclrole = 'uten_owner'::regrole
        AND namespace.nspname = 'public'
        AND defaults.defaclobjtype = 'r'
        AND acl.grantee <> defaults.defaclrole
    ),
    'defaultSequenceAcl', (
      SELECT COALESCE(json_agg(((CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END) || ':' || acl.privilege_type || ':' || acl.is_grantable::text) ORDER BY (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END), acl.privilege_type, acl.is_grantable), '[]'::json)
      FROM pg_default_acl defaults
      JOIN pg_namespace namespace ON namespace.oid = defaults.defaclnamespace
      CROSS JOIN LATERAL aclexplode(defaults.defaclacl) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE defaults.defaclrole = 'uten_owner'::regrole
        AND namespace.nspname = 'public'
        AND defaults.defaclobjtype = 'S'
        AND acl.grantee <> defaults.defaclrole
    ),
    'defaultFunctionAcl', (
      SELECT COALESCE(json_agg(((CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END) || ':' || acl.privilege_type || ':' || acl.is_grantable::text) ORDER BY (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END), acl.privilege_type, acl.is_grantable), '[]'::json)
      FROM pg_default_acl defaults
      JOIN pg_namespace namespace ON namespace.oid = defaults.defaclnamespace
      CROSS JOIN LATERAL aclexplode(defaults.defaclacl) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE defaults.defaclrole = 'uten_owner'::regrole
        AND namespace.nspname = 'public'
        AND defaults.defaclobjtype = 'f'
        AND acl.grantee <> defaults.defaclrole
    ),
    'defaultTypeAcl', (
      SELECT COALESCE(json_agg(((CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END) || ':' || acl.privilege_type || ':' || acl.is_grantable::text) ORDER BY (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END), acl.privilege_type, acl.is_grantable), '[]'::json)
      FROM pg_default_acl defaults
      JOIN pg_namespace namespace ON namespace.oid = defaults.defaclnamespace
      CROSS JOIN LATERAL aclexplode(defaults.defaclacl) acl
      LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
      WHERE defaults.defaclrole = 'uten_owner'::regrole
        AND namespace.nspname = 'public'
        AND defaults.defaclobjtype = 'T'
        AND acl.grantee <> defaults.defaclrole
    )
  ),
  'flywayHistory', (
    SELECT COALESCE(
      json_agg(
        json_build_object(
          'installedRank', installed_rank,
          'version', version,
          'description', description,
          'type', type,
          'script', script,
          'checksum', checksum,
          'success', success
        ) ORDER BY installed_rank
      ),
      '[]'::json
    )
    FROM public.flyway_schema_history
  )
)::text;
""".strip()


class VerificationError(RuntimeError):
    """The fixed, read-only database observation could not be produced."""


def _environment() -> dict[str, str]:
    return {
        "HOME": "/var/lib/postgresql",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
        "PGAPPNAME": "uten-imp-activation-recovery-verifier",
        "PGCONNECT_TIMEOUT": "10",
        "PGOPTIONS": (
            "-c default_transaction_read_only=on "
            "-c statement_timeout=30000 -c lock_timeout=5000"
        ),
    }


def collect() -> dict[str, Any]:
    try:
        postgres = pwd.getpwnam("postgres")
    except KeyError as exc:
        raise VerificationError("the postgres OS account is unavailable") from exc
    if os.geteuid() != postgres.pw_uid:
        raise VerificationError("the database verifier must run as the postgres OS account")
    try:
        result = subprocess.run(
            [
                PSQL,
                "-X",
                "-A",
                "-t",
                "--no-password",
                "-v",
                "ON_ERROR_STOP=1",
                "-h",
                "/var/run/postgresql",
                "-p",
                "5432",
                "-U",
                "postgres",
                "-d",
                "uten_imp",
                "-c",
                QUERY,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_environment(),
            timeout=40,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise VerificationError("the fixed PostgreSQL identity query could not complete") from exc
    if result.returncode != 0:
        raise VerificationError("the fixed PostgreSQL identity query exited non-zero")
    if not result.stdout or len(result.stdout) > MAX_OUTPUT_BYTES or b"\0" in result.stdout:
        raise VerificationError("the fixed PostgreSQL identity output is outside policy")
    try:
        value = json.loads(result.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise VerificationError("the fixed PostgreSQL identity output is not JSON") from exc
    if not isinstance(value, dict):
        raise VerificationError("the fixed PostgreSQL identity output is not one object")
    try:
        unit = subprocess.run(
            [
                SYSTEMCTL,
                "show",
                "--property=MainPID",
                "--value",
                "postgresql@16-main.service",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_environment(),
            timeout=10,
            check=False,
        )
        main_pid = int(unit.stdout.decode("ascii").strip())
    except (OSError, UnicodeDecodeError, ValueError, subprocess.TimeoutExpired) as exc:
        raise VerificationError("the fixed PostgreSQL systemd identity could not be read") from exc
    if unit.returncode != 0 or main_pid <= 1 or value.get("postmasterPid") != main_pid:
        raise VerificationError(
            "the queried PostgreSQL instance differs from postgresql@16-main.service"
        )
    value["systemdMainPid"] = main_pid
    try:
        listeners = subprocess.run(
            [SS, "-H", "-ltnp", "sport", "=", ":5432"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_environment(),
            timeout=10,
            check=False,
        )
        listener_text = listeners.stdout.decode("utf-8")
    except (OSError, UnicodeDecodeError, subprocess.TimeoutExpired) as exc:
        raise VerificationError("the fixed PostgreSQL TCP listener could not be read") from exc
    ipv4_lines = [
        line
        for line in listener_text.splitlines()
        if re.search(r"(?:^|\s)127\.0\.0\.1:5432(?:\s|$)", line)
    ]
    listener_pids = {
        int(match.group(1))
        for line in ipv4_lines
        for match in re.finditer(r"\bpid=(\d+)(?:,|\))", line)
    }
    if listeners.returncode != 0 or len(ipv4_lines) != 1 or listener_pids != {main_pid}:
        raise VerificationError(
            "127.0.0.1:5432 is not exclusively owned by postgresql@16-main.service"
        )
    value["tcpListenerPid"] = main_pid
    return value


def main() -> int:
    if len(sys.argv) != 1:
        print("ERROR: database recovery verifier accepts no arguments", file=sys.stderr)
        return 2
    try:
        value = collect()
    except VerificationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
